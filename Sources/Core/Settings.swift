import SwiftUI
import WebKit

extension Notification.Name {
    static let settingChanged = Notification.Name("lumen.settingChanged")
}

// MARK: - Option types

enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { L(["system": "System", "light": "Light", "dark": "Dark"][rawValue]!) }
}

enum TabLayout: String, Codable, CaseIterable, Identifiable {
    case vertical, horizontal, compact
    var id: String { rawValue }
    var label: String { L(["vertical": "Sidebar", "horizontal": "Separate", "compact": "Compact"][rawValue]!) }
}

enum SidebarSide: String, Codable, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var label: String { L(self == .left ? "Left" : "Right") }
}

enum ChromeStyle: String, Codable, CaseIterable, Identifiable {
    case translucent, solid, tinted
    var id: String { rawValue }
    var label: String { L(["translucent": "Translucent", "solid": "Solid", "tinted": "Tinted"][rawValue]!) }
}

enum StartBackground: String, Codable, CaseIterable, Identifiable {
    case aurora, dusk, ocean, forest, ember, graphite, flow, accent, plain, image, video
    var id: String { rawValue }
    var label: String { L(["plain": "Plain", "flow": "Flow (animated)"][rawValue] ?? rawValue.capitalized) }
    var isGradient: Bool { ![.plain, .image, .video, .accent].contains(self) }
}

enum PopupMode: String, Codable, CaseIterable, Identifiable {
    case never, automatic, always
    var id: String { rawValue }
    var label: String { L(["never": "Never", "automatic": "Automatically", "always": "Always"][rawValue]!) }
}

enum NewTabPosition: String, Codable, CaseIterable, Identifiable {
    case afterCurrent, end
    var id: String { rawValue }
    var label: String { L(self == .end ? "At the end" : "Next to current tab") }
}

enum UserAgentMode: String, Codable, CaseIterable, Identifiable {
    case safari, custom
    var id: String { rawValue }
    var label: String { L(self == .safari ? "Safari (recommended)" : "Custom") }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckduckgo, google, bing, brave, startpage, ecosia, kagi, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckduckgo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .startpage: "Startpage"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .custom: L("Custom")
        }
    }

    /// Search URL with `%s` standing for the query.
    var template: String {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/?q=%s"
        case .google: "https://www.google.com/search?q=%s"
        case .bing: "https://www.bing.com/search?q=%s"
        case .brave: "https://search.brave.com/search?q=%s"
        case .startpage: "https://www.startpage.com/do/search?q=%s"
        case .ecosia: "https://www.ecosia.org/search?q=%s"
        case .kagi: "https://kagi.com/search?q=%s"
        case .custom: Settings.shared.customSearch
        }
    }

    /// Suggestion endpoint returning OpenSearch JSON (`["query", ["a", "b"]]`).
    var suggestTemplate: String? {
        switch self {
        case .duckduckgo: "https://duckduckgo.com/ac/?q=%s&type=list"
        case .google: "https://suggestqueries.google.com/complete/search?client=firefox&q=%s"
        case .bing: "https://api.bing.com/osjson.aspx?query=%s"
        case .brave: "https://search.brave.com/api/suggest?q=%s"
        case .ecosia: "https://ac.ecosia.org/autocomplete?q=%s&type=list"
        default: nil
        }
    }
}

struct SearchShortcut: Codable, Identifiable, Hashable {
    var id = UUID()
    var keyword: String
    var name: String
    var template: String
}

/// A separate set of cookies, sign-ins and site data, for windows opened in it.
struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color = 0
    var tint: Color { TabGroup.colors[color % TabGroup.colors.count] }
}

/// Deleting a profile's cookies and site data.
enum ProfileCleanup {
    private static let key = "lumen.profilesToRemove"

