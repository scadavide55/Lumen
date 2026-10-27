import AppKit
import Observation

// MARK: - Saved groups

/// A tab group put away to open again later, with all its tabs.
struct SavedGroup: Codable, Identifiable, Equatable {
    struct SavedTab: Codable, Equatable {
        var url: URL
        var title: String
    }

    var id = UUID()
    var name: String
    var color: Int
    var date = Date()
    var tabs: [SavedTab]
}

@Observable
final class SavedGroups {
    static let shared = SavedGroups()
    private(set) var items: [SavedGroup] = []
    @ObservationIgnored private let file = StoredFile<[SavedGroup]>("savedGroups.json")

    private init() { items = file.load() ?? [] }

    func add(_ group: SavedGroup) {
        items.insert(group, at: 0)
        file.saveNow(items)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        file.saveNow(items)
    }
}

// MARK: - Moving tabs between windows

/// Tabs on their way to another window, as snapshots, since each window has its own web views and site data.
struct TabMove {
    var tabs: [TabSnapshot]
    /// The group they were in, recreated in the other window.
    var group: (name: String, color: Int)?
}

extension WindowRegistry {
    /// Tabs waiting for the window that is being opened for them.
    private static var pendingMove: (move: TabMove, profile: UUID?)?

    func setPendingMove(_ move: TabMove, profile: UUID?) { Self.pendingMove = (move, profile) }

    func takePendingMove(profile: UUID?) -> TabMove? {
        guard let p = Self.pendingMove, p.profile == profile else { return nil }
        Self.pendingMove = nil
        return p.move
    }

    /// Other normal windows that tabs can be moved into.
    func destinations(from b: BrowserState) -> [BrowserState] {
        browsers.filter { $0 !== b && !$0.isPrivate }
    }
}

// MARK: - Organising

