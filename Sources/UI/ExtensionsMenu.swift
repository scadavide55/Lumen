import SwiftUI
import WebKit

/// The puzzle button in the toolbar: every installed plugin and extension in one list, so nobody has to remember
/// their shortcuts. Clicking one does what it's for: opens its app, runs its action, turns it on or off, or shows
/// how to use it. The shortcuts keep working; this is another way in.
struct ExtensionsMenuButton: View {
    var tab: Tab
    @State private var show = false

    var body: some View {
        IconButton(systemName: "puzzlepiece.extension", help: "Extensions and Tacet Plugins") { show.toggle() }
            .popover(isPresented: $show, arrowEdge: .bottom) { ExtensionsMenu(tab: tab) { show = false } }
    }
}

/// One row of the menu: a Tacet plugin or a web extension.
struct ExtensionEntry: Identifiable {
    enum Kind {
        case plugin(PluginStore.Plugin)
        case webExtension(Extensions.Installed)
    }

    let kind: Kind
    let name: String
    let enabled: Bool

    var id: String {
        switch kind {
        case .plugin(let p): "p-" + p.id
        case .webExtension(let e): "e-" + e.id.uuidString
        }
    }

    /// What a click does, shown on the right of the row.
    var hint: String {
        guard enabled else { return L("Off · click to turn on") }
        switch kind {
        case .plugin(let p):
            switch p.mode {
            case "app": return L("Open")
            case "action": return p.action.map(L) ?? L("Run")
            case "toggle": return L("On · click to turn off")
            default: return L("How to use it")
            }
        case .webExtension: return L("Open")
        }
    }

    static func all(for tab: Tab) -> [ExtensionEntry] {
        let plugins = PluginStore.shared.installed.values.map {
            ExtensionEntry(kind: .plugin($0.plugin), name: L($0.plugin.name), enabled: $0.enabled)
        }
        let extensions = Extensions.isSupported && tab.browser?.isPrivate != true
            ? Extensions.shared.installed.map { ExtensionEntry(kind: .webExtension($0), name: $0.name, enabled: $0.enabled) } : []
        return (plugins + extensions).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct ExtensionsMenu: View {
    var tab: Tab
    let close: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private var store = PluginStore.shared
    private var ext = Extensions.shared
    @State private var selection = 0
    @State private var detail: PluginStore.Plugin?
    @FocusState private var focused: Bool

    init(tab: Tab, close: @escaping () -> Void) {
        self.tab = tab
        self.close = close
    }

    var body: some View {
        // Read so the list redraws when a plugin or extension changes.
        let _ = (store.installed, ext.installed, ext.revision)
        let entries = ExtensionEntry.all(for: tab)
        VStack(alignment: .leading, spacing: 0) {
            if let detail {
                PluginHowTo(plugin: detail, back: { self.detail = nil }, close: close)
            } else {
                HStack {
                    Text("Extensions").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Tacet Plugins…") { openWindow(id: "plugins"); close() }.buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
                if entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("No extensions yet").font(.system(size: 13, weight: .medium))
                        Text("Add plugins made for Tacet, or web extensions from your apps or files.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Browse Tacet Plugins") { openWindow(id: "plugins"); close() }.buttonStyle(.borderedProminent).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity).padding(18)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                                ExtensionRow(entry: e, selected: i == selection, info: { showInfo(e) })
                                    .contentShape(Rectangle())
                                    .onTapGesture { selection = i; activate(e) }
                                    .onHover { if $0 { selection = i } }
                            }
                        }
                        .padding(.horizontal, 6).padding(.bottom, 6)
                    }
                    .frame(maxHeight: 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Button("Manage Extensions…") { openSettings(); close() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(width: 320)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // Arrows move, Return clicks; Esc closes the popover on its own.
        .onKeyPress(.downArrow) { if !entries.isEmpty { selection = (selection + 1) % entries.count }; return .handled }
        .onKeyPress(.upArrow) { if !entries.isEmpty { selection = (selection - 1 + entries.count) % entries.count }; return .handled }
        .onKeyPress(.return) {
            if detail == nil, entries.indices.contains(selection) { activate(entries[selection]) }
            return .handled
        }
    }

    private func showInfo(_ e: ExtensionEntry) {
        if case .plugin(let p) = e.kind { detail = p } else if case .webExtension = e.kind { openSettings(); close() }
    }

    /// What a click on a row does, by the kind of plugin or extension.
    private func activate(_ e: ExtensionEntry) {
        switch e.kind {
        case .plugin(let p):
            // A plugin that's off can only be turned back on from here.
            guard e.enabled else { store.setEnabled(p.id, true); return }
            switch p.mode {
            case "app":
                if let url = p.startURL { tab.browser?.newTab(url: url) }
                close()
            case "action":
                close()
                Task { await store.runAction(p, in: tab) }
            case "toggle":
                store.setEnabled(p.id, false)
            default:
                detail = p
            }
        case .webExtension(let item):
            guard e.enabled else { ext.setEnabled(item.id, true); return }
            // Opens its popup, or runs its action when it has no popup, as clicking its toolbar button would.
            if #available(macOS 15.4, *), let context = ext.context(item.id) { context.performAction(for: tab) }
            close()
        }
    }
}

struct ExtensionRow: View {
    let entry: ExtensionEntry
    let selected: Bool
    let info: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.system(size: 13)).lineLimit(1)
                Text(entry.hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Circle().fill(entry.enabled ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                .help(entry.enabled ? L("On") : L("Off"))
            Button(action: info) { Image(systemName: "info.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("How to use it")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .opacity(entry.enabled ? 1 : 0.5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
    }

    @ViewBuilder private var icon: some View {
        switch entry.kind {
        case .plugin(let p):
            Image(systemName: p.icon ?? "puzzlepiece.extension").font(.system(size: 13, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.14)))
        case .webExtension(let item):
            if #available(macOS 15.4, *), let img = Extensions.shared.context(item.id)?.webExtension.icon(for: CGSize(width: 22, height: 22)) {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
            }
        }
    }
}

/// How to use a plugin: what it does, where it works, its shortcut, and turning it on or off.
struct PluginHowTo: View {
    let plugin: PluginStore.Plugin
    let back: () -> Void
    let close: () -> Void
    private var store = PluginStore.shared

    init(plugin: PluginStore.Plugin, back: @escaping () -> Void, close: @escaping () -> Void) {
        self.plugin = plugin
        self.back = back
        self.close = close
    }

    var body: some View {
        let enabled = store.installed[plugin.id]?.enabled ?? false
        VStack(alignment: .leading, spacing: 10) {
            Button(action: back) { Label("Extensions", systemImage: "chevron.left").font(.caption) }.buttonStyle(.borderless)
            HStack(spacing: 10) {
                Image(systemName: plugin.icon ?? "puzzlepiece.extension").font(.system(size: 18)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(plugin.name)).font(.headline)
                    Text(plugin.byLine).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L(plugin.description)).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let shortcut = plugin.shortcut {
                Label(String(format: L("Shortcut: %@"), shortcut), systemImage: "keyboard").font(.callout)
            }
            Label(plugin.sites.contains("*") ? L("Works on every site") : String(format: L("Works on %@"), plugin.sites.joined(separator: ", ")),
                  systemImage: "globe").font(.callout).foregroundStyle(.secondary)
            Toggle(enabled ? LocalizedStringKey("On") : "Off", isOn: Binding(get: { enabled }, set: { store.setEnabled(plugin.id, $0) }))
                .toggleStyle(.switch).controlSize(.small)
        }
        .padding(14)
    }
}
