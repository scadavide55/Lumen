import AppKit

/// "When I open github.com, use the Coding profile": where links to a site open, so profiles, Spaces and private
/// windows don't have to be picked by hand each time.
///
/// Rules apply to links from other apps, addresses typed in the command bar, and links opened in a new tab (⌘-click
/// or a link that opens a new tab). Never to links followed inside a page, redirects or sign-in pop-ups, so they can't
/// break a sign-in. Right-click › Open Link in New Tab always opens the link right there.
struct OpeningRule: Codable, Identifiable, Equatable {
    enum Action: Codable, Equatable, Hashable {
        /// Switch to a tab already on the site (a pinned one first) instead of opening another.
        case reuseTab
        case privateWindow
        /// A profile's window; nil is the main profile.
        case profile(UUID?)
        case space(UUID)
    }

    var id = UUID()
    /// A site such as github.com; its subdomains match too.
    var site: String
    var action: Action
    var enabled = true

    func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == site || host.hasSuffix("." + site)
    }

    /// "github.com" from whatever was typed: an address, a host, with or without www.
    static func normalizedSite(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let host = URL(string: text.contains("://") ? text : "https://" + text)?.host { text = host }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        return text.contains(".") && !text.contains(" ") ? text : nil
    }
}

enum OpeningRules {
    /// The rule for a link, if one applies.
    static func rule(for url: URL) -> OpeningRule? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return Settings.shared.openingRules.first { $0.enabled && $0.matches(url) }
    }

    /// Opens the link where its rule says, and returns true; false means no rule took it (or it already is where the
    /// rule wants), and the caller opens it as usual.
    static func route(_ url: URL, from b: BrowserState?) -> Bool {
        guard !WebApp.isActive, let rule = rule(for: url) else { return false }
        let reg = WindowRegistry.shared
        switch rule.action {
        case .reuseTab:
            let windows = ([b].compactMap { $0 } + reg.browsers.filter { $0 !== b }).filter { !$0.isPrivate || $0 === b }
            for w in windows {
                let onSite = w.tabs.filter { $0.url.map(rule.matches) == true || $0.pinnedHome.map(rule.matches) == true }
                guard let t = onSite.first(where: \.isPinned) ?? onSite.first else { continue }
                w.select(t)
                if t.url != url { t.load(url) }
                w.window?.makeKeyAndOrderFront(nil)
                return true
            }
            return false
        case .privateWindow:
            if b?.isPrivate == true { return false }
            if let w = reg.browsers.first(where: { $0.isPrivate && !$0.locked }) {
                w.newTab(url: url)
                w.window?.makeKeyAndOrderFront(nil)
            } else {
                reg.openRouted(url, privately: true, profile: nil)
            }
            return true
        case .profile(let id):
            if let b, !b.isPrivate, b.profileID == id { return false }
            if let w = reg.browsers.first(where: { !$0.isPrivate && $0.profileID == id }) {
                w.newTab(url: url)
                w.window?.makeKeyAndOrderFront(nil)
            } else {
                reg.openRouted(url, privately: false, profile: id)
            }
            return true
        case .space(let id):
            // A Space opens only in a window of its own profile.
            guard let space = Spaces.shared.space(id), b?.spaceID != id else { return false }
            if let w = reg.browsers.first(where: { !$0.isPrivate && $0.spaceID == id }) {
                w.newTab(url: url)
                w.window?.makeKeyAndOrderFront(nil)
            } else if let w = [b].compactMap({ $0 }).first(where: { !$0.isPrivate && $0.profileID == space.profile })
                        ?? reg.browsers.first(where: { !$0.isPrivate && $0.profileID == space.profile }) {
                w.switchSpace(to: id)
                w.newTab(url: url)
                w.window?.makeKeyAndOrderFront(nil)
            } else {
                return false
            }
            return true
        }
    }

    /// "Open in a private window", "Use the Work profile", for the settings list.
    static func describe(_ action: OpeningRule.Action) -> String {
        switch action {
        case .reuseTab: L("Switch to its open tab")
        case .privateWindow: L("Open in a private window")
        case .profile(nil): String(format: L("Use the %@ profile"), L("Main Profile"))
        case .profile(let id?): String(format: L("Use the %@ profile"), Settings.shared.profiles.first { $0.id == id }?.name ?? "?")
        case .space(let id): String(format: L("Open in the %@ Space"), Spaces.shared.space(id)?.name ?? "?")
        }
    }
}
