import AppKit
import Observation
import WebKit

/// Web extensions (macOS 15.4 and later): the same WebExtensions Safari, Chrome and Firefox use. They can be added
/// from a folder, a .zip, .crx or .xpi file, or from the Safari extensions inside apps on this Mac.
/// They never run in private windows, and only get the permissions you approve when adding them.
@Observable
final class Extensions {
    static let shared = Extensions()

    /// What Tacet remembers about an added extension.
    struct Installed: Codable, Identifiable, Equatable {
        enum Source: Codable, Equatable {
            /// Unpacked into Tacet's Extensions folder.
            case folder(String)
            /// A Safari web extension inside an app, by the path of its .appex.
            case appExtension(String)
        }

        var id = UUID()
        var name: String
        var source: Source
        var enabled = true
        /// Its button shows in the toolbar; nil (lists from before) counts as shown.
        var pinned: Bool?
        /// Keeps the extension's storage and address the same between launches.
        var uniqueIdentifier = UUID().uuidString
        var added = Date()
        /// What the user allowed ("p:" permissions, "m:" site patterns) and turned down. Nil for extensions added before
        /// Tacet kept this: what they ask for now counts as allowed, as it was when they were added.
        var approved: [String]?
        var declined: [String]?
    }

    /// A Safari web extension found inside an app on this Mac.
    struct Available: Identifiable, Hashable {
        var id: String { path }
        let path: String
        let name: String
        let appName: String
        let icon: NSImage?
    }

    enum Failure: LocalizedError {
        case unsupportedSystem
        case notAnExtension
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSystem: L("Extensions need macOS 15.4 or later.")
            case .notAnExtension: L("This isn't a web extension: there is no manifest.json inside it.")
            case .unreadable(let why): why
            }
        }
    }

    private(set) var installed: [Installed] = []
    /// Bumped when an extension's button changes (icon, badge, enabled), so toolbars redraw.
    private(set) var revision = 0
    @ObservationIgnored private let index = StoredFile<[Installed]>("Extensions/extensions.json")
    @ObservationIgnored let folder = Paths.folder("Extensions")
    /// Typed loosely so this class works on macOS 14, where extensions don't exist.
    @ObservationIgnored private var storage: AnyObject?

    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private init() {
        installed = index.load() ?? []
    }

    private func persist() { index.saveNow(installed) }

    // MARK: Folders

    /// Copies an unpacked extension, or unpacks a .zip, .crx or .xpi, into Tacet's Extensions folder.
    func importPackage(at url: URL) throws -> URL {
        let target = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw Failure.unreadable(L("The file couldn't be found.")) }
        if isDir.boolValue {
            try fm.copyItem(at: url, to: target)
        } else {
            var data = try Data(contentsOf: url)
            // A Chrome .crx is a zip file after a short signed header.
            if data.starts(with: Array("Cr24".utf8)), data.count > 16 {
                let version = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
                let skip: Int
                if version == 3 {
                    let header = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) })
                    skip = 12 + header
                } else {
                    let key = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) })
                    let sig = Int(data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self) })
                    skip = 16 + key + sig
                }
                guard skip < data.count else { throw Failure.notAnExtension }
                data = data.subdata(in: skip..<data.count)
            }
            let zip = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
            try data.write(to: zip)
            defer { try? fm.removeItem(at: zip) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, target.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { try? fm.removeItem(at: target); throw Failure.unreadable(L("The file couldn't be unpacked.")) }
        }
        // Some packages keep the extension one folder down.
        if !fm.fileExists(atPath: target.appendingPathComponent("manifest.json").path),
           let inner = try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
            .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) {
            return inner
        }
        guard fm.fileExists(atPath: target.appendingPathComponent("manifest.json").path) else {
            try? fm.removeItem(at: target)
            throw Failure.notAnExtension
        }
        return target
    }

    /// Safari web extensions inside the apps in /Applications, which can be added with a click.
    func findAppExtensions() -> [Available] {
        let fm = FileManager.default
        var out: [Available] = []
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        for root in roots {
            for app in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where app.hasSuffix(".app") {
                let plugins = root + "/" + app + "/Contents/PlugIns"
                for appex in (try? fm.contentsOfDirectory(atPath: plugins)) ?? [] where appex.hasSuffix(".appex") {
                    let path = plugins + "/" + appex
                    guard let bundle = Bundle(path: path),
                          let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                          ext["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension" else { continue }
                    let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                        ?? (bundle.infoDictionary?["CFBundleName"] as? String) ?? appex.replacingOccurrences(of: ".appex", with: "")
                    let appName = app.replacingOccurrences(of: ".app", with: "")
                    out.append(Available(path: path, name: name, appName: appName,
                                         icon: NSWorkspace.shared.icon(forFile: root + "/" + app)))
                }
            }
        }
        let added = Set(installed.compactMap { if case .appExtension(let p) = $0.source { p } else { nil } })
        return out.filter { !added.contains($0.path) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Changes

    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].enabled = on
        persist()
        if #available(macOS 15.4, *) { on ? load(installed[i]) : unload(id) }
        revision += 1
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let i = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[i].pinned = pinned
        persist()
        revision += 1
    }

    func remove(_ id: UUID) {
        guard let item = installed.first(where: { $0.id == id }) else { return }
        if #available(macOS 15.4, *) {
            unload(id)
            removeData(of: item)
        }
        installed.removeAll { $0.id == id }
        persist()
        if case .folder(let path) = item.source { discardImported(URL(fileURLWithPath: path)) }
        revision += 1
    }

    /// Deletes a package unpacked by `importPackage`, which may hold the extension one folder down.
    func discardImported(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return }
        let top = url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path ? url : url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: top)
    }

    func noteChange() { revision += 1 }

    /// The web view settings for a page of a loaded extension, by its webkit-extension address.
    static func webViewConfiguration(for url: URL) -> WKWebViewConfiguration? {
        guard #available(macOS 15.4, *) else { return nil }
        return shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    func add(_ item: Installed) {
        installed.append(item)
        persist()
        revision += 1
    }
}

