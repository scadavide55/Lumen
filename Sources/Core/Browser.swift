import Combine
import LocalAuthentication
import SwiftUI
import WebKit

/// State for one browser window: its tabs, selection, split view and overlays.
final class BrowserState: ObservableObject {
    let isPrivate: Bool
    let dataStore: WKWebsiteDataStore
    /// The profile whose cookies and site data this window uses; nil for the main one.
    let profileID: UUID?
    var profile: Profile? { profileID.flatMap { id in Settings.shared.profiles.first { $0.id == id } } }

    @Published var tabs: [Tab] = []
    @Published var groups: [TabGroup] = []
    private var popups: [PopupWindow] = []
    @Published var selectedID: UUID?
    @Published var splitID: UUID?
    @Published var sidebarVisible: Bool {
        didSet { if !isPrivate { Settings.shared.sidebarVisible = sidebarVisible } }
    }
    @Published var peekSidebar = false
    @Published var paletteVisible = false
    @Published var findVisible = false
    @Published var showOnboarding = false
    @Published var locked = false
    @Published var showInstallApp = false
    var palettePrefill = ""
    weak var window: NSWindow?

    @Published private(set) var closedTabs: [(snapshot: TabSnapshot, index: Int)] = []
    private var lastOpened: (opener: UUID, tab: UUID)?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var keyObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?

    var current: Tab? { tabs.first { $0.id == selectedID } }
    var splitTab: Tab? { splitID.flatMap { id in tabs.first { $0.id == id } } }
    var pinnedTabs: [Tab] { tabs.filter(\.isPinned) }
    var regularTabs: [Tab] { tabs.filter { !$0.isPinned } }
    var canReopen: Bool { !closedTabs.isEmpty }

