import Foundation

/// Arc keeps what people care about most outside its Chromium data: Spaces, Favorites, pinned tabs and folders
/// live in StorableSidebar.json. This reads that file and rebuilds it in a Tacet window: Favorites become pinned
/// tabs, each Space a tab group, and each folder a group named after its Space. Tabs load only when opened.
enum ArcImport {
    static let bundleID = "company.thebrowser.Browser"

    static var sidebarFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Arc/StorableSidebar.json")
    }

    struct SavedTab: Equatable {
        var title: String
        var url: URL
    }

    struct Group: Equatable {
        var name: String
        var tabs: [SavedTab]
    }

    struct Sidebar: Equatable {
        var favorites: [SavedTab] = []
        var groups: [Group] = []
        var tabCount: Int { favorites.count + groups.reduce(0) { $0 + $1.tabs.count } }
    }

    /// Reads the Spaces of one Arc profile ("Default", "Profile 1"…), or of every profile when `profile` is nil.
    /// Today's unpinned tabs come too when `includeToday` is on, in a group of their own per Space.
    static func read(_ data: Data, profile: String?, includeToday: Bool) throws -> Sidebar {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (json["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil && $0["items"] != nil }) else {
            throw BrowserImporter.ImportError.unreadable("StorableSidebar.json")
        }
        // Both lists alternate an ID string and the object it names; only the objects matter.
        let items = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var byID: [String: [String: Any]] = [:]
        for item in items { if let id = item["id"] as? String { byID[id] = item } }

        func tab(_ item: [String: Any]) -> SavedTab? {
            guard let t = (item["data"] as? [String: Any])?["tab"] as? [String: Any],
                  let raw = t["savedURL"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            let title = (item["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (t["savedTitle"] as? String) ?? raw
            return SavedTab(title: title, url: url)
        }
        func children(_ id: String) -> [[String: Any]] {
            (byID[id]?["childrenIds"] as? [String] ?? []).compactMap { byID[$0] }
        }
        /// The tabs right inside a container or folder, and its folders (any depth) as their own groups.
        func collect(_ id: String, name: String, into groups: inout [Group], depth: Int = 0) -> [SavedTab] {
            var direct: [SavedTab] = []
            for child in children(id) {
                if let t = tab(child) {
                    direct.append(t)
                } else if depth < 8, let folderID = child["id"] as? String, child["childrenIds"] != nil {
                    let folderName = (child["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("Folder")
                    let full = name + " · " + folderName
                    // The folder's group goes before the groups of the folders inside it.
                    let at = groups.count
                    let inside = collect(folderID, name: full, into: &groups, depth: depth + 1)
                    if !inside.isEmpty { groups.insert(Group(name: full, tabs: inside), at: at) }
                }
            }
            return direct
        }

        var out = Sidebar()
        // Favorites: the icons at the top, shared by every Space of a profile.
        for container in items where isTopApps(container, profile: profile) {
            if let id = container["id"] as? String { out.favorites += children(id).compactMap(tab) }
        }
        for space in (main["spaces"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            guard matches(space["profile"], profile) else { continue }
            let ids = space["containerIDs"] as? [String] ?? []
            func container(_ kind: String) -> String? {
                guard let i = ids.firstIndex(of: kind), i + 1 < ids.count else { return nil }
                return ids[i + 1]
            }
            let title = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? L("Space")
            let name = emoji(space).map { "\($0) \(title)" } ?? title
            var groups: [Group] = []
            if let pinned = container("pinned") {
                let direct = collect(pinned, name: name, into: &groups)
                if !direct.isEmpty { groups.insert(Group(name: name, tabs: direct), at: 0) }
            }
            if includeToday, let today = container("unpinned") {
                var nested: [Group] = []
                let direct = collect(today, name: name, into: &nested)
                let all = direct + nested.flatMap(\.tabs)
                if !all.isEmpty { groups.append(Group(name: String(format: L("%@ · Today"), name), tabs: all)) }
            }
            out.groups += groups
        }
        return out
    }

    private static func isTopApps(_ item: [String: Any], profile: String?) -> Bool {
        guard let kind = ((item["data"] as? [String: Any])?["itemContainer"] as? [String: Any])?["containerType"] as? [String: Any],
              let top = kind["topApps"] as? [String: Any] else { return false }
        return matches(top["_0"], profile)
    }

    /// Arc names a profile as {"default": …} or {"custom": {"_0": {"directoryBasename": "Profile 1"}}}.
    private static func matches(_ value: Any?, _ profile: String?) -> Bool {
        guard let profile else { return true }
        guard let p = value as? [String: Any] else { return profile == "Default" }
        if p["default"] != nil { return profile == "Default" }
        let custom = ((p["custom"] as? [String: Any])?["_0"] as? [String: Any])?["directoryBasename"] as? String
        return custom == profile
    }

    private static func emoji(_ space: [String: Any]) -> String? {
        let icon = (space["customInfo"] as? [String: Any])?["iconType"] as? [String: Any]
        return (icon?["emoji_v2"] as? String) ?? (icon?["emoji"] as? String)
    }
}

extension BrowserState {
    /// Adds what was read from Arc: Favorites as pinned tabs, then one group per Space and folder, none loaded yet.
    /// Addresses already open here are skipped. Returns how many tabs were added.
    @discardableResult
    func adopt(_ arc: ArcImport.Sidebar) -> Int {
        var open = Set(tabs.compactMap { $0.url?.absoluteString })
        var added = 0
        for f in arc.favorites where open.insert(f.url.absoluteString).inserted {
            tabs.append(Tab(browser: self, url: f.url, title: f.title, pinned: true))
            added += 1
        }
        for (n, g) in arc.groups.enumerated() {
            let fresh = g.tabs.filter { open.insert($0.url.absoluteString).inserted }
            guard !fresh.isEmpty else { continue }
            // Folded, so a big Arc sidebar doesn't fill the whole tab list at once.
            let group = TabGroup(name: g.name, collapsed: true, color: (groups.count + n) % TabGroup.colors.count)
            groups.append(group)
            for t in fresh {
                let tab = Tab(browser: self, url: t.url, title: t.title)
                tab.groupID = group.id
                tabs.append(tab)
            }
            added += fresh.count
        }
        normalizeOrder()
        return added
    }
}
