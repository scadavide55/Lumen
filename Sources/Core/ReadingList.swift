import AppKit
import Observation
import WebKit

/// Articles saved from Reader to read later without a connection: the Reader page with its images inside it,
/// kept as one HTML file on this Mac.
@Observable
final class ReadingList {
    static let shared = ReadingList()

    struct Article: Codable, Identifiable, Equatable {
        var id = UUID()
        var title: String
        var site: String
        var url: URL
        var saved = Date()
        var bytes = 0
        var read = false
    }

    private(set) var items: [Article] = []
    /// Addresses being saved right now, to show progress.
    private(set) var saving: Set<URL> = []
    @ObservationIgnored private let folder = Paths.folder("Reading List")
    @ObservationIgnored private let index = StoredFile<[Article]>("Reading List/index.json")

    private init() {
        items = (index.load() ?? []).filter { FileManager.default.fileExists(atPath: file(for: $0.id).path) }
    }

    func file(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".html") }

    func article(for url: URL?) -> Article? {
        guard let url else { return nil }
        return items.first { $0.url == url }
    }

    func html(of article: Article) -> String? { try? String(contentsOf: file(for: article.id), encoding: .utf8) }

    func markRead(_ id: UUID, _ read: Bool = true) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].read != read else { return }
        items[i].read = read
        index.saveNow(items)
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        index.saveNow(items)
        try? FileManager.default.removeItem(at: file(for: id))
    }

    func removeAll() {
        for a in items { try? FileManager.default.removeItem(at: file(for: a.id)) }
        items = []
        index.saveNow(items)
    }

    // MARK: Saving

    static let imageLimit = 60
    static let imageBytesLimit = 8_000_000
    static let totalBytesLimit = 60_000_000

    /// Saves the Reader page shown in `webView`, downloading its images into the file so it opens offline.
    @MainActor
    func save(readerIn webView: WKWebView, url: URL, title: String) async -> Bool {
        guard !saving.contains(url) else { return false }
        saving.insert(url)
        defer { saving.remove(url) }
        // 1. The images the page shows, at the size it shows them.
        let list = (try? await webView.evaluateJavaScript(Self.imagesScript, in: nil, contentWorld: .defaultClient)) as? [String] ?? []
        var images: [String: String] = [:]
        var total = 0
        for src in list.prefix(Self.imageLimit) {
            guard let u = URL(string: src), ["http", "https"].contains(u.scheme ?? ""),
                  let (data, type) = await Self.download(u), total + data.count <= Self.totalBytesLimit else { continue }
            total += data.count
            images[src] = "data:\(type);base64," + data.base64EncodedString()
        }
        // 2. The page with those images inside it, and without anything that would reach the network.
        let html = try? await webView.callAsyncJavaScript(Self.inlineScript, arguments: ["images": images], in: nil, contentWorld: .defaultClient) as? String
        guard let html, !html.isEmpty else { return false }
        let site = InputResolver.displayHost(url)
        var article = article(for: url) ?? Article(title: title, site: site, url: url)
        article.title = title
        article.saved = Date()
        article.bytes = html.utf8.count
        article.read = false
        do {
            try html.write(to: file(for: article.id), atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        items.removeAll { $0.id == article.id }
        items.insert(article, at: 0)
        index.saveNow(items)
        return true
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    /// Only public addresses, since a page could point its images at the local network.
    private static func download(_ url: URL) async -> (Data, String)? {
        guard WebTools.isPublic(url),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= imageBytesLimit else { return nil }
        let type = response.mimeType?.lowercased() ?? ""
        guard type.hasPrefix("image/"), type != "image/svg+xml" else { return nil }
        return (data, type)
    }

    static let imagesScript = """
    [...new Set([...document.images].map(i => i.currentSrc || i.src).filter(s => /^https?:/.test(s)))]
    """

    /// Puts the downloaded images in place and returns a page that loads nothing from the network.
    static let inlineScript = """
    const doc = document.documentElement.cloneNode(true);
    const live = [...document.images];
    [...doc.querySelectorAll('img')].forEach((img, n) => {
      const src = live[n] ? (live[n].currentSrc || live[n].src) : img.src;
      img.removeAttribute('srcset');
      img.removeAttribute('sizes');
      img.removeAttribute('loading');
      if (images[src]) img.setAttribute('src', images[src]); else img.remove();
    });
    doc.querySelectorAll('picture source, script, iframe, video, audio, object, embed, link[rel=preload], link[rel=prefetch]').forEach(e => e.remove());
    const meta = doc.querySelector('head') && document.createElement('meta');
    if (meta) {
      meta.setAttribute('http-equiv', 'Content-Security-Policy');
      meta.setAttribute('content', "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:");
      doc.querySelector('head').prepend(meta);
    }
    return '<!doctype html>' + doc.outerHTML;
    """
}

extension Tab {
    /// Saves this page for offline reading, switching to Reader first if needed.
    @MainActor
    func saveForOffline() {
        guard !isPrivate, url != nil else { return }
        if isReader {
            Task { await finishOfflineSave() }
        } else {
            toggleReader { [weak self] ok in
                guard ok, let self else { return }
                // Reader's page has to finish loading before it can be saved.
                Task { @MainActor in
                    for _ in 0..<40 where self.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
                    await self.finishOfflineSave()
                }
            }
        }
    }

    @MainActor
    private func finishOfflineSave() async {
        guard let wv = webView, let origin = readerSource else { return }
        let ok = await ReadingList.shared.save(readerIn: wv, url: origin, title: title)
        if !ok { NSSound.beep() }
    }

    /// Opens a saved article in this tab, as Reader, without the network.
    @MainActor
    func openOffline(_ article: ReadingList.Article) {
        guard let html = ReadingList.shared.html(of: article) else { NSSound.beep(); return }
        showReader(html: html, origin: article.url)
        ReadingList.shared.markRead(article.id)
    }
}