extension BrowserState {
    enum TabSort: String, CaseIterable, Identifiable {
        case site, title, recent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .site: L("By Site")
            case .title: L("By Title")
            case .recent: L("By Last Opened")
            }
        }
    }

    /// The keys held for the click being handled, read from the click itself.
    static var clickModifiers: NSEvent.ModifierFlags {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).intersection([.command, .shift])
    }

    /// Tabs in the order the tab list shows them.
    var orderedTabs: [Tab] { pinnedTabs + regularTabs }

    // MARK: Picking several tabs

    /// A click on a tab: ⌘ adds or removes it from the picked tabs, ⇧ picks the range from the last one, a plain click selects it.
    func click(_ tab: Tab, modifiers: NSEvent.ModifierFlags = BrowserState.clickModifiers) {
        if modifiers.contains(.command) {
            if marked.isEmpty, let c = selectedID { marked.insert(c) }
            if marked.contains(tab.id) { marked.remove(tab.id) } else { marked.insert(tab.id) }
            markAnchor = tab.id
            if marked.count <= 1 && marked.contains(selectedID ?? UUID()) { marked = [] }
        } else if modifiers.contains(.shift) {
            let order = orderedTabs.map(\.id)
            let anchor = markAnchor ?? selectedID
            guard let a = anchor.flatMap({ order.firstIndex(of: $0) }), let z = order.firstIndex(of: tab.id) else { select(tab); return }
            marked = Set(order[min(a, z)...max(a, z)])
            if marked.count <= 1 { marked = [] }
        } else {
            marked = []
            markAnchor = tab.id
            select(tab)
        }
    }

    /// The tabs a menu on `tab` acts on: all picked tabs when it's one of them, otherwise just it.
    func actionTabs(for tab: Tab) -> [Tab] {
        guard marked.count > 1, marked.contains(tab.id) else { return [tab] }
        return orderedTabs.filter { marked.contains($0.id) }
    }

    /// What dragging a tab carries: every picked tab when it's one of them, one per line.
    func dragPayload(for tab: Tab) -> String {
        actionTabs(for: tab).map(\.id.uuidString).joined(separator: "\n")
    }

    func close(_ list: [Tab]) {
        marked = []
        for t in list { close(t) }
    }

    func setPinned(_ list: [Tab], _ pinned: Bool) {
        for t in list {
            t.isPinned = pinned
            if pinned { t.groupID = nil }
        }
        marked = []
        cleanupGroups()
    }

    // MARK: Groups

    /// Puts tabs into a new group, or into the existing group with that name.
    @discardableResult
    func group(_ list: [Tab], named name: String? = nil) -> TabGroup? {
        let members = list.filter { tabs.contains($0) }
        guard let first = members.first else { return nil }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let group: TabGroup
        if !trimmed.isEmpty, let existing = groups.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            group = existing
        } else {
            let sites = Set(members.compactMap { $0.host.map(PasswordStore.site) })
            let fallback = sites.count == 1 ? Self.siteName(sites.first!) : L("New Group")
            group = TabGroup(name: trimmed.isEmpty ? fallback : trimmed, color: groups.count)
            groups.append(group)
        }
        // The group goes where its first tab was.
        let anchor = tabs.firstIndex { $0.id == first.id } ?? tabs.count
        for t in members {
            t.isPinned = false
            t.groupID = group.id
        }
        let ids = Set(members.map(\.id))
        var rest = tabs.filter { !ids.contains($0.id) }
        let at = min(rest.count, tabs[..<anchor].filter { !ids.contains($0.id) }.count)
        rest.insert(contentsOf: members, at: at)
        tabs = rest
        marked = []
        cleanupGroups()
        return group
    }

    func move(_ list: [Tab], toGroup id: UUID) {
        guard let g = groups.first(where: { $0.id == id }) else { return }
        group(list, named: g.name)
    }

    /// A new tab at the end of a group.
    func newTab(inGroup id: UUID) {
        guard groups.contains(where: { $0.id == id }) else { return }
        if let i = groups.firstIndex(where: { $0.id == id }), groups[i].collapsed { groups[i].collapsed = false }
        let last = tabs.last { $0.groupID == id }
        let t = newTab(after: last)
        t.groupID = id
        normalizeOrder()
        if Settings.shared.paletteOnNewTab { showPalette("") }
    }

    /// Undoes site groups for sites the user excluded. Returns whether anything changed.
    @discardableResult
    func dropExceptedGroups() -> Bool {
        var changed = false
        for g in groups where g.site.map({ Settings.shared.groupExceptions.contains($0) }) == true {
            for t in tabs where t.groupID == g.id { t.groupID = nil }
            groups.removeAll { $0.id == g.id }
            changed = true
        }
        if changed { normalizeOrder() }
        return changed
    }

    /// The grouping settings changed: every window follows them.
    static func groupingChanged() {
        for b in WindowRegistry.shared.browsers {
            if Settings.shared.organizeTabs { b.autoOrganize() } else { b.dropExceptedGroups() }
        }
    }

    /// Groups tabs by site right away, as many as the threshold asks, whether or not Lumen does it automatically.
    func groupBySiteNow() {
        marked = []
        autoOrganize()
    }

    /// Closes a group and keeps it to open again later.
    func saveAndClose(_ id: UUID) {
        guard !isPrivate, let g = groups.first(where: { $0.id == id }) else { return }
        let members = tabs.filter { $0.groupID == id }
        let saved = members.compactMap { t in t.url.map { SavedGroup.SavedTab(url: $0, title: t.title) } }
        if !saved.isEmpty { SavedGroups.shared.add(SavedGroup(name: g.name, color: g.color, tabs: saved)) }
        closeGroup(id)
    }

    /// Opens a saved group in this window, and forgets it.
    func open(_ saved: SavedGroup) {
        guard !saved.tabs.isEmpty else { SavedGroups.shared.remove(saved.id); return }
        let group = TabGroup(name: saved.name, color: saved.color)
        groups.append(group)
        let opened = saved.tabs.map { s -> Tab in
            let t = Tab(browser: self, url: s.url, title: s.title)
            t.groupID = group.id
            return t
        }
        tabs.append(contentsOf: opened)
        normalizeOrder()
        if let first = opened.first { select(first) }
        SavedGroups.shared.remove(saved.id)
    }

    // MARK: Duplicates and order

    /// How many tabs show an address that an earlier tab already shows.
    var duplicateCount: Int {
        var seen = Set<String>()
        var count = 0
        for t in tabs {
            guard let key = t.url?.absoluteString else { continue }
            if !seen.insert(key).inserted { count += 1 }
        }
        return count
    }

    /// Sorts the tabs that aren't pinned; each group stays together where its first tab lands.
    func sortTabs(by order: TabSort) {
        let regular = regularTabs.sorted { a, b in
            switch order {
            case .site:
                let sa = a.host.map(PasswordStore.site) ?? "~", sb = b.host.map(PasswordStore.site) ?? "~"
                return sa != sb ? sa < sb : a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .title:
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            case .recent:
                return (a.id == selectedID ? Date.distantFuture : a.lastActive) > (b.id == selectedID ? Date.distantFuture : b.lastActive)
            }
        }
        tabs = pinnedTabs + regular
        normalizeOrder()
    }

    // MARK: Moving to another window

    /// Takes tabs out of this window without adding them to recently closed tabs. Going to another profile,
    /// a tab leaves its page history behind (which can hold what was typed into forms) and loads its address afresh.
    private func detach(_ list: [Tab], keepHistory: Bool) -> [TabSnapshot] {
        let snaps = list.map { t -> TabSnapshot in
            var s = t.snapshot()
            s.group = nil
            if !keepHistory { s.state = nil }
            return s
        }
        let ids = Set(list.map(\.id))
        let wasSelected = selectedID.map(ids.contains) ?? false
        let firstIndex = tabs.firstIndex { ids.contains($0.id) } ?? 0
        for t in list { t.close() }
        tabs.removeAll { ids.contains($0.id) }
        if let s = splitID, ids.contains(s) { splitID = nil }
        marked = []
        cleanupGroups()
        if tabs.isEmpty {
            newTab()
        } else if wasSelected {
            select(tabs[min(firstIndex, tabs.count - 1)])
        }
        return snaps
    }

    /// Adds moved tabs, in their group if they came with one.
    func adopt(_ move: TabMove) {
        var groupID: UUID?
        if let g = move.group {
            let new = TabGroup(name: g.name, color: g.color)
            groups.append(new)
            groupID = new.id
        }
        let opened = move.tabs.map { s -> Tab in
            let t = Tab(browser: self, url: s.url, title: s.title, state: s.state, pinned: groupID == nil && s.pinned)
            t.groupID = groupID
            return t
        }
        // A window opened just for these tabs drops its empty start tab.
        if tabs.count == 1, let only = tabs.first, only.isStartPage { tabs = []; only.close() }
        tabs.append(contentsOf: opened)
        normalizeOrder()
        if let first = opened.first { select(first) }
        window?.makeKeyAndOrderFront(nil)
    }

    func move(_ list: [Tab], group: TabGroup?, to other: BrowserState) {
        guard other !== self, !isPrivate, !other.isPrivate else { return }
        other.adopt(TabMove(tabs: detach(list, keepHistory: other.profileID == profileID), group: group.map { ($0.name, $0.color) }))
    }

    /// Sends tabs to a window that is about to open in `profile` (nil for the main one); the caller opens it.
    func prepareMove(_ list: [Tab], group: TabGroup?, profile: UUID?) {
        guard !isPrivate else { return }
        WindowRegistry.shared.setPendingMove(TabMove(tabs: detach(list, keepHistory: profile == profileID), group: group.map { ($0.name, $0.color) }),
                                             profile: profile)
    }
}
