import AppKit
import CryptoKit
import Foundation
import Observation
import WebKit

/// Tacet Plugins: small plugins made for Tacet, listed in the repository's plugins folder. The list is signed with
/// Tacet's update key and carries the SHA-256 of every file, so only plugins made by Tacet's developer can install.
/// A plugin is a script and/or a style that runs on the sites it names, in a world of its own the page can't reach.
@Observable
final class PluginStore {
    static let shared = PluginStore()
    static let base = URL(string: "https://raw.githubusercontent.com/scadavide55/Tacet/main/plugins/")!

    struct Plugin: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let description: String
        let version: String
        var icon: String?
        let sites: [String]
        var js: String?
        var css: String?
        var runAt: String?
        var world: String?
        /// File name → SHA-256, as listed in the signed index.
        var files: [String: String] = [:]
        /// Who made it: "Tacet Plugins" for Tacet's own.
        var author: String?
        /// "plugin" (Tacet's own format, every Mac) or "extension" (a Chrome, Firefox or Safari web extension).
        var kind: String?
        /// For extensions: the browser it was made for, the .crx, .xpi or .zip to download, and that file's SHA-256.
        var madeFor: String?
        var download: String?
        var sha256: String?
        /// Whether Tacet's developer read and checked it; unverified ones are only known to work.
        var verified: Bool?
        /// The person behind it and their site, shown on its card.
        var developer: String?
        var website: String?
        /// A page of the plugin's app that other plugins' pictures can be sent to (see PluginBridge).
        var handoff: String?
        /// A whole web app that runs inside Tacet at tacet-plugin://<id>/, with its large files downloaded once.
        var app: App?
        /// What clicking it in the extensions menu does: "app" opens its app, "action" runs `action` on the page,
        /// "toggle" turns it on or off, "info" shows how to use it.
        var mode: String?
        /// The action's name, for "action" plugins; the plugin's script defines globalThis.tacetAction to run it.
        var action: String?
        /// Its keyboard shortcut, if it has one, as people press it.
        var shortcut: String?

        struct App: Codable, Equatable {
            let start: String
            var files: [String] = []
            var assets: [Asset] = []
            var downloadSize: Int { assets.reduce(0) { $0 + $1.size } }
        }

        struct Asset: Codable, Equatable {
            let path: String
            let url: String
            let sha256: String
            let size: Int
        }

        var startURL: URL? { app.flatMap { URL(string: "\(PluginAppScheme.scheme)://\(id)/\($0.start)") } }

        /// What a click on it does, worked out for plugins whose manifest predates `mode`.
        var behaviour: String {
            if app != nil { return "app" }
            if let mode { return mode }
            return js == nil ? "toggle" : "info"
        }

        /// A plugin made of a style only can be turned on and off on open pages without reloading them.
        var isStyleOnly: Bool { js == nil && css != nil }

