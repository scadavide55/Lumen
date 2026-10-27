import Foundation
import WebKit

// MARK: - Tracking parameter removal

enum URLCleaner {
    static let params: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "vero_conv", "_openstat", "wickedid", "rb_clickid",
        "s_cid", "ef_id", "srsltid", "epik", "ncid", "sr_share", "spm", "scm", "trk", "trkCampaign",
        "ga_source", "ga_medium", "ga_campaign", "ga_content", "ga_term", "_ga", "_gl", "obOrigUrl",
        "li_fat_id", "irclickid", "mc_tc", "_kx", "ml_subscriber", "ml_subscriber_hash", "wt_mc", "wt_zmc",
        "cmpid", "zanpid", "dm_i", "tt_medium", "tt_content", "fb_source", "fb_ref", "action_object_map",
        "action_type_map", "action_ref_map", "_bta_tid", "_bta_c",
        "sms_click", "sms_source", "sms_uph", "ttd_id", "vgo_ee", "_ke", "redirect_log_mongo_id", "redirect_mongo_id",
    ]
    static let prefixes = ["utm_", "mtm_", "pk_", "hsa_", "piwik_", "matomo_", "fb_action_", "_branch_", "itm_", "stm_"]
    /// Parameters that only track on specific sites.
    static let hostParams: [String: Set<String>] = [
        "google.com": ["gs_l", "oq", "ved", "ei", "sca_esv", "sxsrf", "gs_lcrp", "sclient", "uact"],
        "youtube.com": ["si", "pp", "feature"],
        "youtu.be": ["si", "feature"],
        "open.spotify.com": ["si", "context"],
        "twitter.com": ["s", "t", "ref_src", "ref_url"],
        "x.com": ["s", "t", "ref_src", "ref_url"],
        "amazon.com": ["ref", "ref_", "pf_rd_r", "pf_rd_p", "pd_rd_r", "pd_rd_w", "pd_rd_wg", "content-id"],
        "instagram.com": ["igsh", "img_index"],
        "linkedin.com": ["trk", "trackingId", "lipi", "refId"],
    ]

    /// Link wrappers that only exist to log the click before sending you on: host suffix, path prefix, parameter.
    static let redirectors: [(host: String, path: String, param: String)] = [
        ("google.com", "/url", "q"), ("google.com", "/url", "url"), ("google.it", "/url", "q"),
        ("google.fr", "/url", "q"), ("google.co.uk", "/url", "q"), ("google.de", "/url", "q"),
        ("l.facebook.com", "/l.php", "u"), ("lm.facebook.com", "/l.php", "u"), ("l.messenger.com", "/l.php", "u"),
        ("l.instagram.com", "/", "u"), ("youtube.com", "/redirect", "q"), ("out.reddit.com", "/", "url"),
        ("steamcommunity.com", "/linkfilter", "url"), ("away.vk.com", "/away.php", "to"),
        ("click.linksynergy.com", "/", "murl"), ("t.umblr.com", "/redirect", "z"), ("disq.us", "/url", "url"),
        ("bing.com", "/ck/a", "u"), ("duckduckgo.com", "/l", "uddg"),
    ]

    /// The destination of a known click-tracking redirect, without tracking parameters, or nil.
    static func unwrap(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for r in redirectors where (host == r.host || host.hasSuffix("." + r.host)) && url.path.hasPrefix(r.path) {
            guard var value = items.first(where: { $0.name == r.param })?.value else { continue }
            // Bing encodes the target as "a1" + base64.
            if r.host == "bing.com", value.hasPrefix("a1") {
                var b64 = String(value.dropFirst(2)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
                guard let d = Data(base64Encoded: b64), let decoded = String(data: d, encoding: .utf8) else { continue }
                value = decoded
            }
            guard let target = URL(string: value), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
                  target.host != nil else { continue }
            return clean(target) ?? target
        }
        return nil
    }

    /// Returns the URL without tracking parameters, or nil when nothing changed.
    static func clean(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.queryItems, !items.isEmpty else { return nil }
        let host = (url.host ?? "").lowercased()
        let extra = hostParams.first { host == $0.key || host.hasSuffix("." + $0.key) }?.value ?? []
        let kept = items.filter { item in
            let n = item.name.lowercased()
            if params.contains(item.name) || params.contains(n) || extra.contains(item.name) { return false }
            return !prefixes.contains { n.hasPrefix($0) }
        }
        guard kept.count != items.count else { return nil }
        c.queryItems = kept.isEmpty ? nil : kept
        return c.url
    }
}

// MARK: - Address bar input

