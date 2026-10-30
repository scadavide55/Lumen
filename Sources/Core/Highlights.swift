import AppKit

/// A passage you marked on a page, in a colour, with an optional note. It's found again on the page by the words
/// around it, and stays in Library › Highlights even if the page changes and the passage is gone.
struct Highlight: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The page, without its #fragment.
    var url: URL
    var title: String
    var quote: String
    /// A few characters before and after, to tell this passage from the same words elsewhere on the page.
    var prefix: String
    var suffix: String
    var color = 0
    var note = ""
    var date = Date()

    static let colors: [(css: String, swatch: NSColor, name: String)] = [
        ("rgba(253, 224, 71, .55)", .systemYellow, "Yellow"),
        ("rgba(134, 239, 172, .55)", .systemGreen, "Green"),
        ("rgba(147, 197, 253, .55)", .systemBlue, "Blue"),
        ("rgba(249, 168, 212, .55)", .systemPink, "Pink"),
        ("rgba(196, 181, 253, .6)", .systemPurple, "Purple"),
    ]

    var css: String { Self.colors[color % Self.colors.count].css }

    /// The quote on one line, as it reads.
    var plainQuote: String { quote.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// "> the passage" with the note and a link to the page, for notes apps such as Obsidian.
    var markdown: String {
        var out = plainQuote.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n")
        if !note.isEmpty { out += "\n\n" + note }
        let title = (self.title.isEmpty ? url.host ?? url.absoluteString : self.title).replacingOccurrences(of: "]", with: "\\]")
        return out + "\n\n— [\(title)](\(url.absoluteString))"
    }

    /// The page's address with a text fragment, so opening it scrolls to the passage and marks it.
    var linkToPassage: URL {
        let words = plainQuote.split(separator: " ")
        let fragment: String
        func enc(_ s: some StringProtocol) -> String {
            String(s).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        }
        if words.count > 12 {
            fragment = enc(words.prefix(5).joined(separator: " ")) + "," + enc(words.suffix(5).joined(separator: " "))
        } else {
            fragment = enc(plainQuote)
        }
        return URL(string: url.absoluteString + "#:~:text=" + fragment) ?? url
    }

    static func pageKey(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.fragment = nil
        return c.url ?? url
    }
}

@Observable
final class Highlights {
    static let shared = Highlights()

    private(set) var items: [Highlight] = []
    @ObservationIgnored private let file = StoredFile<[Highlight]>("highlights.json")

    private init() {
        items = file.load() ?? []
    }

    func on(_ url: URL?) -> [Highlight] {
        guard let url else { return [] }
        let key = Highlight.pageKey(url)
        return items.filter { $0.url == key }
    }

    func add(_ h: Highlight) {
        items.insert(h, at: 0)
        persist()
    }

    func update(_ id: UUID, _ change: (inout Highlight) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        persist()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    /// All of them as one Markdown document, newest page first, grouped by page.
    func markdown(_ list: [Highlight]? = nil) -> String {
        let all = list ?? items
        var pages: [URL] = []
        for h in all where !pages.contains(h.url) { pages.append(h.url) }
        return pages.map { page in
            let hs = all.filter { $0.url == page }
            let title = hs.first.map { $0.title.isEmpty ? page.absoluteString : $0.title } ?? page.absoluteString
            return "## [\(title)](\(page.absoluteString))\n\n" + hs.map { h in
                h.plainQuote.split(separator: "\n").map { "> " + $0 }.joined(separator: "\n") + (h.note.isEmpty ? "" : "\n\n" + h.note)
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n")
    }

    private func persist() { file.save(items) }
}
