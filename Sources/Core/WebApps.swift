import AppKit
import WebKit

/// Sites installed as their own apps. Each one is a copy of Tacet with the site's name and icon
/// in ~/Applications/Lumen Apps; when Tacet starts from such a copy it shows only that site.
enum WebApp {
    /// The site this copy of Tacet is dedicated to, or nil for the normal browser.
    static let url: URL? = (Bundle.main.object(forInfoDictionaryKey: "LumenWebAppURL") as? String).flatMap(URL.init)
    static var isActive: Bool { url != nil }
    static var site: String? { url?.host.map(PasswordStore.site) }

    /// Still "Lumen Apps", Tacet's former name, so apps installed before the rename keep working.
    static let folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Lumen Apps", isDirectory: true)
    static let browserBundleID = "com.lumen.browser"

    /// Opens a link in the main Tacet browser.
    static func openInBrowser(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    struct Installed: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let name: String
        let site: String
        var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
    }

    static func installed() -> [Installed] {
        let apps = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return apps.filter { $0.pathExtension == "app" }.compactMap { app in
            guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
                  let site = info["LumenWebAppURL"] as? String else { return nil }
            return Installed(url: app, name: info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent, site: site)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func remove(_ app: Installed, done: @escaping () -> Void) {
        NSWorkspace.shared.recycle([app.url]) { _, _ in DispatchQueue.main.async(execute: done) }
    }

    // MARK: Site details

    struct Candidate {
        var name: String
        var startURL: URL
        var icon: NSImage?
    }

    /// Reads the page's web app manifest (name, start URL, icons), falling back to the title and icons.
    static func candidate(for tab: Tab, done: @escaping (Candidate) -> Void) {
        guard let wv = tab.webView, let pageURL = tab.url else { return }
        let js = """
        (() => {
          const m = document.querySelector('link[rel="manifest"]');
          const t = document.querySelector('link[rel~="apple-touch-icon"]');
          const app = document.querySelector('meta[name="application-name"], meta[name="apple-mobile-web-app-title"]');
          return { manifest: m ? m.href : null, touch: t ? t.href : null, app: app ? app.content : null };
        })();
        """
        wv.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
            let info = (try? result.get()) as? [String: Any] ?? [:]
            var candidate = Candidate(name: (info["app"] as? String) ?? cleanTitle(tab.title, host: pageURL.host),
                                      startURL: pageURL, icon: tab.favicon)
            let session = URLSession(configuration: .ephemeral)
            let group = DispatchGroup()
            var iconURLs: [URL] = []
            if let m = (info["manifest"] as? String).flatMap(URL.init) {
                group.enter()
                session.dataTask(with: m) { data, _, _ in
                    defer { group.leave() }
                    guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    if let n = (json["short_name"] as? String) ?? (json["name"] as? String), !n.isEmpty { candidate.name = n }
                    if let s = json["start_url"] as? String, let u = URL(string: s, relativeTo: m)?.absoluteURL, u.host == pageURL.host {
                        candidate.startURL = u
                    }
                    let icons = (json["icons"] as? [[String: Any]] ?? []).compactMap { i -> (Int, URL)? in
                        guard let src = i["src"] as? String, let u = URL(string: src, relativeTo: m)?.absoluteURL,
                              !(src.lowercased().hasSuffix(".svg")) else { return nil }
                        let size = (i["sizes"] as? String ?? "").split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
                        return (size, u)
                    }
                    iconURLs = icons.sorted { $0.0 > $1.0 }.map(\.1)
                }.resume()
            }
            group.notify(queue: .global()) {
                let touch = (info["touch"] as? String).flatMap(URL.init)
                for u in iconURLs + [touch].compactMap({ $0 }) {
                    if let data = try? Data(contentsOf: u), let img = NSImage(data: data), img.isValid, img.size.width >= 64 {
                        candidate.icon = img
                        break
                    }
                }
                DispatchQueue.main.async { done(candidate) }
            }
        }
    }

    private static func cleanTitle(_ title: String, host: String?) -> String {
        let first = title.components(separatedBy: CharacterSet(charactersIn: "|–—·:-")).first?.trimmingCharacters(in: .whitespaces) ?? title
        if !first.isEmpty && first.count <= 30 { return first }
        return host.map { BrowserState.siteName(PasswordStore.site($0)) } ?? "Web App"
    }

    // MARK: Installing

    enum InstallError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { return m }; return nil }
    }

    /// Builds the app on a background queue and opens it.
    static func install(_ c: Candidate, done: @escaping (Result<URL, InstallError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = build(c)
            DispatchQueue.main.async {
                if case .success(let app) = result { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
                done(result)
            }
        }
    }

    private static func build(_ c: Candidate) -> Result<URL, InstallError> {
        let fm = FileManager.default
        let safeName = c.name.components(separatedBy: CharacterSet(charactersIn: "/:\\\\")).joined().trimmingCharacters(in: .whitespaces)
        guard !safeName.isEmpty else { return .failure(.failed(L("The app needs a name."))) }
        let app = folder.appendingPathComponent(safeName + ".app")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }
            try fm.copyItem(at: Bundle.main.bundleURL, to: app)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }

        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSMutableDictionary(contentsOf: plistURL) else { return .failure(.failed(L("Couldn't create the app."))) }
        let slug = (c.startURL.host ?? safeName).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        plist["CFBundleIdentifier"] = "com.lumen.webapp." + slug
        plist["CFBundleName"] = safeName
        plist["CFBundleDisplayName"] = safeName
        plist["LumenWebAppURL"] = c.startURL.absoluteString
        plist.removeObject(forKey: "CFBundleURLTypes")
        plist.removeObject(forKey: "CFBundleDocumentTypes")

        if let icon = c.icon, let icns = makeIcon(icon, in: app) {
            plist["CFBundleIconFile"] = icns
        }
        guard plist.write(to: plistURL, atomically: true) else { return .failure(.failed(L("Couldn't create the app."))) }

        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        guard run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path]) else {
            return .failure(.failed(L("Couldn't sign the app.")))
        }
        return .success(app)
    }

    /// Draws the site icon on a macOS-style rounded square and writes an .icns.
    private static func makeIcon(_ image: NSImage, in app: URL) -> String? {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-icon-" + UUID().uuidString + ".iconset")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                                      ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
        for (name, px) in sizes {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            let s = CGFloat(px) / 1024
            let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
            let path = NSBezierPath(roundedRect: body, xRadius: 184 * s, yRadius: 184 * s)
            NSColor.white.setFill()
            path.fill()
            path.addClip()
            image.draw(in: body.insetBy(dx: 70 * s, dy: 70 * s), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: work.appendingPathComponent("icon_\(name).png"))
        }
        let name = "AppIcon"
        let out = app.appendingPathComponent("Contents/Resources/\(name).icns")
        return run("/usr/bin/iconutil", ["-c", "icns", work.path, "-o", out.path]) ? name : nil
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
}