    init(isPrivate: Bool, profileID: UUID? = nil) {
        self.isPrivate = isPrivate
        // A window restored from the last session reopens in the profile it had.
        let snap = WebApp.isActive || isPrivate || profileID != nil ? nil : Session.shared.takePending()
        let pid = isPrivate ? nil : (profileID ?? snap?.profile)
        let profile = pid.flatMap { id in Settings.shared.profiles.first { $0.id == id } }
        self.profileID = profile?.id
        dataStore = isPrivate ? .nonPersistent() : profile.map { WKWebsiteDataStore(forIdentifier: $0.id) } ?? .default()
        sidebarVisible = Settings.shared.sidebarVisible
        WindowRegistry.shared.add(self)

        if let app = WebApp.url {
            newTab(url: app)
        } else if let snap {
            restore(snap)
        }
        if !isPrivate {
            for u in WindowRegistry.shared.takePendingURLs() { newTab(url: u) }
        }
        if tabs.isEmpty { newTab() }

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.hibernateIdle() }
        if isPrivate {
            lockObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                if Settings.shared.lockPrivateWindows { self?.locked = true }
            }
        }
        // Settings are baked into a web view when it's made, so a change throws the spare away.
        spareObserver = NotificationCenter.default.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.spare != nil else { return }
            self.spare = nil
            self.prepareSpare()
        }
        prepareSpare()
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
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        if let spareObserver { NotificationCenter.default.removeObserver(spareObserver) }
        tabs.forEach { $0.close() }
    }

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        // The title bar holds tabs, so macOS must not drag the window from it; WindowDragArea moves it instead.
        window.isMovable = false
        window.titleVisibility = .hidden
        window.title = current?.title ?? "Lumen"
        WindowRegistry.shared.lastFocused = self
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            WindowRegistry.shared.lastFocused = self
        }
    }

    private func restore(_ snap: WindowSnapshot) {
        groups = snap.groups ?? []
        tabs = snap.tabs.map { s in
            let t = Tab(browser: self, url: s.url, title: s.title, state: s.state, pinned: s.pinned)
            t.groupID = s.group.flatMap { g in groups.contains { $0.id == g } ? g : nil }
            if let d = s.lastActive { t.lastActive = d }
            return t
        }
        normalizeOrder()
        if !tabs.isEmpty { select(tabs[max(0, min(snap.selected, tabs.count - 1))]) }
    }

    func snapshot() -> WindowSnapshot {
        WindowSnapshot(tabs: tabs.map { $0.snapshot() }, selected: tabs.firstIndex { $0.id == selectedID } ?? 0, groups: groups, profile: profileID)
    }

    // MARK: Opening and selecting

    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true, after anchor: Tab? = nil) -> Tab {
        let tab = Tab(browser: self, url: url)
        insert(tab, after: anchor ?? (Settings.shared.newTabPosition == .afterCurrent ? current : nil))
        if select { self.select(tab) }
        return tab
    }

    /// ⌘T: a fresh tab, with the command bar open unless the user turned that off.
    func newTabWithPalette() {
        newTab()
        if Settings.shared.paletteOnNewTab { showPalette("") }
    }

    private func insert(_ tab: Tab, after anchor: Tab?) {
        if let anchor, !anchor.isPinned, let i = tabs.firstIndex(where: { $0.id == anchor.id }) {
            tabs.insert(tab, at: i + 1)
        } else {
            tabs.append(tab)
        }
    }

    func select(_ tab: Tab) {
        if let g = tab.groupID, let i = groups.firstIndex(where: { $0.id == g }), groups[i].collapsed { groups[i].collapsed = false }
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

    func openPopup(configuration: WKWebViewConfiguration, from opener: Tab, features: WKWindowFeatures) -> WKWebView? {
        let sized = features.width != nil || features.height != nil || WebApp.isActive
        switch WebApp.isActive ? .automatic : Settings.shared.popupMode {
        case .never, .automatic:
            guard Settings.shared.popupMode == .never || sized || WebApp.isActive else { break }
            let popup = PopupWindow(configuration: configuration, features: features, opener: self) { [weak self] p in
                self?.popups.removeAll { $0 === p }
            }
            popups.append(popup)
            return popup.webView
        default:
            break
        }
        let tab = Tab(browser: self, configuration: configuration)
        tab.groupID = opener.groupID
        insert(tab, after: opener)
        select(tab)
        return tab.webView
    }

    /// ⌘-click: opens next to the opener, keeping successive links in order.
    func openInBackground(_ url: URL, from opener: Tab?, select: Bool = false) {
        if WebApp.isActive { WebApp.openInBrowser(url); return }
        var anchor = opener
        if let opener, let last = lastOpened, last.opener == opener.id,
           let t = tabs.first(where: { $0.id == last.tab }) { anchor = t }
        let tab = newTab(url: url, select: select, after: anchor)
        tab.ensureWebView()
        if let opener { lastOpened = (opener.id, tab.id) }
    }

    func tabDidNavigate(_ tab: Tab) {
        if tab.id == selectedID { window?.title = tab.title }
        if Settings.shared.organizeTabs { autoOrganize() }
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
        if tab.groupID != nil { cleanupGroups() }
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

    /// Closes tabs showing the same address as an earlier tab, keeping the selected and pinned ones.
    func closeDuplicates() {
        var seen = Set<String>()
        for t in tabs.sorted(by: { ($0.isPinned || $0.id == selectedID ? 0 : 1) < ($1.isPinned || $1.id == selectedID ? 0 : 1) }) {
            guard let key = t.url?.absoluteString else { continue }
            if seen.contains(key), !t.isPinned, t.id != selectedID { close(t) } else { seen.insert(key) }
        }
    }

    func closeBelow(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        for t in tabs[(i + 1)...] where !t.isPinned { close(t) }
    }

    func reopenClosed(at position: Int? = nil) {
        guard !closedTabs.isEmpty else { return }
        let (snap, index) = closedTabs.remove(at: position ?? closedTabs.count - 1)
        let tab = Tab(browser: self, url: snap.url, title: snap.title, state: snap.state, pinned: snap.pinned)
        // Back into its group, if the group is still there.
        if !snap.pinned, let g = snap.group, groups.contains(where: { $0.id == g }) { tab.groupID = g }
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
    enum DropPlacement { case before, after, group }

    func handleDrop(_ items: [String], before target: Tab?, pinned: Bool) -> Bool {
        handleDrop(items, on: target, placement: .before, pinned: pinned)
    }

    /// Moves or opens dropped tabs. Dropping onto the middle of a tab groups the two.
    func handleDrop(_ items: [String], on target: Tab?, placement: DropPlacement, pinned: Bool) -> Bool {
        if placement == .group, let target, !target.isPinned {
            var handled = false
            for item in items {
                if let id = UUID(uuidString: item), let dragged = tabs.first(where: { $0.id == id }), dragged.id != target.id {
                    group(dragged, with: target)
                    handled = true
                } else if let url = URL(string: item), ["http", "https"].contains(url.scheme ?? "") {
                    let t = Tab(browser: self, url: url)
                    tabs.append(t)
                    group(t, with: target)
                    select(t)
                    handled = true
                }
            }
            return handled
        }
        let anchor: Tab?
        if placement == .after, let target, let i = tabs.firstIndex(where: { $0.id == target.id }) {
            anchor = tabs.indices.contains(i + 1) ? tabs[i + 1] : nil
        } else {
            anchor = target
        }
        let joinGroup = target?.groupID
        let ok = handleDropBefore(items, before: anchor, pinned: pinned, group: pinned ? nil : joinGroup)
        cleanupGroups()
        return ok
    }

    private func handleDropBefore(_ items: [String], before target: Tab?, pinned: Bool, group: UUID?) -> Bool {
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
            tab.groupID = group
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

    /// Pinned tabs first, and the tabs of each group kept together where the group first appears.
    private func normalizeOrder() {
        var regular: [Tab] = []
        var placed = Set<UUID>()
        let unpinned = tabs.filter { !$0.isPinned }
        for t in unpinned {
            guard let g = t.groupID else { regular.append(t); continue }
            if placed.contains(g) { continue }
            placed.insert(g)
            regular += unpinned.filter { $0.groupID == g }
        }
        tabs = tabs.filter(\.isPinned) + regular
    }

    // MARK: Groups

    func group(_ dragged: Tab, with target: Tab) {
        dragged.isPinned = false
        if let g = target.groupID {
            dragged.groupID = g
        } else {
            let sameSite = dragged.host.map(PasswordStore.site) == target.host.map(PasswordStore.site) ? target.host.map(PasswordStore.site) : nil
            let new = TabGroup(name: sameSite.map(Self.siteName) ?? L("New Group"), color: groups.count)
            groups.append(new)
            target.groupID = new.id
            dragged.groupID = new.id
        }
        tabs.removeAll { $0.id == dragged.id }
        if let i = tabs.lastIndex(where: { $0.groupID == dragged.groupID }) { tabs.insert(dragged, at: i + 1) } else { tabs.append(dragged) }
        cleanupGroups()
    }

    func tabs(in group: TabGroup) -> [Tab] { tabs.filter { $0.groupID == group.id } }

    func newGroup(with tab: Tab) {
        let g = TabGroup(name: tab.host.map { Self.siteName(PasswordStore.site($0)) } ?? L("New Group"), color: groups.count)
        groups.append(g)
        tab.groupID = g.id
        cleanupGroups()
    }

    func renameGroup(_ id: UUID, _ name: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        groups[i].name = trimmed.isEmpty ? groups[i].name : trimmed
        groups[i].site = nil // a renamed group is yours now
    }

    func toggleCollapsed(_ id: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].collapsed.toggle()
        if groups[i].collapsed, let current, current.groupID == id,
           let next = tabs.first(where: { $0.groupID != id && !$0.isPinned }) ?? tabs.first(where: { $0.groupID != id }) {
            select(next)
        }
    }

    func setColor(_ id: UUID, _ color: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[i].color = color
    }

    func ungroup(_ id: UUID) {
        for t in tabs where t.groupID == id { t.groupID = nil }
        groups.removeAll { $0.id == id }
        normalizeOrder()
    }

    func removeFromGroup(_ tab: Tab) {
        tab.groupID = nil
        cleanupGroups()
    }

    func closeGroup(_ id: UUID) {
        for t in tabs where t.groupID == id { close(t) }
        groups.removeAll { $0.id == id }
    }

    /// Drops empty groups (and site groups down to one tab) and keeps members together.
    func cleanupGroups() {
        for g in groups {
            let count = tabs.filter { $0.groupID == g.id }.count
            if count == 0 || (g.site != nil && count < 2) {
                for t in tabs where t.groupID == g.id { t.groupID = nil }
                groups.removeAll { $0.id == g.id }
            }
        }
        normalizeOrder()
    }

    /// Groups three or more ungrouped tabs from the same site under the site's name.
    func autoOrganize() {
        var bySite: [String: [Tab]] = [:]
        for t in tabs where !t.isPinned {
            guard let host = t.host, ["http", "https"].contains(t.url?.scheme ?? "") else { continue }
            let auto = t.groupID.flatMap { g in groups.first { $0.id == g } }?.site
            if t.groupID != nil && auto == nil { continue } // grouped by you: leave it alone
            bySite[PasswordStore.site(host), default: []].append(t)
        }
        var changed = false
        for (site, members) in bySite where members.count >= 3 {
            let group: TabGroup
            if let existing = groups.first(where: { $0.site == site }) {
                group = existing
            } else {
                group = TabGroup(name: Self.siteName(site), color: groups.count, site: site)
                groups.append(group)
            }
            for t in members where t.groupID != group.id { t.groupID = group.id; changed = true }
        }
        if changed { cleanupGroups() }
    }

    static func siteName(_ site: String) -> String {
        let brands = ["github": "GitHub", "youtube": "YouTube", "stackoverflow": "Stack Overflow", "linkedin": "LinkedIn",
                      "gitlab": "GitLab", "icloud": "iCloud", "chatgpt": "ChatGPT", "openai": "OpenAI", "x": "X",
                      "duckduckgo": "DuckDuckGo", "wikipedia": "Wikipedia", "tiktok": "TikTok", "paypal": "PayPal",
                      "ebay": "eBay", "whatsapp": "WhatsApp", "soundcloud": "SoundCloud", "deviantart": "DeviantArt"]
        let name = String(site.split(separator: ".").first ?? Substring(site))
        return brands[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
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
        let days = Settings.shared.autoCloseDays
        if days > 0 {
            let old = Date().addingTimeInterval(-Double(days) * 86_400)
            for t in tabs where !t.isPinned && !t.isSelected && !t.isPlayingAudio && t.lastActive < old { close(t) }
        }
        var minutes = Double(Settings.shared.hibernateMinutes)
        guard minutes > 0 else { return }
        // In Low Power Mode background tabs go to sleep three times sooner.
        if Power.shared.lowPower { minutes = max(2, minutes / 3) }
        hibernate(idleFor: minutes * 60)
    }

    /// Hibernates background tabs unused for `seconds`, except ones playing sound.
    func hibernate(idleFor seconds: TimeInterval) {
        let cutoff = Date().addingTimeInterval(-seconds)
        for t in tabs where !t.isSelected && !t.isHibernated && !t.isPlayingAudio && t.lastActive <= cutoff {
            t.hibernate()
        }
    }

    func hibernateOthers() { hibernate(idleFor: 0) }

    // MARK: Window lock

    /// True when the user locked the window from the File menu, so the lock waits for them instead of asking right away.
    @Published private(set) var lockedByUser = false

    /// Covers the window until Touch ID or the Mac password unlocks it.
    func lock() {
        guard !locked else { return }
        paletteVisible = false
        findVisible = false
        lockedByUser = true
        locked = true
        // Keys typed while locked must not reach the page underneath.
        window?.makeFirstResponder(nil)
    }

    private var unlocking = false

    func unlock() {
        guard locked, !unlocking else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { finishUnlock(); return }
        unlocking = true
        let reason = L(isPrivate ? "unlock your private window" : "unlock this window")
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                self.unlocking = false
                if ok { self.finishUnlock() }
            }
        }
    }

    private func finishUnlock() {
        locked = false
        lockedByUser = false
    }

    // MARK: Spare web view

    /// A web view built ahead of time, so the next new tab doesn't wait while one is made and its scripts are set up.
    private var spare: LumenWebView?
    private var spareObserver: NSObjectProtocol?

    func takeSpareWebView() -> LumenWebView? {
        let wv = spare
        spare = nil
        prepareSpare()
        return wv
    }

    private func prepareSpare() {
        // Low Power Mode skips it: the next tab builds its own when it's needed.
        guard !Power.shared.lowPower, !WebApp.isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.spare == nil, !Power.shared.lowPower else { return }
            self.spare = LumenWebView(frame: .zero, configuration: Tab.configuration(store: self.dataStore))
        }
    }

    // MARK: Overlays

    func showPalette(_ prefill: String? = nil) {
        guard !locked else { return }
        palettePrefill = prefill ?? current?.url?.absoluteString ?? ""
        findVisible = false
        paletteVisible = true
    }

    func showFind() {
        paletteVisible = false
        findVisible = true
    }
}
