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
            guard !name.contains("/"), !name.hasPrefix("."),
                  let (data, response) = try? await Self.session.data(from: Self.base.appendingPathComponent(p.id).appendingPathComponent(name)),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == hash.lowercased() else { throw Failure.unverified }
            downloaded[name] = data
        }
        let target = folder.appendingPathComponent(p.id, isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for (name, data) in downloaded { try data.write(to: target.appendingPathComponent(name), options: .atomic) }
        let enabled = installed[p.id]?.enabled ?? true
        installed[p.id] = Installed(plugin: p, enabled: enabled)
        sources[p.id] = nil
        changed()
    }

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
            controller.addUserScript(WKUserScript(source: source, injectionTime: p.runAt == "end" ? .atDocumentEnd : .atDocumentStart,
                                                  forMainFrameOnly: true, in: world))
        }
    }

    /// The name and description in the user's language when Tacet knows them.
    static func localized(_ s: String) -> String { L(s) }
}