        var isExtension: Bool { kind == "extension" }
        var isVerified: Bool { verified ?? !isExtension }
        var byLine: String {
            let who = author ?? "Tacet Plugins"
            if let madeFor { return String(format: L("Made by %@, for %@"), who, madeFor) }
            return String(format: L("By %@"), who)
        }
    }

    struct Installed: Codable, Equatable {
        var plugin: Plugin
        var enabled = true
        /// Shown as a button in the toolbar. Optional, so lists saved before it existed still load.
        var pinned: Bool?
        /// Sites where the plugin is turned off while it stays on elsewhere.
        var offSites: [String]?

        func isOff(on host: String?) -> Bool {
            guard let host = host?.lowercased(), let offSites else { return false }
            return offSites.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    private struct Index: Codable {
        let format: Int
        let plugins: [Plugin]
    }

    enum Failure: LocalizedError {
        case unverified, download, needsNewerMac
        var errorDescription: String? {
            switch self {
            case .unverified: L("The plugin list couldn't be verified, so nothing was installed.")
            case .download: L("Tacet Plugins couldn't be reached. Check your connection and try again.")
            case .needsNewerMac: L("Extensions need macOS 15.4 or later.")
            }
        }
    }

    private(set) var catalog: [Plugin] = []
    private(set) var installed: [String: Installed] = [:]
    private(set) var loading = false
    private(set) var error: String?
    private(set) var working: Set<String> = []
    /// How far a plugin's download has got, from 0 to 1, while it installs.
    private(set) var progress: [String: Double] = [:]
    @ObservationIgnored private let file = StoredFile<[String: Installed]>("Plugins/installed.json")
    @ObservationIgnored private let folder = Paths.folder("Plugins")
    @ObservationIgnored private var lastRefresh: Date?
    /// Each plugin's files as text, read once.
    @ObservationIgnored private var sources: [String: (js: String?, css: String?)] = [:]

    private init() { installed = file.load() ?? [:] }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    // MARK: Catalog

    /// Fetches and verifies the list; also updates installed plugins that have a newer version.
    @MainActor
    func refresh(force: Bool = false) async {
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < 3600, !catalog.isEmpty { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let index = try await Self.fetchIndex()
            catalog = index.plugins
            error = nil
            lastRefresh = Date()
            for p in index.plugins {
                guard let item = installed[p.id] else { continue }
                if UpdateChecker.isNewer(p.version, than: item.plugin.version) {
                    try? await install(p)
                } else if p.files == item.plugin.files, p != item.plugin {
                    // Same files, newer details (its name, what a click does): those are taken as they are.
                    installed[p.id]?.plugin = p
                    file.saveNow(installed)
                }
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func fetchIndex() async throws -> Index {
        guard let (data, r1) = try? await session.data(from: base.appendingPathComponent("index.json")),
              let (sig, r2) = try? await session.data(from: base.appendingPathComponent("index.json.sig")),
              (r1 as? HTTPURLResponse)?.statusCode == 200, (r2 as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        guard verify(data, signature: sig) else { throw Failure.unverified }
        return try JSONDecoder().decode(Index.self, from: data)
    }

    static func verify(_ data: Data, signature: Data) -> Bool {
        guard let sig = Data(base64Encoded: String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: UpdateInstaller.signingKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    // MARK: Installing

    @MainActor
    func install(_ p: Plugin) async throws {
        working.insert(p.id)
        defer { working.remove(p.id) }
        if p.isExtension { try await installExtension(p); return }
        // Every file must match the hash in the signed list before anything is written.
        var downloaded: [String: Data] = [:]
        for (name, hash) in p.files {
            // Plain names, or pages of the plugin's app under app/; never a way out of its folder.
            let parts = name.split(separator: "/")
            guard !name.hasPrefix("."), !parts.contains(".."), parts.count == 1 || (parts.count == 2 && parts[0] == "app"),
                  let (data, response) = try? await Self.session.data(from: Self.base.appendingPathComponent(p.id).appendingPathComponent(name)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == hash.lowercased() else { throw Failure.unverified }
            downloaded[name] = data
        }
        let target = folder.appendingPathComponent(p.id, isDirectory: true)
        // A big app's downloaded files stay through an update if they haven't changed.
        if p.app == nil { try? FileManager.default.removeItem(at: target) }
        try FileManager.default.createDirectory(at: target.appendingPathComponent("app"), withIntermediateDirectories: true)
        for (name, data) in downloaded { try data.write(to: target.appendingPathComponent(name), options: .atomic) }
        if let app = p.app { try await downloadAssets(app, into: target.appendingPathComponent("app"), id: p.id) }
        // An update keeps how it was set up: on or off, pinned, and the sites it's off on.
        var item = installed[p.id] ?? Installed(plugin: p)
        item.plugin = p
        installed[p.id] = item
        sources[p.id] = nil
        changed()
    }

    /// The app's large files (AI models, say), each checked against the hash in the signed list. Files already there
    /// with the right hash are kept, so updates only fetch what changed.
    @MainActor
    private func downloadAssets(_ app: Plugin.App, into dir: URL, id: String) async throws {
        let total = Double(max(1, app.downloadSize))
        var done = 0.0
        progress[id] = 0
        defer { progress[id] = nil }
        for asset in app.assets {
            let parts = asset.path.split(separator: "/")
            guard !asset.path.hasPrefix("/"), !parts.contains(".."), let url = URL(string: asset.url), url.scheme == "https" else { throw Failure.unverified }
            let dest = dir.appendingPathComponent(asset.path)
            if await Task.detached(operation: { Self.sha256(of: dest) }).value == asset.sha256.lowercased() {
                done += Double(asset.size)
                progress[id] = done / total
                continue
            }
            let base = done
            let file = try await AssetDownload.fetch(url) { [weak self] written in
                Task { @MainActor in self?.progress[id] = (base + Double(written)) / total }
            }
            defer { try? FileManager.default.removeItem(at: file) }
            guard await Task.detached(operation: { Self.sha256(of: file) }).value == asset.sha256.lowercased() else { throw Failure.unverified }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: file, to: dest)
            done += Double(asset.size)
            progress[id] = done / total
        }
    }

    /// The SHA-256 of a file, read in pieces so big models don't fill memory; nil if it isn't there.
    nonisolated static func sha256(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs an "action" plugin's action on the page in `tab`, in the plugin's own world. Whatever it returns to copy
    /// goes on the clipboard from here, since a page can only write the clipboard right after a click on it.
    @MainActor
    func runAction(_ p: Plugin, in tab: Tab?) async {
        guard let wv = tab?.webView, tab?.url != nil else { NSSound.beep(); return }
        let world = WKContentWorld.world(name: "TacetPlugin-" + p.id)
        let result = try? await wv.callAsyncJavaScript("return globalThis.tacetAction ? await globalThis.tacetAction() : 'missing';",
                                                        arguments: [:], in: nil, contentWorld: world)
        if (result as? String) == "missing" { NSSound.beep() }
        if let dict = result as? [String: Any], let text = dict["copy"] as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// The folder an installed app's files are in.
    func appFolder(_ id: String) -> URL { folder.appendingPathComponent(id).appendingPathComponent("app") }

    /// A web extension from another browser's store: the exact file named in the signed list, then the usual
    /// sheet that shows what it can do before it's added.
    @MainActor
    private func installExtension(_ p: Plugin) async throws {
        guard Extensions.isSupported else { throw Failure.needsNewerMac }
        guard let raw = p.download, let url = URL(string: raw), url.scheme == "https", let hash = p.sha256,
              let (data, response) = try? await Self.session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else { throw Failure.unverified }
        let ext = url.pathExtension.isEmpty ? "zip" : url.pathExtension
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(p.id + "." + ext)
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let folder = try Extensions.shared.importPackage(at: file)
        pendingExtension = (p, folder)
    }

    /// An extension downloaded from the store, waiting for the user to look at its permissions and add it.
    var pendingExtension: (plugin: Plugin, folder: URL)?

    func remove(_ id: String) {
        installed[id] = nil
        sources[id] = nil
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        changed()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard let item = installed[id] else { return }
        installed[id]?.enabled = on
        changed(live: item.plugin.isStyleOnly ? id : nil)
    }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard installed[id] != nil else { return }
        installed[id]?.pinned = pinned
        file.saveNow(installed)
    }

    /// Turns a plugin off, or back on, for one site only.
    func setOff(_ id: String, on host: String, _ off: Bool) {
        guard let item = installed[id] else { return }
        let site = PublicSuffix.registrable(host.lowercased())
        var sites = item.offSites ?? []
        sites.removeAll { $0 == site }
        if off { sites.append(site) }
        installed[id]?.offSites = sites.isEmpty ? nil : sites
        changed(live: item.plugin.isStyleOnly ? id : nil)
    }

    /// Saves the list and updates open pages: a style-only plugin changes on the page at once; any other plugin
    /// needs the page it changes to load again, so the tab you're looking at reloads.
    private func changed(live id: String? = nil) {
        file.saveNow(installed)
        NotificationCenter.default.post(name: .settingChanged, object: self, userInfo: ["key": id == nil ? "plugins" : "pluginsQuiet"])
        if let id { applyLive(id) }
    }

    /// Adds or removes a style-only plugin's style on every open page, following its sites and where it's off.
    private func applyLive(_ id: String) {
        guard let item = installed[id] else { return }
        let world = WKContentWorld.world(name: "TacetPlugin-" + id)
        let source = item.enabled ? styleSource(id, item) : nil
        for b in WindowRegistry.shared.browsers {
            for t in b.tabs {
                guard let wv = t.webView else { continue }
                let remove = "document.querySelectorAll('style[data-tacet-plugin=\"\(id)\"]').forEach(s => s.remove());"
                let js = remove + (source.map { "\n" + $0 } ?? "")
                wv.evaluateJavaScript(js, in: nil, in: world)
            }
        }
    }

    private func styleSource(_ id: String, _ item: Installed) -> String? {
        let dir = folder.appendingPathComponent(id)
        guard let name = item.plugin.css, let css = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8),
              let data = try? JSONSerialization.data(withJSONObject: [css]) else { return nil }
        return "(() => {\n" + guardJS(item) + """
        const s = document.createElement('style'); s.dataset.tacetPlugin = '\(id)'; s.textContent = \(String(decoding: data, as: UTF8.self))[0];
        (document.head || document.documentElement).appendChild(s);
        })();
        """
    }

    /// The start of every plugin script: it stops unless the page is on one of the plugin's sites and the plugin
    /// isn't turned off there.
    private func guardJS(_ item: Installed) -> String {
        let json = { (list: [String]) in
            (try? JSONSerialization.data(withJSONObject: list.map { $0.lowercased() })).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        }
        return "const __sites = \(json(item.plugin.sites)), __off = \(json(item.offSites ?? [])); const __h = location.hostname.toLowerCase();\n"
            + "const __on = (d) => __h === d || __h.endsWith('.' + d);\n"
            + "if ((!__sites.includes('*') && !__sites.some(__on)) || __off.some(__on)) return;\n"
    }

    // MARK: Running

    /// Adds every enabled plugin to a web view's scripts. Each runs only on its sites, in its own world.
    func addScripts(to controller: WKUserContentController) {
        for (id, item) in installed where item.enabled {
            let p = item.plugin
            if sources[id] == nil {
                let dir = folder.appendingPathComponent(id)
                sources[id] = (p.js.flatMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) },
                               p.css.flatMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) })
            }
            // An app with nothing to add to pages (Focus Timer, say) has no script.
            guard let src = sources[id], src.js != nil || src.css != nil else { continue }
            var body = ""
            if let css = src.css, let data = try? JSONSerialization.data(withJSONObject: [css]) {
                body += """
                const __css = \(String(decoding: data, as: UTF8.self))[0];
                const __add = () => { const s = document.createElement('style'); s.dataset.tacetPlugin = '\(id)'; s.textContent = __css;
                  (document.head || document.documentElement).appendChild(s); };
                if (document.documentElement) __add(); else document.addEventListener('DOMContentLoaded', __add);

                """
            }
            // One plugin's mistake stays its own: it's reported in the Web Inspector and the others still run.
            if let js = src.js { body += "try {\n" + js + "\n} catch (e) { console.error('Tacet plugin \(id):', e); }" }
            let source = "(() => {\n" + guardJS(item) + body + "\n})();"
            let world: WKContentWorld = p.world == "page" ? .page : .world(name: "TacetPlugin-" + id)
            // A plugin that hands pictures to its app can talk to Tacet, from its own world only.
            if p.handoff != nil, p.world != "page" {
                controller.removeScriptMessageHandler(forName: PluginBridge.name, contentWorld: world)
                controller.add(PluginBridge.shared, contentWorld: world, name: PluginBridge.name)
            }
            controller.addUserScript(WKUserScript(source: source, injectionTime: p.runAt == "end" ? .atDocumentEnd : .atDocumentStart,
                                                  forMainFrameOnly: true, in: world))
        }
    }

    /// The name and description in the user's language when Tacet knows them.
    static func localized(_ s: String) -> String { L(s) }
}

// MARK: - Downloads with progress

/// One large download to a temporary file, reporting the bytes written so far.
private final class AssetDownload: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(_ onProgress: @escaping (Int64) -> Void) { self.onProgress = onProgress }

    static func fetch(_ url: URL, progress: @escaping (Int64) -> Void) async throws -> URL {
        let d = AssetDownload(progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            d.continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file goes away when this returns, so it's moved first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("tacet-plugin-" + UUID().uuidString)
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200, (try? FileManager.default.moveItem(at: location, to: keep)) != nil else {
            continuation?.resume(throwing: PluginStore.Failure.download)
            continuation = nil
            return
        }
        continuation?.resume(returning: keep)
        continuation = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
    }
}

// MARK: - Plugins that are whole apps

/// Serves an installed plugin's app from this Mac at tacet-plugin://<id>/, so it runs without the network.
/// Only enabled plugins' own files are served, and nothing outside their folder.
final class PluginAppScheme: NSObject, WKURLSchemeHandler {
    static let shared = PluginAppScheme()
    static let scheme = "tacet-plugin"

    private static let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "wasm": "application/wasm",
                                "json": "application/json", "css": "text/css", "png": "image/png", "md": "text/markdown",
                                "onnx": "application/octet-stream", "svg": "image/svg+xml"]

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let id = url.host, let item = PluginStore.shared.installed[id], item.enabled,
              item.plugin.app != nil else { return fail(task, 404) }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = item.plugin.app?.start ?? "index.html" }
        // The app's health check, which online would reach its model host: here everything is already on the Mac.
        if path == "ping.json" { return reply(task, Data("{}".utf8), type: "application/json") }
        let root = PluginStore.shared.appFolder(id).standardizedFileURL
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return fail(task, 404) }
        reply(task, data, type: Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream")
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func reply(_ task: WKURLSchemeTask, _ data: Data, type: String) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": type, "Content-Length": String(data.count),
                                                            "Access-Control-Allow-Origin": "*", "Cache-Control": "no-cache"]) else { return }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ code: Int) {
        guard let url = task.request.url, let r = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        task.didReceive(r)
        task.didReceive(Data())
        task.didFinish()
    }
}
