import Foundation

/// Text you were writing in a page's field (a comment, a message, a form), kept on this Mac until it's sent, so a
/// reload, a crash or a closed tab doesn't lose it. Only long text in text fields and editors; never passwords, card
/// numbers or private windows, and nothing older than a week.
struct Draft: Codable, Identifiable, Equatable {
    var id: String { page.absoluteString + "\u{1}" + field }
    /// The page, without its #fragment.
    var page: URL
    /// Which field, as the page names it (its name or id, or its place among the page's fields).
    var field: String
    /// The field's label or placeholder, to say which one it was.
    var label: String
    var text: String
    var date = Date()
}

@Observable
final class Drafts {
    static let shared = Drafts()
    static let keepDays = 7.0

    private(set) var items: [Draft] = []
    @ObservationIgnored private let file = StoredFile<[Draft]>("drafts.json")

    private init() {
        let cutoff = Date().addingTimeInterval(-Self.keepDays * 86_400)
        items = (file.load() ?? []).filter { $0.date > cutoff }
    }

    func on(_ url: URL?) -> [Draft] {
        guard let url else { return [] }
        let key = Highlight.pageKey(url)
        return items.filter { $0.page == key }
    }

    func keep(page: URL, field: String, label: String, text: String) {
        let d = Draft(page: Highlight.pageKey(page), field: field, label: label, text: text)
        items.removeAll { $0.id == d.id }
        items.insert(d, at: 0)
        if items.count > 60 { items.removeLast(items.count - 60) }
        persist()
    }

    func forget(page: URL, field: String) {
        let key = Highlight.pageKey(page)
        let before = items.count
        items.removeAll { $0.page == key && $0.field == field }
        if items.count != before { persist() }
    }

    func forget(_ ids: Set<String>) {
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    func clear() {
        items = []
        persist()
    }

    private func persist() { file.save(items, delay: 0.5) }
}
