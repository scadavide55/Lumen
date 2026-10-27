import Foundation

/// The Public Suffix List, to tell where a site's own name starts: "alice.github.io" is its own site, not part of github.io.
enum PublicSuffix {
    private struct Rules {
        var plain = Set<String>()
        var wildcard = Set<String>()
        var exception = Set<String>()
    }

    private static let rules: Rules? = {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var r = Rules()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("!") { r.exception.insert(String(line.dropFirst())) }
            else if line.hasPrefix("*.") { r.wildcard.insert(String(line.dropFirst(2))) }
            else { r.plain.insert(String(line)) }
        }
        return r
    }()

    /// The registrable domain: "www.bbc.co.uk" → "bbc.co.uk", "alice.github.io" → "alice.github.io".
    /// A host that is a suffix itself, an address or a single name comes back unchanged.
    static func registrable(_ host: String) -> String {
        let host = host.lowercased()
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 1, host.contains(where: { !$0.isNumber && $0 != "." }) else { return host }
        let suffix = suffixLength(labels)
        guard labels.count > suffix else { return host }
        return labels.suffix(suffix + 1).joined(separator: ".")
    }

    /// How many trailing labels are the public suffix.
    private static func suffixLength(_ labels: [String]) -> Int {
        guard let rules else { return min(2, labels.count - 1) }
        var best = 1
        for i in 0..<labels.count {
            let candidate = labels[i...].joined(separator: ".")
            let count = labels.count - i
            if rules.exception.contains(candidate) { return count - 1 }
            if rules.plain.contains(candidate) { best = max(best, count) }
            if i + 1 < labels.count, rules.wildcard.contains(labels[(i + 1)...].joined(separator: ".")) { best = max(best, count) }
        }
        return best
    }
}
