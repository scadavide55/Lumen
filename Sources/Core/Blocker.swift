import WebKit

extension Notification.Name {
    /// Posted when the set of rule lists a tab should use may have changed.
    static let blockerChanged = Notification.Name("lumen.blockerChanged")
}

/// Owns every compiled WebKit rule list: the built-in list, the third-party cookie
/// list, and optional EasyList / EasyPrivacy lists downloaded and converted at runtime.
final class ContentBlocker: ObservableObject {
    static let shared = ContentBlocker()

    @Published private(set) var builtInCount = 0
    @Published private(set) var filterCount = 0
    @Published private(set) var updating = false
    @Published private(set) var status = ""
    @Published private(set) var lastUpdated: Date?

    private(set) var isReady = false
    private var readyCallbacks: [() -> Void] = []
    private var builtIn: WKContentRuleList?
    private var cookies: WKContentRuleList?
    private var filters: [WKContentRuleList] = []
    private let store = WKContentRuleListStore.default()!
    private let defaults = UserDefaults.standard

    static let sources: [(key: String, url: URL)] = [
        ("easyList", URL(string: "https://easylist.to/easylist/easylist.txt")!),
        ("easyPrivacy", URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]

    var ruleCount: Int { (Settings.shared.adBlock ? builtInCount + filterCount : 0) }

    func start() {
        builtInCount = BuiltInRules.count
        filterCount = defaults.integer(forKey: "lumen.filterCount")
        lastUpdated = defaults.object(forKey: "lumen.filterDate") as? Date
        let ids = defaults.stringArray(forKey: "lumen.filterIDs") ?? []

        let group = DispatchGroup()
        let json = BuiltInRules.json()
        group.enter()
        compileOrLookUp("lumen-builtin-" + Self.hash(json), json, stalePrefix: "lumen-builtin-") {
            self.builtIn = $0
            group.leave()
        }
        group.enter()
        compileOrLookUp("lumen-cookies-1", BuiltInRules.cookieJSON, stalePrefix: "lumen-cookies-") {
            self.cookies = $0
            group.leave()
        }
        var found: [String: WKContentRuleList] = [:]
        for id in ids {
            group.enter()
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in
                if let list { found[id] = list }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.filters = ids.compactMap { found[$0] }
            if self.filters.count != ids.count { self.filterCount = 0; self.filters = [] }
            self.markReady()
            self.updateIfStale()
        }
        // Never hold page loads hostage to the rule store.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.markReady() }

        NotificationCenter.default.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? String else { return }
            switch key {
            case "easyList", "easyPrivacy": self.updateFilterLists()
            case "adBlock", "thirdPartyCookies", "allowlist":
                self.objectWillChange.send()
                NotificationCenter.default.post(name: .blockerChanged, object: nil)
            default: break
            }
        }
    }

    func whenReady(_ f: @escaping () -> Void) {
        if isReady { f() } else { readyCallbacks.append(f) }
    }

    /// Rule lists a page on `host` should load with.
    func lists(for host: String?) -> [WKContentRuleList] {
        let s = Settings.shared
        guard !s.isAllowlisted(host) else { return [] }
        var out: [WKContentRuleList] = []
        if s.adBlock {
            if let builtIn { out.append(builtIn) }
            out += filters
        }
        if s.blockThirdPartyCookies, let cookies { out.append(cookies) }
        return out
    }

    // MARK: Filter lists

    func updateIfStale() {
        let s = Settings.shared
        guard s.easyList || s.easyPrivacy else { return }
        let age = lastUpdated.map { Date().timeIntervalSince($0) } ?? .infinity
        if filters.isEmpty || age > 7 * 86_400 { updateFilterLists() }
    }