// MARK: - Running extensions (macOS 15.4)

@available(macOS 15.4, *)
extension Extensions {
    /// Tacet's side of the extension runtime: windows, tabs, popups and permission prompts.
    final class Runtime: NSObject, WKWebExtensionControllerDelegate {
        let controller: WKWebExtensionController
        var contexts: [UUID: WKWebExtensionContext] = [:]

        override init() {
            // A fixed identifier keeps extension storage between launches.
            let id = UUID(uuidString: "6C1E0D2A-5B7F-4E2D-9C1A-4C55E7A1B0F3")!
            controller = WKWebExtensionController(configuration: WKWebExtensionController.Configuration(identifier: id))
            super.init()
            controller.delegate = self
        }

        // MARK: Windows and tabs

        private var windows: [BrowserState] { WindowRegistry.shared.browsers.filter { !$0.isPrivate } }

        func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
            let all = windows
            let focused = WindowRegistry.shared.lastFocused.flatMap { f in all.first { $0 === f } }
            return ((focused.map { [$0] } ?? []) + all.filter { $0 !== focused }).map(ExtensionWindow.of)
        }

        func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
            (WindowRegistry.shared.lastFocused.flatMap { $0.isPrivate ? nil : $0 } ?? windows.first).map(ExtensionWindow.of)
        }

        func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                    for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
            guard let b = (configuration.window as? ExtensionWindow)?.browser ?? (WindowRegistry.shared.lastFocused.flatMap { $0.isPrivate ? nil : $0 }) ?? windows.first else {
                completionHandler(nil, Failure.unreadable(L("No browser window is open.")))
                return
            }
            let tab = b.newTab(url: configuration.url, select: configuration.shouldBeActive)
            if configuration.shouldBePinned { b.togglePin(tab) }
            tab.ensureWebView()
            completionHandler(tab, nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                    for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void) {
            // Extensions open pages in a tab of the front window rather than in new windows.
            guard let b = WindowRegistry.shared.lastFocused.flatMap({ $0.isPrivate ? nil : $0 }) ?? windows.first else {
                completionHandler(nil, Failure.unreadable(L("No browser window is open.")))
                return
            }
            for url in configuration.tabURLs { b.newTab(url: url) }
            completionHandler(ExtensionWindow.of(b), nil)
        }

        func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping ((any Error)?) -> Void) {
            guard let url = extensionContext.optionsPageURL,
                  let b = WindowRegistry.shared.lastFocused.flatMap({ $0.isPrivate ? nil : $0 }) ?? windows.first else {
                completionHandler(Failure.unreadable(L("This extension has no settings page.")))
                return
            }
            b.newTab(url: url)
            completionHandler(nil)
        }

        // MARK: Permissions asked for later

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
            let list = permissions.map { Extensions.describe($0) }.sorted()
            ask(extensionContext, String(format: L("“%@” wants to:"), Extensions.name(extensionContext)), list) { ok in
                completionHandler(ok ? permissions : [], nil)
            }
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<URL>, Date?) -> Void) {
            let hosts = Set(urls.compactMap(\.host)).sorted()
            ask(extensionContext, String(format: L("“%@” wants to read and change these sites:"), Extensions.name(extensionContext)), hosts) { ok in
                completionHandler(ok ? urls : [], nil)
            }
        }

        func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                    in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext,
                                    completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
            let list = matchPatterns.map { Extensions.describe($0) }.sorted()
            ask(extensionContext, String(format: L("“%@” wants to read and change these sites:"), Extensions.name(extensionContext)), list) { ok in
                completionHandler(ok ? matchPatterns : [], nil)
            }
        }

        private func ask(_ context: WKWebExtensionContext, _ title: String, _ items: [String], done: @escaping (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = items.map { "• " + $0 }.joined(separator: "\n")
            alert.addButton(withTitle: L("Allow"))
            alert.addButton(withTitle: L("Don't Allow"))
            alert.icon = context.webExtension.icon(for: CGSize(width: 64, height: 64))
            if let w = NSApp.keyWindow {
                alert.beginSheetModal(for: w) { done($0 == .alertFirstButtonReturn) }
            } else {
                done(alert.runModal() == .alertFirstButtonReturn)
            }
        }

        // MARK: Buttons and popups

        func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                    forExtensionContext context: WKWebExtensionContext) {
            Extensions.shared.noteChange()
        }

        func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                    for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
            guard let popover = action.popupPopover else {
                completionHandler(Failure.unreadable(L("The extension's popup couldn't be shown.")))
                return
            }
            let id = Extensions.shared.contextID(context)
            let anchor = id.flatMap { ExtensionAnchors.view(for: $0) } ?? NSApp.keyWindow?.contentView
            guard let anchor else {
                completionHandler(Failure.unreadable(L("The extension's popup couldn't be shown.")))
                return
            }
            popover.behavior = .transient
            // Below the button: its view isn't flipped, so the bottom edge is minY.
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
            completionHandler(nil)
        }
    }

    var runtime: Runtime {
        if let r = storage as? Runtime { return r }
        let r = Runtime()
        storage = r
        return r
    }

    var controller: WKWebExtensionController { runtime.controller }

    func context(_ id: UUID) -> WKWebExtensionContext? { runtime.contexts[id] }

    func contextID(_ context: WKWebExtensionContext) -> UUID? {
        runtime.contexts.first { $0.value === context }?.key
    }

    /// The loaded extensions, in the order they were added.
    var loaded: [(item: Installed, context: WKWebExtensionContext)] {
        installed.compactMap { item in runtime.contexts[item.id].map { (item, $0) } }
    }

    /// Loads every enabled extension. Called once at launch.
    func start() {
        for item in installed where item.enabled { load(item) }
    }

    /// Reads an extension from its folder or app.
    func extensionFrom(_ source: Installed.Source) async throws -> WKWebExtension {
        switch source {
        case .folder(let path):
            return try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: path, isDirectory: true))
        case .appExtension(let path):
            guard let bundle = Bundle(path: path) else { throw Failure.unreadable(L("The app with this extension couldn't be found.")) }
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
    }

    func load(_ item: Installed) {
        guard runtime.contexts[item.id] == nil else { return }
        Task { @MainActor in
            guard let ext = try? await extensionFrom(item.source) else { return }
            let context = WKWebExtensionContext(for: ext)
            context.uniqueIdentifier = item.uniqueIdentifier
            // A fixed address, so the extension's pages and the data it stores stay the same between launches.
            if let base = URL(string: "webkit-extension://\(item.uniqueIdentifier.lowercased())/") { context.baseURL = base }
            context.hasAccessToPrivateData = false
            // With the Web Inspector on (Settings › Advanced), its pages and popup can be inspected.
            context.isInspectable = Settings.shared.developer
            await grantApproved(context, for: item)
            do {
                try controller.load(context)
                runtime.contexts[item.id] = context
                registerOpenWindows()
                // Its pages restored before it loaded were made without it; they're made again now.
                for b in WindowRegistry.shared.browsers where !b.isPrivate {
                    for t in b.tabs where t.url?.scheme == "webkit-extension" && controller.extensionContext(for: t.url!) === context {
                        t.remakeWebView()
                    }
                }
                // Its background script starts now, so its button and popup are ready when clicked.
                do { try await context.loadBackgroundContent() } catch {
                    NSLog("Tacet: background of \(item.name) failed: \(error.localizedDescription)")
                }
                revision += 1
            } catch {
                NSLog("Tacet couldn't load the extension \(item.name): \(error.localizedDescription)")
            }
        }
    }

    func unload(_ id: UUID) {
        guard let context = runtime.contexts[id] else { return }
        // Its own pages (settings, popups opened in a tab) stop working without it, so they close with it.
        for b in WindowRegistry.shared.browsers where !b.isPrivate {
            for t in b.tabs where t.url?.scheme == "webkit-extension" && t.url.flatMap({ controller.extensionContext(for: $0) }) === context {
                b.close(t)
            }
        }
        try? controller.unload(context)
        runtime.contexts[id] = nil
    }

    /// Deletes what a removed extension stored (its settings, lists and so on), found by its fixed identifier.
    func removeData(of item: Installed) {
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        controller.fetchDataRecords(ofTypes: types) { [controller] records in
            let mine = records.filter { $0.uniqueIdentifier == item.uniqueIdentifier }
            guard !mine.isEmpty else { return }
            controller.removeData(ofTypes: types, from: mine) {}
        }
    }

    /// Grants what the user allowed when the extension was added. An extension inside another app updates with that
    /// app, so anything new it asks for is only granted once the user says yes to it, and a no is remembered.
    @MainActor
    func grantApproved(_ context: WKWebExtensionContext, for item: Installed) async {
        let ext = context.webExtension
        let permissions = ext.requestedPermissions, patterns = ext.requestedPermissionMatchPatterns
        let asked = Set(permissions.map { "p:" + $0.rawValue } + patterns.map { "m:" + $0.string })
        var approved = Set(item.approved ?? Array(asked))
        var declined = Set(item.declined ?? [])
        let new = asked.subtracting(approved).subtracting(declined)
        if !new.isEmpty {
            let list = permissions.filter { new.contains("p:" + $0.rawValue) }.map(Self.describe)
                + patterns.filter { new.contains("m:" + $0.string) }.map(Self.describe)
            let alert = NSAlert()
            alert.messageText = String(format: L("“%@” was updated and now also wants to:"), item.name)
            alert.informativeText = Array(Set(list)).sorted().map { "• " + $0 }.joined(separator: "\n")
            alert.addButton(withTitle: L("Allow"))
            alert.addButton(withTitle: L("Don't Allow"))
            if alert.runModal() == .alertFirstButtonReturn { approved.formUnion(new) } else { declined.formUnion(new) }
        }
        for p in permissions where approved.contains("p:" + p.rawValue) { context.setPermissionStatus(.grantedExplicitly, for: p) }
        for m in patterns where approved.contains("m:" + m.string) { context.setPermissionStatus(.grantedExplicitly, for: m) }
        if let i = installed.firstIndex(where: { $0.id == item.id }),
           installed[i].approved.map(Set.init) != approved || (installed[i].declined.map(Set.init) ?? []) != declined {
            installed[i].approved = approved.sorted()
            installed[i].declined = declined.isEmpty ? nil : declined.sorted()
            persist()
        }
    }

    /// Adds a loaded extension after the user approved its permissions.
    func install(_ ext: WKWebExtension, source: Installed.Source) {
        let item = Installed(name: ext.displayName ?? L("Extension"), source: source)
        add(item)
        load(item)
    }

    /// Tells the runtime about windows and tabs that existed before an extension loaded.
    func registerOpenWindows() {
        for b in WindowRegistry.shared.browsers where !b.isPrivate {
            controller.didOpenWindow(ExtensionWindow.of(b))
            for t in b.tabs { controller.didOpenTab(t) }
            if let c = b.current { controller.didActivateTab(c, previousActiveTab: nil) }
        }
        if let f = WindowRegistry.shared.lastFocused, !f.isPrivate { controller.didFocusWindow(ExtensionWindow.of(f)) }
    }

    // MARK: Describing permissions

    static func name(_ context: WKWebExtensionContext) -> String {
        context.webExtension.displayName ?? L("This extension")
    }

    static func describe(_ p: WKWebExtension.Permission) -> String {
        let known: [WKWebExtension.Permission: String] = [
            .activeTab: L("Use the page you're on when you click it"),
            .alarms: L("Run tasks on a schedule"),
            .clipboardWrite: L("Copy to your clipboard"),
            .contextMenus: L("Add items to the right-click menu"),
            .cookies: L("Read and change cookies"),
            .declarativeNetRequest: L("Block or change requests to websites"),
            .declarativeNetRequestFeedback: L("See which requests it blocked"),
            .declarativeNetRequestWithHostAccess: L("Block or change requests on the sites it can access"),
            .menus: L("Add items to the right-click menu"),
            .nativeMessaging: L("Talk to its app on your Mac"),
            .scripting: L("Run scripts on pages"),
            .storage: L("Store data"),
            .tabs: L("See the addresses and titles of your tabs"),
            .unlimitedStorage: L("Store unlimited data"),
            .webNavigation: L("See when pages load"),
            .webRequest: L("See requests to websites"),
        ]
        return known[p] ?? p.rawValue
    }

    static func describe(_ m: WKWebExtension.MatchPattern) -> String {
        if m.matchesAllHosts { return L("All websites") }
        return m.host.map { $0.replacingOccurrences(of: "*.", with: "") } ?? m.description
    }

    /// One plain list of what an extension asks for, for the install sheet.
    static func summary(_ ext: WKWebExtension) -> [String] {
        var out = ext.requestedPermissions.map(describe).sorted()
        let patterns = ext.allRequestedMatchPatterns
        if patterns.contains(where: \.matchesAllHosts) {
            out.insert(L("Read and change all websites you visit"), at: 0)
        } else if !patterns.isEmpty {
            let hosts = Set(patterns.map(describe)).sorted().prefix(8).joined(separator: ", ")
            out.insert(String(format: L("Read and change: %@"), hosts), at: 0)
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }
}

