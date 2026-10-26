import AppKit
import CommonCrypto
import SQLite3
import WebKit

// MARK: - Model

struct BrowserSource: Identifiable, Hashable {
    enum Kind { case chromium, firefox, safari }

    let id: String
    let name: String
    let kind: Kind
    let bundleID: String?
    let keychainService: String?
    let profiles: [BrowserProfile]

    var icon: NSImage? {
        bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

struct BrowserProfile: Identifiable, Hashable {
    var id: String { path.path }
    let name: String
    let path: URL
}

struct ImportOptions {
    var bookmarks = true
    var history = true
    var cookies = true
}

struct ImportResult {
    var bookmarks = 0
    var history = 0
    var cookies = 0
    var warnings: [String] = []
    var needsFullDiskAccess = false
}

// MARK: - Detection

enum BrowserImporter {
    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

    /// Known Chromium browsers: data folder, name, bundle ID, Keychain item holding the cookie key.
    private static let chromium: [String: (String, String, String)] = [
        "Google/Chrome": ("Google Chrome", "com.google.Chrome", "Chrome Safe Storage"),
        "Google/Chrome Beta": ("Chrome Beta", "com.google.Chrome.beta", "Chrome Safe Storage"),
        "Google/Chrome Canary": ("Chrome Canary", "com.google.Chrome.canary", "Chrome Safe Storage"),
        "Chromium": ("Chromium", "org.chromium.Chromium", "Chromium Safe Storage"),
        "BraveSoftware/Brave-Browser": ("Brave", "com.brave.Browser", "Brave Safe Storage"),
        "BraveSoftware/Brave-Browser-Beta": ("Brave Beta", "com.brave.Browser.beta", "Brave Safe Storage"),
        "Microsoft Edge": ("Microsoft Edge", "com.microsoft.edgemac", "Microsoft Edge Safe Storage"),
        "Vivaldi": ("Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi Safe Storage"),
        "com.operasoftware.Opera": ("Opera", "com.operasoftware.Opera", "Opera Safe Storage"),
        "com.operasoftware.OperaGX": ("Opera GX", "com.operasoftware.OperaGX", "Opera Safe Storage"),
        "com.operasoftware.OperaAir": ("Opera Air", "com.operasoftware.OperaAir", "Opera Safe Storage"),
        "Arc/User Data": ("Arc", "company.thebrowser.Browser", "Arc Safe Storage"),
        "net.imput.helium": ("Helium", "net.imput.helium", "Helium Storage Key"),
        "Yandex/YandexBrowser": ("Yandex Browser", "ru.yandex.desktop.yandex-browser", "Yandex Safe Storage"),
        "Thorium": ("Thorium", "org.chromium.Thorium", "Thorium Safe Storage"),
        "Comet": ("Comet", "ai.perplexity.comet", "Comet Safe Storage"),
        "Dia/User Data": ("Dia", "company.thebrowser.dia", "Dia Safe Storage"),
    ]

    private static let firefox: [String: (String, String)] = [
        "Firefox": ("Firefox", "org.mozilla.firefox"),
        "zen": ("Zen", "app.zen-browser.zen"),
        "librewolf": ("LibreWolf", "io.gitlab.librewolf-community"),
        "Waterfox": ("Waterfox", "net.waterfox.waterfox"),
        "Floorp": ("Floorp", "one.ablaze.floorp"),
    ]

    /// Browsers with data on this Mac, found by scanning Application Support.
    static func detect() -> [BrowserSource] {
        var out: [BrowserSource] = []
        let fm = FileManager.default

        if fm.fileExists(atPath: "/Applications/Safari.app") || fm.fileExists(atPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app") {
            let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari")
            out.append(BrowserSource(id: "safari", name: "Safari", kind: .safari, bundleID: "com.apple.Safari",
                                     keychainService: nil, profiles: [BrowserProfile(name: "Default", path: dir)]))
        }

        // Every folder (one or two levels deep) with a Chromium "Local State" file and a profile that has history.
        var candidates: [String] = []
        for top in (try? fm.contentsOfDirectory(atPath: support.path)) ?? [] {
            candidates.append(top)
            let sub = support.appendingPathComponent(top)
            for child in (try? fm.contentsOfDirectory(atPath: sub.path)) ?? [] { candidates.append(top + "/" + child) }
        }
        for rel in candidates.sorted() {
            let dir = support.appendingPathComponent(rel)
            guard fm.fileExists(atPath: dir.appendingPathComponent("Local State").path) else { continue }
            let profiles = chromiumProfiles(dir)
            guard !profiles.isEmpty else { continue }
            let known = chromium[rel]
            // Electron apps also ship a Chromium profile; an unknown one counts only if it has browsed somewhere.
            if known == nil && !profiles.contains(where: hasBrowsed) { continue }
            let fallback = rel.split(separator: "/").last.map(String.init) ?? rel
            out.append(BrowserSource(id: dir.path, name: known?.0 ?? fallback, kind: .chromium, bundleID: known?.1,
                                     keychainService: known?.2 ?? "\(fallback) Safe Storage", profiles: profiles))
        }

        for (folder, info) in firefox {
            let dir = support.appendingPathComponent(folder).appendingPathComponent("Profiles")
            let profiles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name -> BrowserProfile? in
                let p = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: p.appendingPathComponent("places.sqlite").path) else { return nil }
                let label = name.split(separator: ".", maxSplits: 1).last.map(String.init) ?? name
                return BrowserProfile(name: label, path: p)
            }
            if !profiles.isEmpty {
                out.append(BrowserSource(id: dir.path, name: info.0, kind: .firefox, bundleID: info.1, keychainService: nil, profiles: profiles))
            }
        }
        return out
    }