enum InputResolver {
    /// Turns what the user typed into a URL: an address, a search shortcut, or a search.
    static func resolve(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        if let u = URL(string: s), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file", "about", "data", "blob", "view-source"].contains(scheme) {
            return u
        }
        if s.hasPrefix("/") || s.hasPrefix("~/") {
            let path = (s as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }

        // Search shortcuts: "yt lofi" searches YouTube.
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2, let sc = Settings.shared.shortcuts.first(where: { $0.keyword.lowercased() == parts[0].lowercased() }) {
            return fill(sc.template, parts[1])
        }

        if !s.contains(" "), let u = addressURL(s) { return u }
        return searchURL(s)
    }

    static func searchURL(_ query: String) -> URL? {
        fill(Settings.shared.engine.template, query) ?? fill(SearchEngine.duckduckgo.template, query)
    }

    static func fill(_ template: String, _ query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: q))
    }

    /// Recognises "example.com", "localhost:3000/x", "192.168.1.1" and similar.
    static func addressURL(_ s: String) -> URL? {
        let hostPart = s.split(whereSeparator: { "/?#".contains($0) }).first.map(String.init) ?? s
        let host = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let isLocal = host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test")
        let isIP = host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
        if isLocal || isIP { return URL(string: "http://" + s) }
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) || tld.hasPrefix("xn--"),
              labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        return URL(string: "https://" + s)
    }

    /// Whether the host is written with letters from other alphabets (punycode, "xn--"),
    /// which can be made to look like a familiar site's name.
    static func isInternational(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host.split(separator: ".").contains { $0.hasPrefix("xn--") }
    }

    /// Host for display: "www.apple.com" shows as "apple.com".
    static func displayHost(_ url: URL?) -> String {
        guard let host = url?.host else { return url?.absoluteString ?? "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

// MARK: - HTTPS upgrade

enum HTTPSUpgrade {
    /// Hosts that failed over HTTPS during this run, so they are loaded over HTTP.
    static var httpOnly: Set<String> = []
    /// Hosts the user chose to open over HTTP despite HTTPS-only mode.
    static var userAllowed: Set<String> = []

    static func eligible(_ url: URL) -> Bool {
        guard url.scheme == "http", let host = url.host?.lowercased() else { return false }
        if httpOnly.contains(host) { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test") { return false }
        if host.split(separator: ".").allSatisfy({ Int($0) != nil }) || host.contains(":") { return false }
        return true
    }

    static func upgraded(_ url: URL) -> URL? {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "https"
        if c.port == 80 { c.port = nil }
        return c.url
    }

    /// Errors that mean the host does not really speak HTTPS.
    static func shouldFallBack(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
                NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
                NSURLErrorTimedOut, NSURLErrorBadServerResponse].contains(error.code)
    }
}

// MARK: - Clearing data

enum DataCleaner {
    enum Range: String, CaseIterable, Identifiable {
        case hour, day, week, all
        var id: String { rawValue }
        var label: String { L(["hour": "Last hour", "day": "Today", "week": "Last 7 days", "all": "All time"][rawValue]!) }
        var since: Date {
            switch self {
            case .hour: Date().addingTimeInterval(-3600)
            case .day: Calendar.current.startOfDay(for: Date())
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .all: .distantPast
            }
        }
    }

    static func clear(range: Range, history: Bool, cookies: Bool, cache: Bool, done: @escaping () -> Void) {
        if history {
            History.shared.clear(since: range == .all ? nil : range.since)
            AssistantHistory.shared.clear(since: range == .all ? nil : range.since)
        }
        var types = Set<String>()
        let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                       WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]
        if cache { types.formUnion(cacheTypes) }
        if cookies { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes)) }
        if cache && range == .all { Favicons.shared.clearDisk() }
        guard !types.isEmpty else { done(); return }
        // Every profile's data goes too.
        let stores = [WKWebsiteDataStore.default()] + Settings.shared.profiles.map { WKWebsiteDataStore(forIdentifier: $0.id) }
        let group = DispatchGroup()
        for store in stores {
            group.enter()
            store.removeData(ofTypes: types, modifiedSince: range.since) { group.leave() }
        }
        group.notify(queue: .main, execute: done)
    }

    /// Removes cookies and storage belonging to one site.
    static func clearSite(_ host: String, store: WKWebsiteDataStore, done: @escaping () -> Void) {
        let base = host.lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored)
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matching = records.filter { base == $0.displayName || base.hasSuffix("." + $0.displayName) || $0.displayName.hasSuffix("." + base) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching, completionHandler: done)
        }
    }
}
