import AppKit
import CryptoKit

/// Checks GitHub releases for a newer Lumen and can install it in place.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let releasesAPI = URL(string: "https://api.github.com/repos/scadavide55/Lumen/releases?per_page=10")!

    struct Release: Equatable {
        let version: String
        let name: String
        let notes: String
        let page: URL
        let asset: URL?
        /// "<asset>.sig" published next to the asset, holding its Ed25519 signature.
        let signature: URL?
    }

    @Published private(set) var available: Release?
    @Published private(set) var checking = false
    @Published private(set) var lastResult: String?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The update to announce at launch: available and not skipped.
    var announceable: Release? {
        guard let r = available, r.version != UserDefaults.standard.string(forKey: "lumen.skippedVersion") else { return nil }
        return r
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: "lumen.skippedVersion")
    }

    /// Checks at most once a day unless forced.
    func check(force: Bool = false, done: (() -> Void)? = nil) {
        let defaults = UserDefaults.standard
        if !force {
            guard Settings.shared.checkUpdates else { return }
            if let last = defaults.object(forKey: "lumen.updateCheck") as? Date, Date().timeIntervalSince(last) < 86_400 { return }
        }
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: Self.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            let releases = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let newest = releases
                .filter { ($0["draft"] as? Bool) != true }
                .compactMap(Self.release)
                .max { Self.isNewer($1.version, than: $0.version) }
            DispatchQueue.main.async {
                self.checking = false
                defer { done?() }
                guard ok else {
                    self.lastResult = L("Couldn't check for updates.")
                    return
                }
                defaults.set(Date(), forKey: "lumen.updateCheck")
                if let newest, Self.isNewer(newest.version, than: Self.currentVersion) {
                    self.available = newest
                    self.lastResult = String(format: L("%@ is available."), newest.name)
                } else {
                    self.available = nil
                    self.lastResult = L("Lumen is up to date.")
                }
            }
        }.resume()
    }

    private static func release(_ r: [String: Any]) -> Release? {
        guard let tag = r["tag_name"] as? String, let page = (r["html_url"] as? String).flatMap(URL.init) else { return nil }
        let assets = (r["assets"] as? [[String: Any]] ?? []).compactMap { a -> (String, URL)? in
            guard let name = a["name"] as? String, let url = (a["browser_download_url"] as? String).flatMap(URL.init) else { return nil }
            return (name.lowercased(), url)
        }
        let picked = assets.first { $0.0.hasSuffix(".dmg") } ?? assets.first { $0.0.hasSuffix(".zip") }
        let signature = picked.flatMap { p in assets.first { $0.0 == p.0 + ".sig" }?.1 }
        return Release(version: version(fromTag: tag), name: r["name"] as? String ?? tag,
                       notes: r["body"] as? String ?? "", page: page, asset: picked?.1, signature: signature)
    }

    /// "v1.5-beta" → "1.5"
    static func version(fromTag tag: String) -> String {
        var t = tag.lowercased()
        if t.hasPrefix("v") { t.removeFirst() }
        return String(t.prefix { $0.isNumber || $0 == "." })
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

// MARK: - Installing

/// Downloads a release, checks it is Lumen, swaps it in for the running copy and relaunches.
final class UpdateInstaller: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let shared = UpdateInstaller()
    @Published private(set) var state = State.idle
    private var release: UpdateChecker.Release?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)

    /// Public half of the key that signs Lumen updates (see tools/sign-update.swift).
    /// Updates not signed with the matching private key are refused.
    private static let signingKey = "F+nRdeNu8pDKHPW5IepLoLSrTmiMkV6CatzvXsCLgHA="

    private static let trustedHosts = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    func install(_ r: UpdateChecker.Release) {
        guard let asset = r.asset else {
            NSWorkspace.shared.open(r.page)
            return
        }
        guard asset.scheme == "https", Self.trustedHosts.contains(asset.host ?? "") else {
            state = .failed(L("The update doesn't come from GitHub."))
            return
        }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            state = .failed(L("Lumen can't replace itself here. Move Lumen to the Applications folder, or install the update from GitHub."))
            return
        }
        release = r
        state = .downloading(0)
        session.downloadTask(with: asset).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { state = .downloading(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { state = .failed(error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let ext = downloadTask.originalRequest?.url?.pathExtension.lowercased() ?? "zip"
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-update-" + UUID().uuidString)
        let archive = work.appendingPathComponent("update." + ext)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: archive)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .installing
        let signature = release?.signature
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.verify(archive: archive, signature: signature).flatMap { Self.prepare(archive: archive, ext: ext, work: work) }
            DispatchQueue.main.async {
                switch result {
                case .success(let app): self.relaunch(into: app)
                case .failure(let message): self.state = .failed(message.text)
                }
            }
        }
    }

    struct Message: Error { let text: String }

    /// The download must carry a signature made with Lumen's update key. A checksum next to the file
    /// would not do: whoever can change the release can change that too.
    private static func verify(archive: URL, signature: URL?) -> Result<Void, Message> {
        let damaged = Message(text: L("The update couldn't be verified. It may be damaged or changed; try again later."))
        guard let signature, signature.scheme == "https", trustedHosts.contains(signature.host ?? ""),
              let text = try? String(contentsOf: signature, encoding: .utf8),
              let sig = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: signingKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: archive, options: .mappedIfSafe) else { return .failure(damaged) }
        return key.isValidSignature(sig, for: data) ? .success(()) : .failure(damaged)
    }

    /// Extracts the new Lumen.app and checks its identity and version.
    private static func prepare(archive: URL, ext: String, work: URL) -> Result<URL, Message> {
        let extracted = work.appendingPathComponent("extracted")
        try? FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        if ext == "dmg" {
            let mount = work.appendingPathComponent("mount")
            guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, archive.path]) else {
                return .failure(Message(text: L("Couldn't open the downloaded disk image.")))
            }
            defer { _ = run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }
            guard let app = findApp(in: mount), run("/usr/bin/ditto", [app.path, extracted.appendingPathComponent("Lumen.app").path]) else {
                return .failure(Message(text: L("The download doesn't contain Lumen.")))
            }
        } else {
            guard run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]) else {
                return .failure(Message(text: L("Couldn't unzip the update.")))
            }
        }
        guard let app = findApp(in: extracted), let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return .failure(Message(text: L("The download doesn't contain Lumen.")))
        }
        // The app must be intact: every file has to match its code signature.
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) else {
            return .failure(Message(text: L("The update couldn't be verified. It may be damaged or changed; try again later.")))
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard UpdateChecker.isNewer(version, than: UpdateChecker.currentVersion) else {
            return .failure(Message(text: L("The downloaded version isn't newer than this one.")))
        }
        return .success(app)
    }

    private static func findApp(in folder: URL) -> URL? {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension == "app" }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A small script waits for Lumen to quit, swaps the app and opens the new one.
    private func relaunch(into newApp: URL) {
        Session.shared.saveNow()
        let current = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        backup="\(current).old-$$"
        if mv "\(current)" "$backup" && /usr/bin/ditto "\(newApp.path)" "\(current)"; then
            rm -rf "$backup"
            /usr/bin/xattr -dr com.apple.quarantine "\(current)"
        else
            rm -rf "\(current)"; mv "$backup" "\(current)"
        fi
        /usr/bin/open "\(current)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        do {
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