    /// Erases the profile's data right away. WebKit only gives up the profile's folder once Lumen
    /// restarts, so removing the folder itself may wait until then.
    static func remove(_ id: UUID) {
        let store = WKWebsiteDataStore(forIdentifier: id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            _ = store
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if error != nil { DispatchQueue.main.async { pending.append(id.uuidString) } }
            }
        }
    }

    /// Removes folders left by profiles deleted last time. It runs once a page has loaded,
    /// because WebKit crashes when asked to remove a profile before it has started.
    static func finishPending() {
        let ids = pending.compactMap(UUID.init)
        guard !ids.isEmpty else { return }
        guard WindowRegistry.shared.browsers.contains(where: { $0.current?.webView != nil }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finishPending() }
            return
        }
        pending = []
        for id in ids {
            WKWebsiteDataStore.remove(forIdentifier: id) { error in
                if error != nil { DispatchQueue.main.async { pending.append(id.uuidString) } }
            }
        }
    }

    private static var pending: [String] {
        get { UserDefaults.standard.stringArray(forKey: key) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

enum MediaPermission {
    enum Kind: String {
        case camera, microphone, both

        init(_ type: WKMediaCaptureType) {
            switch type {
            case .camera: self = .camera
            case .microphone: self = .microphone
            default: self = .both
            }
        }

        var label: String { L(["camera": "camera", "microphone": "microphone", "both": "camera and microphone"][rawValue]!) }
    }

    static func key(host: String, kind: Kind) -> String { host.lowercased() + "|" + kind.rawValue }

    /// Splits a stored key back into its site and what it's for.
    static func parse(_ key: String) -> (host: String, kind: Kind)? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = Kind(rawValue: parts[1]) else { return nil }
        return (parts[0], kind)
    }
}

struct SiteStyle: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var css: String
    var enabled = true
}

// MARK: - Persisted preference wrapper

/// Stores a Codable value in UserDefaults and publishes changes through the
/// enclosing `Settings` object.
@propertyWrapper
struct Pref<Value: Codable> {
    let key: String
    var value: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        if let data = UserDefaults.standard.data(forKey: "lumen." + key),
           let v = try? JSONDecoder().decode(Value.self, from: data) {
            value = v
        } else {
            value = wrappedValue
        }
    }

    @available(*, unavailable, message: "Pref can only be used inside Settings")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript(
        _enclosingInstance s: Settings,
        wrapped _: ReferenceWritableKeyPath<Settings, Value>,
        storage k: ReferenceWritableKeyPath<Settings, Pref<Value>>
    ) -> Value {
        get { s[keyPath: k].value }
        set {
            s.objectWillChange.send()
            s[keyPath: k].value = newValue
            let key = s[keyPath: k].key
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "lumen." + key)
            }
            s.didChange(key)
        }
    }
}

// MARK: - Settings

final class Settings: ObservableObject {
    static let shared = Settings()

    // Appearance
    @Pref("theme") var theme = ThemeMode.system
    @Pref("accent") var accentHex = "#5E5CE6"
    @Pref("tabLayout") var tabLayout = TabLayout.vertical
    @Pref("sidebarSide") var sidebarSide = SidebarSide.left
    @Pref("chromeStyle") var chromeStyle = ChromeStyle.translucent
    @Pref("sidebarWidth") var sidebarWidth = 240.0
    @Pref("sidebarVisible") var sidebarVisible = true
    @Pref("addressInSidebar") var addressInSidebar = true
    @Pref("insetContent") var insetContent = true
    @Pref("cornerRadius") var cornerRadius = 10.0
    @Pref("siteTint") var siteTint = true
    @Pref("compactTabs") var compactTabs = false
    @Pref("showFullURL") var showFullURL = false
    @Pref("statusBar") var statusBar = true

    // Start page
    @Pref("startBackground") var startBackground = StartBackground.aurora
    @Pref("startImage") var startImagePath = ""
    @Pref("startVideo") var startVideoPath = ""
    @Pref("animateBackground") var animateBackground = false
    @Pref("showClock") var showClock = true
    @Pref("showGreeting") var showGreeting = true
    @Pref("userName") var userName = ""
    @Pref("showFavorites") var showFavorites = true

    // Tabs
    @Pref("hibernate") var hibernateMinutes = 15
    @Pref("newTabPosition") var newTabPosition = NewTabPosition.afterCurrent
    @Pref("restoreSession") var restoreSession = true
    @Pref("blockAutoplay") var blockAutoplay = true
    @Pref("checkUpdates") var checkUpdates = true
    @Pref("paletteOnNewTab") var paletteOnNewTab = true
    @Pref("organizeTabs") var organizeTabs = false
    @Pref("popupMode") var popupMode = PopupMode.automatic
    @Pref("autoCloseDays") var autoCloseDays = 0
    @Pref("alwaysShowTitles") var alwaysShowTitles = false
    @Pref("pullToRefresh") var pullToRefresh = true
    @Pref("profiles") var profiles: [Profile] = []
    @Pref("onboarded") var onboarded = false

