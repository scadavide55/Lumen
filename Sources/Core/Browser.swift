import Combine
import SwiftUI
import WebKit

/// State for one browser window: its tabs, selection, split view and overlays.
final class BrowserState: ObservableObject {
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore

    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var splitID: UUID?
    @Published var sidebarVisible: Bool {
        didSet { if !isPrivate { Settings.shared.sidebarVisible = sidebarVisible } }
    }
    @Published var peekSidebar = false
    @Published var paletteVisible = false
    @Published var findVisible = false
    var palettePrefill = ""
    weak var window: NSWindow?

    private var closedTabs: [(snapshot: TabSnapshot, index: Int)] = []
    private var lastOpened: (opener: UUID, tab: UUID)?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var keyObserver: NSObjectProtocol?

    var current: Tab? { tabs.first { $0.id == selectedID } }
    var splitTab: Tab? { splitID.flatMap { id in tabs.first { $0.id == id } } }
    var pinnedTabs: [Tab] { tabs.filter(\.isPinned) }
    var regularTabs: [Tab] { tabs.filter { !$0.isPinned } }
    var canReopen: Bool { !closedTabs.isEmpty }

    init(isPrivate: Bool) {
        self.isPrivate = isPrivate
        dataStore = isPrivate ? .nonPersistent() : .default()
        sidebarVisible = Settings.shared.sidebarVisible
        WindowRegistry.shared.add(self)

        if !isPrivate, let snap = Session.shared.takePending() { restore(snap) }
        if !isPrivate {
            for u in WindowRegistry.shared.takePendingURLs() { newTab(url: u) }
        }
        if tabs.isEmpty { newTab() }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.hibernateIdle() }
        if !isPrivate {
            $tabs.combineLatest($selectedID)
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { _ in Session.shared.scheduleSave() }
                .store(in: &cancellables)
        }
    }

    deinit {
        timer?.invalidate()
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        tabs.forEach { $0.close() }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = current?.title ?? "Lumen"
        WindowRegistry.shared.lastFocused = self
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            WindowRegistry.shared.lastFocused = self
        }
    }

    private func restore(_ snap: WindowSnapshot) {
        tabs = snap.tabs.map { Tab(browser: self, url: $0.url, title: $0.title, state: $0.state, pinned: $0.pinned) }
        normalizeOrder()
        if !tabs.isEmpty { select(tabs[max(0, min(snap.selected, tabs.count - 1))]) }
    }

    func snapshot() -> WindowSnapshot {
        WindowSnapshot(tabs: tabs.map { $0.snapshot() }, selected: tabs.firstIndex { $0.id == selectedID } ?? 0)
    }

    // MARK: Opening and selecting

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(browser: self, url: url)
        insert(tab, after: anchor ?? (Settings.shared.newTabPosition == .afterCurrent ? current : nil))
        if select { self.select(tab) }
        return tab
    }

    /// ⌘T: a fresh tab with the command bar open.
    func newTabWithPalette() {
        newTab()
        showPalette("")
    }

    private func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, !anchor.isPinned, let i = tabs.firstIndex(where: { $0.id == anchor.id }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        if splitID == tab.id { splitID = selectedID }
        current?.lastActive = Date()
        tab.ensureWebView()
        tab.lastActive = Date()
        selectedID = tab.id
        findVisible = false
        window?.title = tab.title
    }

    func select(index: Int) {
        guard !tabs.isEmpty else { return }
        select(index >= 9 ? tabs[tabs.count - 1] : tabs[min(index - 1, tabs.count - 1)])
    }

    func selectNext(_ step: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selectedID }), tabs.count > 1 else { return }
        select(tabs[(i + step + tabs.count) % tabs.count])
    }

    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab) -> WKWebView? {
        let tab = Tab(browser: self, configuration: configuration)
        insert(tab, after: opener)
        select(tab)
        return tab.webView
    }

    /// ⌘-click: opens next to the opener, keeping successive links in order.
    func openInBackground(_ url: URL, from opener: Tab?, select: Bool = false) {
        var anchor = opener
        if let opener, let last = lastOpened, last.opener == opener.id,
           let t = tabs.first(where: { $0.id == last.tab }) { anchor = t }
        let tab = newTab(url: url, select: select, after: anchor)
        tab.ensureWebView()
        if let opener { lastOpened = (opener.id, tab.id) }
    }

    func tabDidNavigate(_ tab: Tab) {
        if tab.id == selectedID { window?.title = tab.title }
        if !isPrivate { Session.shared.scheduleSave() }
    }

    // MARK: Closing

    func close(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if tab.url != nil {
            closedTabs.append((tab.snapshot(), i))
            if closedTabs.count > 30 { closedTabs.removeFirst() }
        }
        let wasSelected = tab.id == selectedID
        tabs.remove(at: i)
        tab.close()
        if splitID == tab.id { splitID = nil }
        if tabs.isEmpty {
            newTab()
        } else if wasSelected {
            select(tabs[min(i, tabs.count - 1)])
        }
    }

    /// ⌘W closes the tab; on a lone empty tab it closes the window.
    func closeCurrent() {
        guard let t = current else { return }
        if tabs.count == 1 && t.isStartPage {
            window?.performClose(nil)
        } else {
            close(t)
        }
    }

    func closeOthers(_ keep: Tab) {
        for t in tabs where t.id != keep.id && !t.isPinned { close(t) }
    }

    func closeBelow(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for t in tabs[(i + 1)...] where !t.isPinned { close(t) }
    }

    func reopenClosed() {
        guard let (snap, index) = closedTabs.popLast() else { return }
        let tab = Tab(browser: self, url: snap.url, title: snap.title, state: snap.state, pinned: snap.pinned)
        tabs.insert(tab, at: min(index, tabs.count))
        normalizeOrder()
        select(tab)
    }

    // MARK: Arranging

    func togglePin(_ tab: Tab) {
        tab.isPinned.toggle()
        normalizeOrder()
    }

    func duplicate(_ tab: Tab) {
        let copy = Tab(browser: self, url: tab.url, title: tab.title, state: tab.snapshot().state)
        insert(copy, after: tab)
        select(copy)
    }

    /// Handles tab IDs or URLs dropped onto a tab row or section.
    func handleDrop(_ items: [String], before target: Tab?, pinned: Bool) -> Bool {
        var handled = false
        var opened: Tab?
        for item in items {
            let tab: Tab
            if let id = UUID(uuidString: item), let existing = tabs.first(where: { $0.id == id }) {
                guard existing.id != target?.id else { continue }
                tabs.removeAll { $0.id == id }
                tab = existing
            } else if let url = URL(string: item), ["http", "https"].contains(url.scheme ?? "") {
                tab = Tab(browser: self, url: url)
                opened = tab
            } else {
                continue
            }
            tab.isPinned = pinned
            if let target, let i = tabs.firstIndex(where: { $0.id == target.id }) {
                tabs.insert(tab, at: i)
            } else if pinned, let i = tabs.lastIndex(where: \.isPinned) {
                tabs.insert(tab, at: i + 1)
            } else {
                tabs.append(tab)
            }
            handled = true
        }
        normalizeOrder()
        if let opened { select(opened) }
        return handled
    }

    private func normalizeOrder() {
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
    }

    // MARK: Split view

    func openSplit(_ tab: Tab) {
        guard tab.id != selectedID else { return }
        tab.ensureWebView()
        splitID = tab.id
    }

    func splitWithNewTab() {
        let t = newTab(select: false)
        t.ensureWebView()
        splitID = t.id
    }

    func swapSplit() {
        guard let s = splitID, let c = selectedID else { return }
        selectedID = s
        splitID = c
    }

    func closeSplit() { splitID = nil }

    // MARK: Memory

    func hibernateIdle() {
        let minutes = Settings.shared.hibernateMinutes
        guard minutes > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        for t in tabs where !t.isSelected && !t.isHibernated && !t.isPlayingAudio && t.lastActive < cutoff {
            t.hibernate()
        }
    }

    func hibernateOthers() {
        for t in tabs where !t.isSelected && !t.isPlayingAudio { t.hibernate() }
    }

    // MARK: Overlays

    func showPalette(_ prefill: String? = nil) {
        palettePrefill = prefill ?? current?.url?.absoluteString ?? ""
        findVisible = false
        paletteVisible = true
    }

    func showFind() {
        paletteVisible = false
        findVisible = true
    }
}
