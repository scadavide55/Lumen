import SwiftUI
import WebKit

extension Notification.Name {
    static let focusAddress = Notification.Name("lumen.focusAddress")
}

// MARK: - Tab

final class Tab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    var openTab: ((URL) -> Void)?
    private var observers: [NSKeyValueObservation] = []

    init(config: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        observers = [
            webView.observe(\.title) { [weak self] w, _ in
                let t = w.title ?? ""
                self?.title = t.isEmpty ? (w.url?.host ?? "New Tab") : t
            },
            webView.observe(\.url) { [weak self] w, _ in self?.url = w.url },
            webView.observe(\.isLoading) { [weak self] w, _ in self?.isLoading = w.isLoading },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in self?.progress = w.estimatedProgress },
            webView.observe(\.canGoBack) { [weak self] w, _ in self?.canGoBack = w.canGoBack },
            webView.observe(\.canGoForward) { [weak self] w, _ in self?.canGoForward = w.canGoForward },
        ]
    }

    func load(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        webView.load(URLRequest(url: Tab.resolve(s)))
    }

    static func resolve(_ s: String) -> URL {
        if let u = URL(string: s), let scheme = u.scheme, ["http", "https", "file", "about"].contains(scheme) {
            return u
        }
        if s.hasPrefix("localhost"), let u = URL(string: "http://" + s) { return u }
        if !s.contains(" "), s.contains("."), let u = URL(string: "https://" + s) { return u }
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: s)]
        return c.url!
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { openTab?(u) }
        return nil
    }
}

// MARK: - Browser state

final class Browser: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var sidebarVisible = true
    @Published var adBlock: Bool {
        didSet {
            UserDefaults.standard.set(adBlock, forKey: "adBlock")
            applyAdBlock()
        }
    }
    private var ruleList: WKContentRuleList?

    var current: Tab? { tabs.first { $0.id == selectedID } }

    init() {
        adBlock = UserDefaults.standard.object(forKey: "adBlock") as? Bool ?? true
        newTab()
        Task { @MainActor in
            ruleList = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "lumen-v1", encodedContentRuleList: Browser.rulesJSON())
            applyAdBlock()
        }
    }

    func newTab(url: URL? = nil) {
        let cfg = WKWebViewConfiguration()
        if adBlock, let r = ruleList { cfg.userContentController.add(r) }
        let tab = Tab(config: cfg)
        tab.openTab = { [weak self] u in self?.newTab(url: u) }
        tabs.append(tab)
        selectedID = tab.id
        if let url { tab.webView.load(URLRequest(url: url)) }
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { newTab(); return }
        if selectedID == id { selectedID = tabs[min(i, tabs.count - 1)].id }
    }

    func applyAdBlock() {
        for t in tabs {
            let c = t.webView.configuration.userContentController
            c.removeAllContentRuleLists()
            if adBlock, let r = ruleList { c.add(r) }
        }
        if let t = current, t.url != nil { t.webView.reload() }
    }

    // Starter rule set: third-party ad and tracker hosts plus a few cosmetic selectors.
    static func rulesJSON() -> String {
        let domains = [
            "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
            "googletagmanager.com", "googletagservices.com", "adservice.google.com", "2mdn.net",
            "connect.facebook.net", "ads-twitter.com", "adnxs.com", "criteo.com", "criteo.net",
            "taboola.com", "outbrain.com", "scorecardresearch.com", "quantserve.com", "hotjar.com",
            "amazon-adsystem.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com",
            "moatads.com", "adsrvr.org", "advertising.com", "yieldmo.com", "mixpanel.com",
            "fullstory.com", "cdn.segment.com",
        ]
        var rules: [[String: Any]] = domains.map { d in
            let escaped = d.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://([^/]*\\.)?\(escaped)[/:]"],
                "action": ["type": "block"],
            ]
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": [
                "type": "css-display-none",
                "selector": ".adsbygoogle, [id^='google_ads'], [id^='div-gpt-ad'], .ad-banner, .ad-container, .advert",
            ],
        ])
        let data = try! JSONSerialization.data(withJSONObject: rules)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Views

