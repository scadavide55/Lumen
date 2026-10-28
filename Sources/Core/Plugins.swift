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
            for p in index.plugins where installed[p.id].map({ UpdateChecker.isNewer(p.version, than: $0.plugin.version) }) == true {
                try? await install(p)
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
        let enabled = installed[p.id]?.enabled ?? true
        installed[p.id] = Installed(plugin: p, enabled: enabled)
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
        guard installed[id] != nil else { return }
        installed[id]?.enabled = on
        changed()
    }

    private func changed() {
        file.saveNow(installed)
        // Open pages pick the change up the way they pick up settings.
        NotificationCenter.default.post(name: .settingChanged, object: self, userInfo: ["key": "plugins"])
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
            guard let src = sources[id] else { continue }
            let sites = (try? JSONSerialization.data(withJSONObject: p.sites.map { $0.lowercased() })).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let guardJS = "const __sites = \(sites); const __h = location.hostname.toLowerCase();\n"
                + "if (!__sites.includes('*') && !__sites.some(d => __h === d || __h.endsWith('.' + d))) return;\n"
            var body = ""
            if let css = src.css, let data = try? JSONSerialization.data(withJSONObject: [css]) {
                body += """
                const __css = \(String(decoding: data, as: UTF8.self))[0];
                const __add = () => { const s = document.createElement('style'); s.dataset.tacetPlugin = '\(id)'; s.textContent = __css;
                  (document.head || document.documentElement).appendChild(s); };
                if (document.documentElement) __add(); else document.addEventListener('DOMContentLoaded', __add);

                """
            }
            if let js = src.js { body += js }
            let source = "(() => {\n" + guardJS + body + "\n})();"
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
