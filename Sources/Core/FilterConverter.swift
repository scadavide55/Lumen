import Foundation

/// Converts Adblock Plus / EasyList syntax into WebKit content rules.
///
/// WebKit's url-filter is a restricted regex: ASCII only, no `|` disjunction, no `{n}`
/// repetition, and a trigger may carry only one of if-domain / unless-domain. Rules that
/// cannot be expressed exactly are dropped rather than approximated loosely.
enum FilterConverter {
    struct Output {
        var block: [[String: Any]] = []
        var allow: [[String: Any]] = []
        var hide: [[String: Any]] = []
        var skipped = 0
    }

    static func convert(_ text: String) -> Output {
        var out = Output()
        var seenSelectors = Set<String>()
        var seenFilters = Set<String>()
        text.enumerateLines { raw, _ in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { return }
            if line.contains("#@#") || line.contains("#?#") || line.contains("#$#") || line.contains("#%#")
                || line.contains("$$") || line.contains("#@?#") {
                out.skipped += 1
                return
            }
            if let r = line.range(of: "##") {
                let domains = String(line[..<r.lowerBound])
                let selector = String(line[r.upperBound...])
                if domains.isEmpty {
                    guard !seenSelectors.contains(selector) else { return }
                    seenSelectors.insert(selector)
                }
                if let rule = cosmetic(domains: domains, selector: selector) { out.hide.append(rule) } else { out.skipped += 1 }
                return
            }
            guard !seenFilters.contains(line) else { return }
            seenFilters.insert(line)
            guard let (rule, isException) = network(line) else { out.skipped += 1; return }
            if isException { out.allow.append(rule) } else { out.block.append(rule) }
        }
        return out
    }

    // MARK: Element hiding

    static let unsupportedSelectorParts = [
        ":-abp-", ":has-text", ":contains(", ":xpath", ":style(", ":matches-css", ":upward", ":remove(",
        ":watch-attr", ":min-text-length", ":matches-path", ":others(", "[-ext-", ":if(", ":if-not(",
        ":nth-ancestor", ":matches-attr", ":matches-prop", ":matches-media", ":remove-attr", ":remove-class",
    ]

    static func cosmetic(domains: String, selector raw: String) -> [String: Any]? {
        let selector = raw.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII),
              !selector.contains("{"), !selector.contains("}"),
              !unsupportedSelectorParts.contains(where: selector.contains) else { return nil }
        var trigger: [String: Any] = ["url-filter": ".*"]
        if !domains.isEmpty {
            guard let (key, list) = domainCondition(domains.split(separator: ",").map(String.init)) else { return nil }
            trigger[key] = list
        }
        return ["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]]
    }

    // MARK: Network rules

    static func network(_ line: String) -> (rule: [String: Any], isException: Bool)? {
        var pattern = Substring(line)
        var isException = false
        if pattern.hasPrefix("@@") {
            isException = true
            pattern = pattern.dropFirst(2)
        }
        // Regex rules ("/ads[0-9]+/") cannot be translated reliably.
        if pattern.hasPrefix("/"), pattern.count > 2 {
            let body = pattern.split(separator: "$", maxSplits: 1).first ?? pattern
            if body.hasSuffix("/") { return nil }
        }

        var options: [Substring] = []
        if let dollar = pattern.lastIndex(of: "$") {
            options = pattern[pattern.index(after: dollar)...].split(separator: ",")
            pattern = pattern[..<dollar]
        }

        var trigger: [String: Any] = [:]
        var types = Set<String>()
        var loadType: String?
        for opt in options {
            let negated = opt.hasPrefix("~")
            let name = negated ? opt.dropFirst() : opt
            if name.hasPrefix("domain=") {
                let list = name.dropFirst("domain=".count).split(separator: "|").map(String.init)
                guard let (key, domains) = domainCondition(list) else { return nil }
                trigger[key] = domains
                continue
            }
            switch name {
            case "third-party", "3p":
                loadType = negated ? "first-party" : "third-party"
            case "first-party", "1p":
                loadType = negated ? "third-party" : "first-party"
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important", "all":
                continue
            default:
                guard !negated, let type = resourceType(name) else { return nil }
                if type == "document" && isException { return nil } // page-level allowlisting
                types.insert(type)
            }
        }

        guard let filter = urlFilter(pattern) else { return nil }
        trigger["url-filter"] = filter
        if !types.isEmpty { trigger["resource-type"] = types.sorted() }
        if let loadType { trigger["load-type"] = [loadType] }
        let action = isException ? "ignore-previous-rules" : "block"
        return (["trigger": trigger, "action": ["type": action]], isException)
    }

    static func resourceType(_ option: Substring) -> String? {
        switch option {
        case "script": "script"
        case "image": "image"
        case "stylesheet", "css": "style-sheet"
        case "font": "font"
        case "media": "media"
        case "subdocument", "frame": "document"
        case "document", "doc": "document"
        case "popup": "popup"
        case "xmlhttprequest", "xhr", "websocket", "ping", "other", "object", "object-subrequest", "beacon": "raw"
        default: nil
        }
    }

    /// One WebKit domain condition. Mixed include/exclude lists are not expressible.
    static func domainCondition(_ list: [String]) -> (String, [String])? {
        var include: [String] = []
        var exclude: [String] = []
        for raw in list {
            var d = raw.trimmingCharacters(in: .whitespaces).lowercased()
            let negated = d.hasPrefix("~")
            if negated { d.removeFirst() }
            guard !d.isEmpty, d.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
            if negated { exclude.append("*" + d) } else { include.append("*" + d) }
        }
        if !include.isEmpty && !exclude.isEmpty { return nil }
        if !include.isEmpty { return ("if-domain", include) }
        if !exclude.isEmpty { return ("unless-domain", exclude) }
        return nil
    }

    /// ABP pattern to WebKit regex.
    static func urlFilter(_ raw: Substring) -> String? {
        var p = raw
        guard p.allSatisfy({ $0.isASCII && $0 != " " }) else { return nil }
        var prefix = ""
        var suffix = ""
        var domainAnchor = false
        if p.hasPrefix("||") {
            p = p.dropFirst(2)
            prefix = "^[^:]+://+([^:/]+\\.)?"
            domainAnchor = true
        } else if p.hasPrefix("|") {
            p = p.dropFirst()
            prefix = "^"
        }
        if p.hasSuffix("|") {
            p = p.dropLast()
            suffix = "$"
        }
        while p.hasPrefix("*") {
            p = p.dropFirst()
            if !domainAnchor { prefix = "" }
        }
        while p.hasSuffix("*") {
            p = p.dropLast()
            suffix = ""
        }
        // Very short patterns ("ad", "-") would match half the web.
        let meaningful = p.filter { $0.isLetter || $0.isNumber }
        guard meaningful.count >= 3 || (domainAnchor && meaningful.count >= 2) else { return nil }

        var out = prefix
        let chars = Array(p)
        for (i, c) in chars.enumerated() {
            switch c {
            case "*":
                if !out.hasSuffix(".*") { out += ".*" }
            case "^":
                if i == chars.count - 1 {
                    // A trailing separator after a bare domain is always followed by "/" or ":port".
                    let rest = String(chars[..<i])
                    if domainAnchor && !rest.contains("/") { out += "[/:]" }
                } else {
                    out += "[^a-zA-Z0-9_.%-]"
                }
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|":
                out += "\\" + String(c)
            default:
                out.append(c)
            }
        }
        return out + suffix
    }
}