struct WebContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var b: Browser

    var body: some View {
        HStack(spacing: 0) {
            if b.sidebarVisible {
                Sidebar()
                Divider()
            }
            if let tab = b.current {
                Page(tab: tab).id(tab.id)
            } else {
                Spacer()
            }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var b: Browser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer().frame(height: 30)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(b.tabs) { TabRow(tab: $0) }
                }
            }
            Button { b.newTab() } label: {
                Label("New Tab", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 220)
        .background { Rectangle().fill(.regularMaterial).ignoresSafeArea() }
    }
}

struct TabRow: View {
    @EnvironmentObject var b: Browser
    @ObservedObject var tab: Tab
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe").foregroundStyle(.secondary)
            Text(tab.title).lineLimit(1)
            Spacer(minLength: 0)
            if hover {
                Button { b.close(tab.id) } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(b.selectedID == tab.id ? Color.primary.opacity(0.12) : (hover ? Color.primary.opacity(0.06) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { b.selectedID = tab.id }
        .onHover { hover = $0 }
    }
}

struct Page: View {
    @EnvironmentObject var b: Browser
    @ObservedObject var tab: Tab
    @State private var address = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !b.sidebarVisible { Spacer().frame(width: 70) }
                icon("sidebar.left") { b.sidebarVisible.toggle() }
                icon("chevron.left") { tab.webView.goBack() }.disabled(!tab.canGoBack)
                icon("chevron.right") { tab.webView.goForward() }.disabled(!tab.canGoForward)
                icon(tab.isLoading ? "xmark" : "arrow.clockwise") {
                    if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                }
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { tab.load(address); focused = false }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                Button { b.adBlock.toggle() } label: {
                    Image(systemName: b.adBlock ? "shield.lefthalf.filled" : "shield.slash")
                        .foregroundStyle(b.adBlock ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(b.adBlock ? "Ad blocker on (click to disable)" : "Ad blocker off (click to enable)")
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .overlay(alignment: .bottom) {
                if tab.isLoading {
                    GeometryReader { g in
                        Rectangle().fill(Color.accentColor).frame(width: g.size.width * tab.progress, height: 2)
                    }
                    .frame(height: 2)
                }
            }
            ZStack {
                WebContainer(webView: tab.webView)
                if tab.url == nil { StartView() }
            }
        }
        .onAppear {
            address = tab.url?.absoluteString ?? ""
            if tab.url == nil { focused = true }
        }
        .onChange(of: tab.url) { _, u in if !focused { address = u?.absoluteString ?? "" } }
        .onReceive(NotificationCenter.default.publisher(for: .focusAddress)) { _ in focused = true }
    }

    private func icon(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).frame(width: 18) }.buttonStyle(.plain)
    }
}

struct StartView: View {
    @EnvironmentObject var b: Browser

    var body: some View {
        VStack(spacing: 6) {
            Text("Lumen").font(.system(size: 44, weight: .ultraLight))
            Text(b.adBlock ? "Ads and trackers blocked" : "Ad blocker off")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .allowsHitTesting(false)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var browser = Browser()

    var body: some Scene {
        Window("Lumen", id: "main") {
            ContentView()
                .environmentObject(browser)
                .frame(minWidth: 700, minHeight: 450)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { browser.newTab() }.keyboardShortcut("t")
                Button("Close Tab") { if let t = browser.current { browser.close(t.id) } }.keyboardShortcut("w")
                Button("Open Location") {
                    NotificationCenter.default.post(name: .focusAddress, object: nil)
                }.keyboardShortcut("l")
            }
            CommandMenu("Page") {
                Button("Reload") { browser.current?.webView.reload() }.keyboardShortcut("r")
                Button("Back") { browser.current?.webView.goBack() }.keyboardShortcut("[")
                Button("Forward") { browser.current?.webView.goForward() }.keyboardShortcut("]")
                Divider()
                Button("Toggle Sidebar") { browser.sidebarVisible.toggle() }.keyboardShortcut("\\")
                Button("Toggle Ad Blocker") { browser.adBlock.toggle() }.keyboardShortcut("b", modifiers: [.command, .shift])
            }
        }
    }
}
