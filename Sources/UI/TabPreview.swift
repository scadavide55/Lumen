import SwiftUI
import WebKit

/// How much memory a tab's page uses: the footprint of its web content process, the number Activity Monitor
/// shows. Each tab normally has its own process; when WebKit puts several in one (a pop-up and its opener,
/// or many tabs at once), the tabs sharing it are named instead of giving each the whole amount.
enum TabMemory {
    struct Use: Equatable {
        var bytes: UInt64
        /// Other open tabs in the same process.
        var sharedWith: Int
    }

    static func processID(_ webView: WKWebView) -> pid_t? {
        // WebKit's own name for it; checked first, so a WebKit without it just shows no number.
        let key = "_webProcessIdentifier"
        guard webView.responds(to: NSSelectorFromString(key)),
              let n = webView.value(forKey: key) as? NSNumber, n.int32Value > 0 else { return nil }
        return n.int32Value
    }

    static func footprint(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_phys_footprint : nil
    }

    static func use(of tab: Tab) -> Use? {
        guard let wv = tab.webView, let pid = processID(wv), let bytes = footprint(pid) else { return nil }
        let others = WindowRegistry.shared.browsers.flatMap(\.tabs).filter { t in
            t !== tab && t.webView.flatMap(processID) == pid
        }
        return Use(bytes: bytes, sharedWith: others.count)
    }

    static func describe(_ use: Use) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(use.bytes), countStyle: .memory)
        switch use.sharedWith {
        case 0: return String(format: L("Memory: %@"), size)
        case 1: return String(format: L("Memory: %@, shared with 1 other tab"), size)
        default: return String(format: L("Memory: %@, shared with %d other tabs"), size, use.sharedWith)
        }
    }
}

/// Shown after the pointer rests on a tab: its title, site, memory and, when there is one, a picture of the page.
struct TabPreviewCard: View {
    var tab: Tab
    @State private var memory: TabMemory.Use?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = tab.previewImage {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 260, height: 140, alignment: .top).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(tab.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
            if let url = tab.url {
                Text(InputResolver.displayHost(url)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Group {
                if tab.isHibernated {
                    Label("Sleeping: uses no memory until you open it", systemImage: "moon.zzz")
                } else if let memory {
                    Label(TabMemory.describe(memory), systemImage: "memorychip")
                }
            }
            .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .task(id: tab.isHibernated) {
            // Read once when the card opens, then every two seconds while it stays.
            while !Task.isCancelled {
                memory = TabMemory.use(of: tab)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// Opens the preview card when the pointer rests on a tab for a moment, and closes it when it leaves.
struct TabPreviewOnHover: ViewModifier {
    var tab: Tab
    var edge: Edge
    @State private var shown = false
    @State private var waiting: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                waiting?.cancel()
                guard Settings.shared.tabPreviews else { shown = false; return }
                if inside {
                    waiting = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        if !Task.isCancelled { shown = true }
                    }
                } else {
                    shown = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded { waiting?.cancel(); shown = false })
            .popover(isPresented: $shown, arrowEdge: edge) { TabPreviewCard(tab: tab) }
            // With previews off, the plain tooltip names the page instead.
            .help(Settings.shared.tabPreviews ? "" : (tab.url?.absoluteString ?? tab.title))
    }
}

extension View {
    func tabPreview(_ tab: Tab, edge: Edge) -> some View { modifier(TabPreviewOnHover(tab: tab, edge: edge)) }
}