    private static func hasBrowsed(_ profile: BrowserProfile) -> Bool {
        guard let db = SQLiteCopy(profile.path.appendingPathComponent("History")) else { return false }
        var count = 0
        db.rows("SELECT COUNT(*) FROM urls WHERE url LIKE 'http%'") { count = Int($0.int(0)) }
        return count > 0
    }

    private static func chromiumProfiles(_ dir: URL) -> [BrowserProfile] {
        let fm = FileManager.default
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: dir.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (key, value) in cache { names[key] = ((value as? [String: Any])?["name"] as? String) ?? key }
        }
        if names.isEmpty { names["Default"] = "Default" }
        var out = names.keys.sorted().compactMap { key -> BrowserProfile? in
            let p = dir.appendingPathComponent(key)
            return fm.fileExists(atPath: p.appendingPathComponent("History").path) ? BrowserProfile(name: names[key]!, path: p) : nil
        }
        // Older Opera keeps its only profile in the root folder.
        if out.isEmpty, fm.fileExists(atPath: dir.appendingPathComponent("History").path) {
            out.append(BrowserProfile(name: "Default", path: dir))
        }
        return out
    }

    // MARK: Import

    /// Reads on a background queue, then merges into Lumen on the main queue.
    static func run(_ source: BrowserSource, profile: BrowserProfile, options: ImportOptions,
                    done: @escaping (ImportResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var (result, marks, visits, cookies) = load(source, profile: profile, options: options)
            DispatchQueue.main.async {
                result.bookmarks = Bookmarks.shared.importItems(marks)
                result.history = History.shared.importEntries(visits)
                let store = WKWebsiteDataStore.default().httpCookieStore
                let group = DispatchGroup()
                for c in cookies {
                    group.enter()
                    store.setCookie(c) { group.leave() }
                }
                group.notify(queue: .main) {
                    result.cookies = cookies.count
                    done(result)
                }
            }
        }
    }

    /// Reads another browser's data without changing anything in Lumen.
    static func load(_ source: BrowserSource, profile: BrowserProfile, options: ImportOptions)
        -> (ImportResult, [(String, URL)], [HistoryEntry], [HTTPCookie]) {
            var result = ImportResult()
            var marks: [(String, URL)] = []
            var visits: [HistoryEntry] = []
            var cookies: [HTTPCookie] = []
            do {
                switch source.kind {
                case .chromium:
                    if options.bookmarks { marks = try chromiumBookmarks(profile.path) }
                    if options.history { visits = try chromiumHistory(profile.path) }
                    if options.cookies { cookies = try chromiumCookies(profile.path, service: source.keychainService ?? "", result: &result) }
                case .firefox:
                    if options.bookmarks { marks = try firefoxBookmarks(profile.path) }
                    if options.history { visits = try firefoxHistory(profile.path) }
                    if options.cookies { cookies = try firefoxCookies(profile.path) }
                case .safari:
                    if options.bookmarks { marks = try safariBookmarks(profile.path) }
                    if options.history { visits = try safariHistory(profile.path) }
                    if options.cookies { cookies = try safariCookies() }
                }
            } catch ImportError.permission {
                result.needsFullDiskAccess = true
                result.warnings.append(String(format: L("macOS blocked access to %@'s data. Give Lumen Full Disk Access, then try again."), source.name))
            } catch {
                result.warnings.append(error.localizedDescription)
            }
            return (result, marks, visits, cookies)
    }

    enum ImportError: LocalizedError {
        case permission
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .permission: L("Permission denied")
            case .unreadable(let what): String(format: L("Couldn't read %@."), what)
            }
        }
    }

    private static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch let e as NSError {
            if e.code == NSFileReadNoPermissionError || (e.underlyingErrors.first as NSError?)?.code == Int(EPERM) { throw ImportError.permission }
            throw ImportError.unreadable(url.lastPathComponent)
        }
    }

    private static func open(_ url: URL) throws -> SQLiteCopy {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if FileManager.default.fileExists(atPath: url.path) { throw ImportError.permission }
            throw ImportError.unreadable(url.lastPathComponent)
        }
        guard let db = SQLiteCopy(url) else { throw ImportError.permission }
        return db
    }

    private static let historyLimit = 10_000

    // MARK: Chromium

    private static func chromiumBookmarks(_ profile: URL) throws -> [(String, URL)] {
        let file = profile.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: read(file)) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return [] }
        var out: [(String, URL)] = []
        func walk(_ node: [String: Any]) {
            if node["type"] as? String == "url", let s = node["url"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
                out.append((node["name"] as? String ?? s, u))
            }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let root = roots[key] as? [String: Any] { walk(root) }
        }
        return out
    }

    /// Chromium times are microseconds since 1601.
    private static func chromeDate(_ t: Int64) -> Date {
        Date(timeIntervalSince1970: Double(t) / 1_000_000 - 11_644_473_600)
    }

    private static func chromiumHistory(_ profile: URL) throws -> [HistoryEntry] {
        let db = try open(profile.appendingPathComponent("History"))
        var out: [HistoryEntry] = []
        db.rows("SELECT url, title, visit_count, last_visit_time FROM urls WHERE hidden = 0 AND last_visit_time > 0 ORDER BY last_visit_time DESC LIMIT \(historyLimit)") { r in
            guard let s = r.text(0), let u = URL(string: s) else { return }
            out.append(HistoryEntry(url: u, title: r.text(1) ?? "", date: chromeDate(r.int(3)), visits: max(1, Int(r.int(2)))))
        }
        return out
    }

    private static func chromiumCookies(_ profile: URL, service: String, result: inout ImportResult) throws -> [HTTPCookie] {
        let file = [profile.appendingPathComponent("Network/Cookies"), profile.appendingPathComponent("Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file else { return [] }
        guard let key = chromiumKey(service) else {
            result.warnings.append(String(format: L("Sign-ins weren't imported: Lumen couldn't read “%@” from your Keychain."), service))
            return []
        }
        let db = try open(file)
        var version = 0
        db.rows("SELECT value FROM meta WHERE key = 'version'") { version = Int($0.text(0) ?? "") ?? 0 }
        var out: [HTTPCookie] = []
        db.rows("SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite FROM cookies") { r in
            var value = r.text(2) ?? ""
            let enc = r.blob(3)
            if value.isEmpty, enc.count > 3 {
                guard let plain = decrypt(enc, key: key) else { return }
                // Since Chrome 130 the plaintext starts with a SHA-256 of the domain.
                let body = version >= 24 && plain.count >= 32 ? plain.dropFirst(32) : plain[...]
                value = String(decoding: body, as: UTF8.self)
            }
            let expires = r.int(5)
            if let c = cookie(domain: r.text(0) ?? "", name: r.text(1) ?? "", value: value, path: r.text(4) ?? "/",
                              expires: expires > 0 ? chromeDate(expires) : nil, secure: r.int(6) != 0,
                              httpOnly: r.int(7) != 0, sameSite: Int(r.int(8))) {
                out.append(c)
            }
        }
        return out
    }

    /// The AES key Chromium derives from its Keychain password. macOS asks the user first.
    private static func chromiumKey(_ service: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let password = item as? Data else { return nil }
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let status = key.withUnsafeMutableBytes { k in
            password.withUnsafeBytes { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                     k.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }
        }
        return status == kCCSuccess ? key : nil
    }

    private static func decrypt(_ data: Data, key: Data) -> Data? {
        guard data.starts(with: Array("v10".utf8)) || data.starts(with: Array("v11".utf8)) else { return nil }
        let cipher = data.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = Data(count: cipher.count + 16)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { o in
            cipher.withUnsafeBytes { c in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, iv, c.baseAddress, cipher.count, o.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    // MARK: Firefox

    private static func firefoxBookmarks(_ profile: URL) throws -> [(String, URL)] {
        let db = try open(profile.appendingPathComponent("places.sqlite"))
        var out: [(String, URL)] = []
        db.rows("SELECT b.title, p.url FROM moz_bookmarks b JOIN moz_places p ON b.fk = p.id WHERE b.type = 1 AND p.url LIKE 'http%' ORDER BY b.parent, b.position") { r in
            guard let s = r.text(1), let u = URL(string: s) else { return }
            out.append((r.text(0) ?? s, u))
        }
        return out
    }

    private static func firefoxHistory(_ profile: URL) throws -> [HistoryEntry] {
        let db = try open(profile.appendingPathComponent("places.sqlite"))
        var out: [HistoryEntry] = []
        db.rows("SELECT url, title, visit_count, last_visit_date FROM moz_places WHERE last_visit_date IS NOT NULL AND hidden = 0 AND url LIKE 'http%' ORDER BY last_visit_date DESC LIMIT \(historyLimit)") { r in
            guard let s = r.text(0), let u = URL(string: s) else { return }
            out.append(HistoryEntry(url: u, title: r.text(1) ?? "", date: Date(timeIntervalSince1970: Double(r.int(3)) / 1_000_000),
                                    visits: max(1, Int(r.int(2)))))
        }
        return out
    }

    private static func firefoxCookies(_ profile: URL) throws -> [HTTPCookie] {
        let file = profile.appendingPathComponent("cookies.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try open(file)
        var out: [HTTPCookie] = []
        db.rows("SELECT host, name, value, path, expiry, isSecure, isHttpOnly, sameSite FROM moz_cookies") { r in
            var expiry = Double(r.int(4))
            if expiry > 100_000_000_000 { expiry /= 1000 } // newer Firefox stores milliseconds
            // Firefox: 0 none, 1 lax, 2 strict. Chromium numbering is used by cookie().
            let same = [0: 0, 1: 1, 2: 2][Int(r.int(7))] ?? -1
            if let c = cookie(domain: r.text(0) ?? "", name: r.text(1) ?? "", value: r.text(2) ?? "", path: r.text(3) ?? "/",
                              expires: expiry > 0 ? Date(timeIntervalSince1970: expiry) : nil,
                              secure: r.int(5) != 0, httpOnly: r.int(6) != 0, sameSite: same) {
                out.append(c)
            }
        }
        return out
    }

    // MARK: Safari

    private static func safariBookmarks(_ dir: URL) throws -> [(String, URL)] {
        let data = try read(dir.appendingPathComponent("Bookmarks.plist"))
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        var out: [(String, URL)] = []
        func walk(_ node: [String: Any]) {
            if node["Title"] as? String == "com.apple.ReadingList" { return }
            if node["WebBookmarkType"] as? String == "WebBookmarkTypeLeaf",
               let s = node["URLString"] as? String, let u = URL(string: s), u.scheme?.hasPrefix("http") == true {
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                out.append((title ?? s, u))
            }
            for child in node["Children"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(root)
        return out
    }

    private static func safariHistory(_ dir: URL) throws -> [HistoryEntry] {
        _ = try read(dir.appendingPathComponent("History.db"))
        let db = try open(dir.appendingPathComponent("History.db"))
        var out: [HistoryEntry] = []
        db.rows("SELECT i.url, v.title, i.visit_count, MAX(v.visit_time) AS t FROM history_items i JOIN history_visits v ON v.history_item = i.id GROUP BY i.id ORDER BY t DESC LIMIT \(historyLimit)") { r in
            guard let s = r.text(0), let u = URL(string: s) else { return }
            out.append(HistoryEntry(url: u, title: r.text(1) ?? "", date: Date(timeIntervalSinceReferenceDate: r.double(3)),
                                    visits: max(1, Int(r.int(2)))))
        }
        return out
    }

    /// Parses Safari's Cookies.binarycookies file.
    private static func safariCookies() throws -> [HTTPCookie] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let file = [home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"),
                    home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let file else { return [] }
        let d = [UInt8](try read(file))
        guard d.count > 8, Array(d[0..<4]) == Array("cook".utf8) else { return [] }
        func be32(_ o: Int) -> Int { Int(d[o]) << 24 | Int(d[o + 1]) << 16 | Int(d[o + 2]) << 8 | Int(d[o + 3]) }
        func le32(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 | Int(d[o + 2]) << 16 | Int(d[o + 3]) << 24 }
        func leDouble(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(d[o + i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }
        func cString(_ o: Int, end: Int) -> String {
            guard o < end else { return "" }
            var e = o
            while e < end && d[e] != 0 { e += 1 }
            return String(decoding: d[o..<e], as: UTF8.self)
        }
        let pages = be32(4)
        var sizes: [Int] = []
        for i in 0..<pages where 8 + i * 4 + 4 <= d.count { sizes.append(be32(8 + i * 4)) }
        var offset = 8 + pages * 4
        var out: [HTTPCookie] = []
        for size in sizes {
            let page = offset
            offset += size
            guard page + 8 <= d.count, page + size <= d.count else { break }
            let count = le32(page + 4)
            for i in 0..<count {
                let rec = page + le32(page + 8 + i * 4)
                guard rec + 56 <= page + size else { continue }
                let end = rec + le32(rec)
                let flags = le32(rec + 8)
                let host = cString(rec + le32(rec + 16), end: end)
                let name = cString(rec + le32(rec + 20), end: end)
                let path = cString(rec + le32(rec + 24), end: end)
                let value = cString(rec + le32(rec + 28), end: end)
                let expiry = leDouble(rec + 40)
                if let c = cookie(domain: host, name: name, value: value, path: path.isEmpty ? "/" : path,
                                  expires: expiry > 0 ? Date(timeIntervalSinceReferenceDate: expiry) : nil,
                                  secure: flags & 1 != 0, httpOnly: flags & 4 != 0, sameSite: -1) {
                    out.append(c)
                }
            }
        }
        return out
    }

    // MARK: Helpers

    /// sameSite uses Chromium numbering: 0 none, 1 lax, 2 strict, anything else unspecified.
    private static func cookie(domain: String, name: String, value: String, path: String, expires: Date?,
                               secure: Bool, httpOnly: Bool, sameSite: Int) -> HTTPCookie? {
        guard !domain.isEmpty, !name.isEmpty else { return nil }
        if let expires, expires < Date() { return nil }
        var p: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: value]
        if let expires { p[.expires] = expires }
        if secure { p[.secure] = "TRUE" }
        if httpOnly { p[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if sameSite == 1 { p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax }
        if sameSite == 2 { p[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict }
        return HTTPCookie(properties: p)
    }
}

// MARK: - SQLite

/// Opens a private copy of a database, since the owning browser may hold a lock on it.
final class SQLiteCopy {
    private var db: OpaquePointer?
    private let dir: URL

    init?(_ source: URL) {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-import-" + UUID().uuidString)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent("db.sqlite")
            try fm.copyItem(at: source, to: target)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: target.path + suffix)) }
            }
            guard sqlite3_open_v2(target.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return nil }
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dir)
    }

    func rows(_ sql: String, _ body: (Row) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { body(Row(stmt: stmt)) }
    }

    struct Row {
        let stmt: OpaquePointer
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func blob(_ i: Int32) -> Data {
            guard let p = sqlite3_column_blob(stmt, i) else { return Data() }
            return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }
}