    // Search
    @Pref("engine") var engine = SearchEngine.duckduckgo
    @Pref("customSearch") var customSearch = "https://duckduckgo.com/?q=%s"
    @Pref("suggestions") var suggestions = false
    @Pref("shortcuts") var shortcuts: [SearchShortcut] = [
        SearchShortcut(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query=%s"),
        SearchShortcut(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/wiki/Special:Search?search=%s"),
        SearchShortcut(keyword: "gh", name: "GitHub", template: "https://github.com/search?q=%s"),
        SearchShortcut(keyword: "maps", name: "Maps", template: "https://maps.apple.com/?q=%s"),
        SearchShortcut(keyword: "r", name: "Reddit", template: "https://www.reddit.com/search/?q=%s"),
    ]

    // Shield
    @Pref("adBlock") var adBlock = true
    @Pref("easyList") var easyList = false
    @Pref("easyPrivacy") var easyPrivacy = false
    @Pref("youtubeAds") var youtubeAds = true
    @Pref("cookieBanners") var hideCookieBanners = true
    @Pref("thirdPartyCookies") var blockThirdPartyCookies = true
    @Pref("stripTracking") var stripTracking = true
    @Pref("httpsUpgrade") var httpsUpgrade = true
    @Pref("gpc") var gpc = true
    @Pref("clearOnQuit") var clearOnQuit = false
    @Pref("allowlist") var allowlist: [String] = []

    // Passwords and security
    @Pref("savePasswords") var savePasswords = true
    @Pref("autofillPasswords") var autofillPasswords = true
    @Pref("strongPasswords") var suggestStrongPasswords = false
    @Pref("passwordManager") var passwordManager = ""
    @Pref("neverSave") var neverSaveHosts: [String] = []
    @Pref("httpsOnly") var httpsOnly = false
    @Pref("confirmDownloads") var confirmDangerousDownloads = true
    @Pref("lockPrivate") var lockPrivateWindows = true

    // Sites
    @Pref("siteStyles") var siteStyles: [SiteStyle] = []
    @Pref("siteZoom") var siteZoom: [String: Double] = [:]
    @Pref("defaultZoom") var defaultZoom = 1.0
    /// Camera and microphone choices per site, keyed by `MediaPermission.key`.
    @Pref("mediaPermissions") var mediaPermissions: [String: Bool] = [:]
    @Pref("forceDark") var forceDark = false

    // Advanced
    @Pref("developer") var developer = false
    @Pref("javaScript") var javaScript = true
    @Pref("uaMode") var uaMode = UserAgentMode.safari
    @Pref("customUA") var customUA = ""
    @Pref("askDownload") var askDownloadLocation = false

    var accent: Color { Color(hex: accentHex) }

    var accentBinding: Binding<Color> {
        Binding(get: { Color(hex: self.accentHex) },
                set: { self.accentHex = $0.hexString })
    }

    func isAllowlisted(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowlist.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setAllowlisted(_ host: String, _ allowed: Bool) {
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
        var list = allowlist.filter { $0 != h }
        if allowed { list.append(h) }
        allowlist = list.sorted()
    }

    func didChange(_ key: String) {
        if key == "theme" { applyTheme() }
        NotificationCenter.default.post(name: .settingChanged, object: self, userInfo: ["key": key])
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Language

/// Looks up a translation for text that isn't a SwiftUI string literal.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, it, fr
    var id: String { rawValue }

    /// Each language is named in itself, so it can be found in any locale.
    var label: String {
        switch self {
        case .system: L("System")
        case .en: "English"
        case .it: "Italiano"
        case .fr: "Français"
        }
    }

    static var current: AppLanguage {
        guard let list = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = list.first else { return .system }
        return AppLanguage(rawValue: String(first.prefix(2))) ?? .system
    }

    /// Takes effect the next time Lumen starts.
    func apply() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        Session.shared.saveNow()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: - User agent

enum UserAgent {
    /// The installed Safari's version, so sites treat Lumen like current Safari.
    static let safariVersion: String = {
        let url = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: url),
              let v = dict["CFBundleShortVersionString"] as? String else { return "18.0" }
        return v.split(separator: ".").prefix(2).joined(separator: ".")
    }()

    static let applicationName = "Version/\(safariVersion) Safari/605.1.15"

    static var custom: String? {
        let s = Settings.shared
        return s.uaMode == .custom && !s.customUA.isEmpty ? s.customUA : nil
    }
}

// MARK: - Color helpers

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0x5E5CE6
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }

    var hexString: String {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return "#5E5CE6" }
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)),
                      Int(round(c.blueComponent * 255)))
    }
}

extension NSColor {
    /// Relative luminance in 0...1.
    var luminance: Double {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}
