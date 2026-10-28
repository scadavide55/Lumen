import Foundation

/// Tacet's own manual, which Tacet Assistant reads with the tacet_guide tool to answer questions about the browser:
/// where something is, shortcuts, settings, versions, the rename from Lumen, who made it.
enum TacetGuide {
    struct Section {
        let title: String
        let body: String
    }

    static let sections: [Section] = {
        let url = Bundle.main.url(forResource: "TacetGuide", withExtension: "md")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return text.components(separatedBy: "\n## ").dropFirst().map { chunk in
            let lines = chunk.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return Section(title: String(lines.first ?? ""), body: lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : "")
        }
    }()

    /// The sections that answer `query` best, with the version running now; with no query, the list of sections.
    static func lookup(_ query: String, limit: Int = 9_000) -> String {
        let header = "Tacet version running now: \(UpdateChecker.currentVersion)\n"
        let words = query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        guard !words.isEmpty else {
            return header + "Sections of the Tacet Guide (call tacet_guide again with a query to read them):\n"
                + sections.map { "- " + $0.title }.joined(separator: "\n")
        }
        let ranked = sections.map { s -> (Section, Int) in
            let title = s.title.lowercased(), body = s.body.lowercased()
            let score = words.reduce(0) { n, w in n + (title.contains(w) ? 6 : 0) + body.components(separatedBy: w).count - 1 }
            return (s, score)
        }
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        var out = header
        for (s, _) in ranked.prefix(4) {
            let block = "\n## " + s.title + "\n" + s.body + "\n"
            if out.count + block.count > limit { break }
            out += block
        }
        if ranked.isEmpty {
            out += "Nothing in the Tacet Guide matches that. Sections: " + sections.map(\.title).joined(separator: "; ")
        }
        return out
    }
}
