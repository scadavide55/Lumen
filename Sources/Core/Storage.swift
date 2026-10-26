import AppKit
import WebKit

// MARK: - Files

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Lumen", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func file(_ name: String) -> URL { support.appendingPathComponent(name) }

    static func folder(_ name: String) -> URL {
        let url = support.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A JSON document on disk with debounced background writes.
final class JSONFile<T: Codable> {
    let url: URL
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "lumen.storage", qos: .utility)

    init(_ name: String) { url = Paths.file(name) }

    func load() -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(T.self, from: data)
    }

    func save(_ value: T, delay: TimeInterval = 1) {
        pending?.cancel()
        let url = url
        let item = DispatchWorkItem {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func saveNow(_ value: T) {
        pending?.cancel()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        if let data = try? encoder.encode(value) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Bookmarks

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: URL
    var added = Date()
}

final class Bookmarks: ObservableObject {
    static let shared = Bookmarks()
    @Published private(set) var items: [Bookmark]
    private let file = JSONFile<[Bookmark]>("bookmarks.json")

    private init() { items = file.load() ?? [] }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        return items.contains { $0.url == url }
    }

    func toggle(url: URL?, title: String) {
        guard let url else { return }
        if contains(url) { items.removeAll { $0.url == url } } else { items.append(Bookmark(title: title, url: url)) }
        persist()
    }

    func add(url: URL, title: String) {
        guard !contains(url) else { return }
        items.append(Bookmark(title: title, url: url))
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Adds bookmarks from another browser, skipping URLs already saved. Returns how many were added.
    func importItems(_ list: [(String, URL)]) -> Int {
        var known = Set(items.map(\.url))
        var added = 0
        for (title, url) in list where !known.contains(url) {
            known.insert(url)
            items.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    /// Imports a Netscape bookmark file (the format Safari, Chrome and Firefox export).
    func importHTML(_ html: String) -> Int {
        let pattern = #"<A[^>]*HREF="([^"]+)"[^>]*>(.*?)</A>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return 0 }
        let ns = html as NSString
        var added = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let title = Self.unescape(ns.substring(with: m.range(at: 2)))
            guard let url = URL(string: href), ["http", "https"].contains(url.scheme ?? ""), !contains(url) else { continue }
            items.append(Bookmark(title: title.isEmpty ? (url.host ?? href) : title, url: url))
            added += 1
        }
        persist()
        return added
    }

    func exportHTML() -> String {
        var out = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>

        """
        for b in items {
            let t = b.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            out += "    <DT><A HREF=\"\(b.url.absoluteString)\" ADD_DATE=\"\(Int(b.added.timeIntervalSince1970))\">\(t)</A>\n"
        }
        return out + "</DL><p>\n"
    }

    private static func unescape(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            r = r.replacingOccurrences(of: k, with: v)
        }
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persist() { file.save(items) }
}

// MARK: - History

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var date: Date
    var visits: Int = 1
}

final class History: ObservableObject {
    static let shared = History()
    /// Newest first, one entry per URL.
    @Published private(set) var entries: [HistoryEntry]
    private let file = JSONFile<[HistoryEntry]>("history.json")
    private let limit = 10_000

    private init() { entries = file.load() ?? [] }

    func record(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme ?? "") else { return }
        var entry = HistoryEntry(url: url, title: title, date: Date())
        if let i = entries.firstIndex(where: { $0.url == url }) {
            entry = entries.remove(at: i)
            entry.date = Date()
            entry.visits += 1
            if !title.isEmpty { entry.title = title }
        }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        persist()
    }

    /// Merges history from another browser, keeping the newest visit per URL. Returns how many entries were new.
    func importEntries(_ list: [HistoryEntry]) -> Int {
        guard !list.isEmpty else { return 0 }
        var byURL = Dictionary(entries.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
        var added = 0
        for e in list where ["http", "https"].contains(e.url.scheme ?? "") {
            if var old = byURL[e.url] {
                old.visits += e.visits
                if e.date > old.date { old.date = e.date }
                if old.title.isEmpty { old.title = e.title }
                byURL[e.url] = old
            } else {
                byURL[e.url] = e
                added += 1
            }
        }
        entries = Array(byURL.values.sorted { $0.date > $1.date }.prefix(limit))
        file.saveNow(entries)
        return added
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let i = entries.prefix(20).firstIndex(where: { $0.url == url }),
              entries[i].title != title else { return }
        entries[i].title = title
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
        persist()
    }

    func clear(since date: Date? = nil) {
        if let date { entries.removeAll { $0.date >= date } } else { entries.removeAll() }
        file.saveNow(entries)
    }

    /// Ranked matches for the command palette: title/URL contains every word, frequent and recent first.
    func search(_ query: String, limit: Int = 8) -> [HistoryEntry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let now = Date()
        return entries.lazy
            .filter { e in
                let hay = (e.title + " " + e.url.absoluteString).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .prefix(200)
            .map { e -> (HistoryEntry, Double) in
                let age = now.timeIntervalSince(e.date) / 86_400
                var score = Double(e.visits) / (1 + age)
                if e.url.host?.lowercased().hasPrefix(words[0]) == true || e.url.host?.lowercased().hasPrefix("www." + words[0]) == true { score += 10 }
                return (e, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private func persist() { file.save(entries, delay: 2) }
}

// MARK: - Session

struct TabSnapshot: Codable {
    var url: URL?
    var title: String
    var pinned: Bool
    var state: Data?
}

struct WindowSnapshot: Codable {
    var tabs: [TabSnapshot]
    var selected: Int
}

final class Session {
    static let shared = Session()
    private let file = JSONFile<[WindowSnapshot]>("session.json")
    private var pending: [WindowSnapshot] = []
    private var extraWindowsClaimed = false

    private init() {
        if Settings.shared.restoreSession { pending = file.load() ?? [] }
    }

    func takePending() -> WindowSnapshot? { pending.isEmpty ? nil : pending.removeFirst() }

    /// Number of extra windows to open at launch. Returns non-zero only once.
    func claimExtraWindows() -> Int {
        guard !extraWindowsClaimed else { return 0 }
        extraWindowsClaimed = true
        return pending.count
    }

    func scheduleSave() {
        let snaps = WindowRegistry.shared.browsers.filter { !$0.isPrivate }.map { $0.snapshot() }
        guard !snaps.isEmpty else { return }
        file.save(snaps, delay: 2)
    }

    func saveNow() {
        let snaps = WindowRegistry.shared.browsers.filter { !$0.isPrivate }.map { $0.snapshot() }
        guard !snaps.isEmpty else { return }
        file.saveNow(snaps)
    }
}

// MARK: - Window registry

final class WindowRegistry {
    static let shared = WindowRegistry()
    private let table = NSHashTable<BrowserState>.weakObjects()
    weak var lastFocused: BrowserState?
    private(set) var pendingURLs: [URL] = []

    var browsers: [BrowserState] { table.allObjects }

    func add(_ b: BrowserState) { table.add(b) }

    func takePendingURLs() -> [URL] {
        defer { pendingURLs = [] }
        return pendingURLs
    }

    /// Opens URLs in the frontmost normal window. Returns false when no window exists yet.
    @discardableResult
    func open(_ urls: [URL]) -> Bool {
        let target = (lastFocused.flatMap { $0.isPrivate ? nil : $0 }) ?? browsers.first { !$0.isPrivate }
        guard let b = target else {
            pendingURLs += urls
            return false
        }
        for u in urls { b.newTab(url: u) }
        b.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

// MARK: - Favicons

final class Favicons {
    static let shared = Favicons()
    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private let folder = Paths.folder("Favicons")
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    func cached(_ host: String?) -> NSImage? {
        guard let host = host?.lowercased() else { return nil }
        if let img = memory[host] { return img }
        let file = folder.appendingPathComponent(host + ".icon")
        if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
            memory[host] = img
            return img
        }
        return nil
    }

    func fetch(_ url: URL, host: String, persist: Bool, done: @escaping (NSImage) -> Void) {
        let key = host.lowercased()
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        session.dataTask(with: url) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(key)
                guard let data, data.count < 1_000_000,
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                      let img = NSImage(data: data), img.isValid else { return }
                self.memory[key] = img
                if persist { try? data.write(to: self.folder.appendingPathComponent(key + ".icon"), options: .atomic) }
                done(img)
            }
        }.resume()
    }

    func clearDisk() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
}