// MARK: - Windows and tabs as extensions see them

/// A browser window as extensions see it, one per window.
@available(macOS 15.4, *)
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var browser: BrowserState?
    private static let table = NSMapTable<BrowserState, ExtensionWindow>.weakToStrongObjects()

    private init(_ b: BrowserState) { browser = b }

    static func of(_ b: BrowserState) -> ExtensionWindow {
        if let w = table.object(forKey: b) { return w }
        let w = ExtensionWindow(b)
        table.setObject(w, forKey: b)
        return w
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { browser?.tabs ?? [] }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { browser?.current }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let w = browser?.window else { return .normal }
        if w.isMiniaturized { return .minimized }
        if w.styleMask.contains(.fullScreen) { return .fullscreen }
        return .normal
    }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { browser?.isPrivate ?? false }
    func frame(for context: WKWebExtensionContext) -> CGRect { browser?.window?.frame ?? .null }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { browser?.window?.screen?.frame ?? NSScreen.main?.frame ?? .null }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.window?.performClose(nil)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
extension Tab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser.map(ExtensionWindow.of) }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { browser?.tabs.firstIndex { $0 === self } ?? 0 }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func isPinned(for context: WKWebExtensionContext) -> Bool { isPinned }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { browser?.selectedID == id }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { isPlayingAudio }
    func isMuted(for context: WKWebExtensionContext) -> Bool { isMuted }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { isReader }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { zoom }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.select(self)
        completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        browser?.close(self)
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        load(url)
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        fromOrigin ? hardReload() : reload()
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goBack()
        completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        goForward()
        completionHandler(nil)
    }
    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        setMuted(muted)
        completionHandler(nil)
    }
    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if pinned != isPinned { browser?.togglePin(self) }
        completionHandler(nil)
    }
}

