import Foundation

/// The Public Suffix List, to tell where a site's own name starts: "alice.github.io" is its own site, not part of github.io.
enum PublicSuffix {
    struct Rules {
        var plain = Set<String>()
        var wildcard = Set<String>()
        var exception = Set<String>()
    }

    /// The copy downloaded by `refreshIfStale`, newer than the one inside the app.
    static var downloaded: URL { Paths.support.appendingPathComponent("public_suffix_list.txt") }

    private static let rules: Rules? = {
        let bundled = Bundle.main.url(forResource: "public_suffix_list", withExtension: "txt")
        for url in [downloaded, bundled].compactMap({ $0 }) {
            if let text = try? String(contentsOf: url, encoding: .utf8), let r = parse(text) { return r }
        }
        return nil
    }()

    /// Reads the list as publicsuffix.org publishes it (comments, blank lines and all), or nil if it doesn't look like one.
    static func parse(_ text: String) -> Rules? {
        var r = Rules()
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("!") { r.exception.insert(String(line.dropFirst())) }
            else if line.hasPrefix("*.") { r.wildcard.insert(String(line.dropFirst(2))) }
            else { r.plain.insert(line) }
        }
        // A real list has thousands of rules, including the obvious ones.
        guard r.plain.count > 5_000, r.plain.contains("com"), r.plain.contains("co.uk") else { return nil }
        return r
    }

    /// New domains and hosting services appear all the time, so the list is fetched again once a week.
    /// It's used from the next launch, so sites don't regroup while you browse.
    static func refreshIfStale() {
        let file = downloaded
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) < 7 * 86_400 { return }
        guard let source = URL(string: "https://publicsuffix.org/list/public_suffix_list.dat") else { return }
        var request = URLRequest(url: source)
        request.timeoutInterval = 30
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8), parse(text) != nil else { return }
            try? data.write(to: file, options: .atomic)
        }.resume()
    }

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