    func updateFilterLists() {
        let enabled = Self.sources.filter { src in
            src.key == "easyList" ? Settings.shared.easyList : Settings.shared.easyPrivacy
        }
        guard !enabled.isEmpty else { removeFilters(); return }
        guard !updating else { return }
        updating = true
        status = L("Downloading filter lists…")

        let group = DispatchGroup()
        var texts = [String?](repeating: nil, count: enabled.count)
        for (i, src) in enabled.enumerated() {
            group.enter()
            var request = URLRequest(url: src.url)
            request.timeoutInterval = 30
            URLSession.shared.dataTask(with: request) { data, response, _ in
                DispatchQueue.main.async {
                    if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                        texts[i] = String(decoding: data, as: UTF8.self)
                    }
                    group.leave()
                }
            }.resume()
        }
        group.notify(queue: .main) {
            let downloaded = texts.compactMap { $0 }
            guard downloaded.count == texts.count else {
                self.updating = false
                self.status = L("Couldn't download the filter lists. Check your connection.")
                return
            }
            self.status = L("Converting rules…")
            DispatchQueue.global(qos: .utility).async {
                let out = FilterConverter.convert(downloaded.joined(separator: "\n"))
                let chunks = Self.chunks(out)
                DispatchQueue.main.async { self.compileFilters(chunks, total: out.block.count + out.hide.count) }
            }
        }
    }

    private func compileFilters(_ chunks: [[[String: Any]]], total: Int) {
        status = String(format: L("Compiling %@ rules…"), total.formatted())
        let stamp = Int(Date().timeIntervalSince1970)
        var lists: [WKContentRuleList] = []
        var compiled = 0

        func next(_ i: Int) {
            guard i < chunks.count else {
                finish(lists, count: compiled)
                return
            }
            compileResilient(chunks[i], id: "lumen-filter-\(stamp)-\(i)") { l, n in
                lists += l
                compiled += n
                next(i + 1)
            }
        }
        next(0)
    }

    private func finish(_ lists: [WKContentRuleList], count: Int) {
        let old = filters.map(\.identifier)
        filters = lists
        filterCount = count
        lastUpdated = Date()
        updating = false
        status = lists.isEmpty ? L("No rules could be compiled.") : ""
        defaults.set(lists.map(\.identifier), forKey: "lumen.filterIDs")
        defaults.set(count, forKey: "lumen.filterCount")
        defaults.set(lastUpdated, forKey: "lumen.filterDate")
        for id in old where !lists.contains(where: { $0.identifier == id }) {
            store.removeContentRuleList(forIdentifier: id) { _ in }
        }
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    private func removeFilters() {
        for l in filters { store.removeContentRuleList(forIdentifier: l.identifier) { _ in } }
        filters = []
        filterCount = 0
        lastUpdated = nil
        status = ""
        defaults.removeObject(forKey: "lumen.filterIDs")
        defaults.removeObject(forKey: "lumen.filterCount")
        defaults.removeObject(forKey: "lumen.filterDate")
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    /// Splits converted rules under WebKit's per-list limit. Exceptions only affect
    /// rules earlier in the same list, so each network chunk ends with all of them.
    static func chunks(_ out: FilterConverter.Output, size: Int = 45_000) -> [[[String: Any]]] {
        var result: [[[String: Any]]] = []
        var i = 0
        while i < out.block.count {
            result.append(Array(out.block[i..<min(i + size, out.block.count)]) + out.allow)
            i += size
        }
        i = 0
        while i < out.hide.count {
            result.append(Array(out.hide[i..<min(i + size, out.hide.count)]))
            i += size
        }
        return result
    }

    /// Compiles a list; if WebKit rejects it, splits it in half until the bad rules are isolated and dropped.
    private func compileResilient(_ rules: [[String: Any]], id: String, done: @escaping ([WKContentRuleList], Int) -> Void) {
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules) else {
            done([], 0)
            return
        }
        store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: String(decoding: data, as: UTF8.self)) { list, _ in
            if let list { done([list], rules.count); return }
            guard rules.count > 1 else { done([], 0); return }
            let mid = rules.count / 2
            self.compileResilient(Array(rules[..<mid]), id: id + "a") { l1, c1 in
                self.compileResilient(Array(rules[mid...]), id: id + "b") { l2, c2 in done(l1 + l2, c1 + c2) }
            }
        }
    }

    // MARK: Helpers

    private func markReady() {
        guard !isReady else { return }
        isReady = true
        let callbacks = readyCallbacks
        readyCallbacks = []
        callbacks.forEach { $0() }
        NotificationCenter.default.post(name: .blockerChanged, object: nil)
    }

    private func compileOrLookUp(_ id: String, _ json: String, stalePrefix: String, done: @escaping (WKContentRuleList?) -> Void) {
        store.lookUpContentRuleList(forIdentifier: id) { list, _ in
            if let list { done(list); return }
            self.store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Lumen: rule list \(id) failed: \(error)") }
                done(list)
            }
            self.store.getAvailableContentRuleListIdentifiers { ids in
                for old in ids ?? [] where old.hasPrefix(stalePrefix) && old != id {
                    self.store.removeContentRuleList(forIdentifier: old) { _ in }
                }
            }
        }
    }

    static func hash(_ s: String) -> String {
        var h: UInt64 = 5381
        for b in s.utf8 { h = (h &* 33) ^ UInt64(b) }
        return String(h, radix: 36)
    }
}