// MARK: - Telling extensions what happens

/// Called from tabs and windows; does nothing before macOS 15.4 or with no extensions loaded.
enum ExtensionEvents {
    private static var active: Bool {
        guard Extensions.isSupported, !Extensions.shared.installed.isEmpty else { return false }
        return true
    }

    static func opened(_ tab: Tab) {
        guard active, tab.browser?.isPrivate == false, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didOpenTab(tab)
    }

    static func closed(_ tab: Tab, windowClosing: Bool = false) {
        guard active, tab.browser?.isPrivate != true, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didCloseTab(tab, windowIsClosing: windowClosing)
    }

    static func activated(_ tab: Tab, previous: Tab?) {
        guard active, tab.browser?.isPrivate == false, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didActivateTab(tab, previousActiveTab: previous)
    }

    static func changed(_ tab: Tab, url: Bool = false, title: Bool = false, loading: Bool = false) {
        guard active, tab.browser?.isPrivate == false, #available(macOS 15.4, *) else { return }
        var p: WKWebExtension.TabChangedProperties = []
        if url { p.insert(.URL) }
        if title { p.insert(.title) }
        if loading { p.insert(.loading) }
        Extensions.shared.controller.didChangeTabProperties(p, for: tab)
    }

    /// Tabs added to or removed from a window's list.
    static func tabsChanged(from old: [Tab], to new: [Tab]) {
        guard active, #available(macOS 15.4, *) else { return }
        let before = Set(old.map(ObjectIdentifier.init)), after = Set(new.map(ObjectIdentifier.init))
        for t in new where !before.contains(ObjectIdentifier(t)) { opened(t) }
        for t in old where !after.contains(ObjectIdentifier(t)) { closed(t) }
    }

    static func openedWindow(_ b: BrowserState) {
        guard active, !b.isPrivate, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didOpenWindow(ExtensionWindow.of(b))
    }

    static func closedWindow(_ b: BrowserState) {
        guard active, !b.isPrivate, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didCloseWindow(ExtensionWindow.of(b))
    }

    static func focused(_ b: BrowserState) {
        guard active, !b.isPrivate, #available(macOS 15.4, *) else { return }
        Extensions.shared.controller.didFocusWindow(ExtensionWindow.of(b))
    }
}

/// The toolbar buttons of extensions, by extension, so popups can point at them. Every window has its own button,
/// so the one in the front window is used.
enum ExtensionAnchors {
    private static var table: [UUID: NSHashTable<NSView>] = [:]

    static func set(_ view: NSView, for id: UUID) {
        let views = table[id] ?? .weakObjects()
        views.add(view)
        table[id] = views
    }

    static func view(for id: UUID) -> NSView? {
        let views = (table[id]?.allObjects ?? []).filter { $0.window?.isVisible == true }
        let front = NSApp.keyWindow ?? NSApp.mainWindow
        return views.first { $0.window === front } ?? views.first
    }
}
