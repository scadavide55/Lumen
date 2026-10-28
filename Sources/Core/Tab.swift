import SwiftUI
import WebKit

/// One browser tab. The web view is created lazily and released when the tab
/// hibernates, keeping its back/forward history in `restoreState`.
@Observable
final class Tab: NSObject, Identifiable {
    let id = UUID()
    @ObservationIgnored weak var browser: BrowserState?

    var title: String
    var url: URL?
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var favicon: NSImage?
    var isPinned: Bool
    var groupID: UUID?
    var isPlayingAudio = false
    var isMuted = false
    var hoverURL: String?
    var isReader = false
    var isSecure = false
    var themeColor: NSColor?
    var zoom = 1.0
    var failedURL: URL?
    private(set) var webView: LumenWebView?
    var loginMenu: LoginMenu?
    var pendingSave: PendingLogin?
    var insecureWarning = false
    /// Picking elements on the page to hide.
    var pickingElements = false
    @ObservationIgnored var lastActive = Date()
    /// What the page looked like when it went to sleep, shown over it while it wakes up so there's no white flash.
    var sleepImage: NSImage?
    /// The page as it looked when you last left the tab, as JPEG, and where it was scrolled to.
    @ObservationIgnored private var lastLook: (jpeg: Data, scroll: CGPoint)?
    @ObservationIgnored private var waking = false
    /// Page translation: in progress, done (from which language), or why it couldn't be.
    var translating = false
    var translatedFrom: String?
    var translationError: String?
    var readingAloud = false
    /// What Tacet Shield blocked on the page shown now, by site, and how many times.
    var blockedHere: [String: Int] = [:]

    /// The picture of the page from when you last left it, for the preview shown when hovering over the tab.
    var previewImage: NSImage? { isSelected ? nil : lastLook.flatMap { NSImage(data: $0.jpeg) } }

    @ObservationIgnored private var restoreState: Data?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var observers: [NSKeyValueObservation] = []
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var appliedLists: String?
    @ObservationIgnored private var upgrade: (host: String, original: URL, at: Date)?
    @ObservationIgnored private var internalLoad = false
    @ObservationIgnored private var internalNavigation: WKNavigation?
    @ObservationIgnored private var readerOrigin: URL?
    @ObservationIgnored private var faviconHost: String?
    /// Pull to refresh state, kept apart so that only the indicator redraws while you pull.
    let pull = PullToRefresh()
    /// Loading progress, kept apart so that only the progress line redraws while a page loads.
    let load = LoadProgress()
    @ObservationIgnored private var mediaPermissions: [String: Bool] = [:]
    @ObservationIgnored private var rememberedUser: (host: String, name: String, at: Date)?
    @ObservationIgnored private var lastCrash: Date?

    /// Saved accounts shown under a focused sign-in field, in page-view coordinates.
    struct LoginMenu: Equatable {
        let origin: CGPoint
        let width: CGFloat
        let logins: [SavedLogin]
        /// A generated password to offer, on sign-up and change-password fields.
        var strongPassword: String?
    }

    struct PendingLogin: Equatable {
        let host: String
        let username: String
        let password: String
        let isUpdate: Bool
    }

    private static let owners = NSMapTable<WKWebView, Tab>.weakToWeakObjects()
    static func owner(of webView: WKWebView) -> Tab? { owners.object(forKey: webView) }

    static let zoomSteps = [0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    var isHibernated: Bool { webView == nil }
    var isSelected: Bool { browser?.selectedID == id || browser?.splitID == id }
    var isPrivate: Bool { browser?.isPrivate ?? false }
    var host: String? { url?.host?.lowercased() }
    var shieldsUp: Bool { Settings.shared.adBlock && !Settings.shared.isAllowlisted(host) }
    var isStartPage: Bool { url == nil && failedURL == nil && !isLoading }

    init(browser: BrowserState, url: URL? = nil, title: String? = nil, state: Data? = nil, pinned: Bool = false) {
        self.browser = browser
        self.url = url
        self.title = title ?? (url.map { InputResolver.displayHost($0) } ?? L("New Tab"))
        self.isPinned = pinned
        pendingURL = url
        restoreState = state
        super.init()
        favicon = Favicons.shared.cached(url?.host)
        observeNotifications()
    }

    /// A tab for a popup WebKit asked us to create; WebKit loads it itself.
    init(browser: BrowserState, configuration: WKWebViewConfiguration) {
        self.browser = browser
        title = L("New Tab")
        isPinned = false
        super.init()
        attach(LumenWebView(frame: .zero, configuration: configuration))
        observeNotifications()
    }

    deinit {
        tokens.forEach(NotificationCenter.default.removeObserver)
    }

    static func configuration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.applicationNameForUserAgent = UserAgent.applicationName
        c.preferences.isElementFullscreenEnabled = true
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.allowsAirPlayForMediaPlayback = true
        c.mediaTypesRequiringUserActionForPlayback = Settings.shared.blockAutoplay ? .audio : []
        c.defaultWebpagePreferences.allowsContentJavaScript = Settings.shared.javaScript
        Scripts.install(on: c.userContentController)
        // Extensions run in normal windows and profiles, never in private windows.
        if #available(macOS 15.4, *), store.isPersistent {
            c.webExtensionController = Extensions.shared.controller
        }
        return c
    }

    // MARK: Web view lifecycle

    func ensureWebView() {
        guard webView == nil, let browser else { return }
        // An extension's own page (its settings, say) needs a web view made for that extension.
        if let target = pendingURL ?? url, target.scheme == "webkit-extension", let config = Extensions.webViewConfiguration(for: target) {
            attach(LumenWebView(frame: .zero, configuration: config))
            pendingURL = nil
            restoreState = nil
            load(target)
            return
        }
        // A tab restoring its history needs a web view that has never loaded anything; a fresh tab can take the spare.
        let spare = restoreState == nil ? browser.takeSpareWebView() : nil
        let wv = spare ?? LumenWebView(frame: .zero, configuration: Tab.configuration(store: browser.dataStore))
        attach(wv)
        let state = restoreState
        let target = pendingURL
        restoreState = nil
        pendingURL = nil
        if state != nil, let look = lastLook, let image = NSImage(data: look.jpeg) {
            sleepImage = image
            waking = true
            // A page that never finishes loading isn't hidden for long.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishWaking(restoreScroll: false) }
        }
        ContentBlocker.shared.whenReady { [weak self, weak wv] in
            guard let self, let wv, self.webView === wv else { return }
            self.applyBlocking(for: target ?? self.url)
            if let state {
                wv.interactionState = state
            } else if let target {
                self.load(target)
            }
        }
    }

    private func attach(_ wv: LumenWebView) {
        wv.tab = self
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.allowsMagnification = true
        wv.isInspectable = Settings.shared.developer
        wv.customUserAgent = UserAgent.custom
        Tab.owners.setObject(self, forKey: wv)
        observers = [
            // Each assignment redraws every view watching the tab, so only real changes are passed on.
            wv.observe(\.title) { [weak self] w, _ in
                self?.titleChanged(w.title)
                if let self { ExtensionEvents.changed(self, title: true) }
            },
            wv.observe(\.url) { [weak self] w, _ in
                guard let self, let u = w.url, self.url != u else { return }
                self.url = u
                ExtensionEvents.changed(self, url: true)
            },
            wv.observe(\.isLoading) { [weak self] w, _ in
                guard let self, self.isLoading != w.isLoading else { return }
                self.isLoading = w.isLoading
                ExtensionEvents.changed(self, loading: true)
            },
            wv.observe(\.estimatedProgress) { [weak self] w, _ in
                guard let load = self?.load else { return }
                let p = w.estimatedProgress
                // The bar is 2 pt tall: steps under 4% can't be seen, but each one costs a redraw.
                if abs(p - load.value) >= 0.04 || p == 1 || p < load.value { if p != load.value { load.value = p } }
            },
            wv.observe(\.canGoBack) { [weak self] w, _ in if self?.canGoBack != w.canGoBack { self?.canGoBack = w.canGoBack } },
            wv.observe(\.canGoForward) { [weak self] w, _ in if self?.canGoForward != w.canGoForward { self?.canGoForward = w.canGoForward } },
            wv.observe(\.hasOnlySecureContent) { [weak self] w, _ in
                if self?.isSecure != w.hasOnlySecureContent { self?.isSecure = w.hasOnlySecureContent }
            },
            wv.observe(\.themeColor) { [weak self] w, _ in if self?.themeColor != w.themeColor { self?.themeColor = w.themeColor } },
        ]
        webView = wv
    }

    /// Keeps a small picture of the page and its scroll position as the tab goes to the background, for when it wakes.
    func rememberLook() {
        guard let wv = webView, wv.window != nil, url != nil, !isReader, !isPrivate else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: min(1200, Double(wv.bounds.width)))
        wv.takeSnapshot(with: config) { [weak self] image, _ in
            guard let image, let tiff = image.tiffRepresentation,
                  let jpeg = NSBitmapImageRep(data: tiff)?.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { return }
            wv.evaluateJavaScript("[window.scrollX, window.scrollY]", in: nil, in: .defaultClient) { result in
                let xy = (try? result.get()) as? [Double] ?? [0, 0]
                self?.lastLook = (jpeg, CGPoint(x: xy.first ?? 0, y: xy.last ?? 0))
            }
        }
    }

    /// The page has loaded after waking: puts it back where it was scrolled to if it didn't do that itself,
    /// then lets the picture fade.
    private func finishWaking(restoreScroll: Bool) {
        guard waking else { return }
        waking = false
        if restoreScroll, let wv = webView, let y = lastLook?.scroll.y, y > 40 {
            let x = lastLook?.scroll.x ?? 0
            wv.evaluateJavaScript("if (Math.abs(window.scrollY - \(y)) > 40) window.scrollTo(\(x), \(y))", in: nil, in: .defaultClient)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            withAnimation(.easeOut(duration: 0.2)) { self?.sleepImage = nil }
        }
    }

    /// Releases the web view but keeps enough state to restore the page and its history.
    func hibernate() {
        guard let wv = webView else { return }
        restoreState = wv.interactionState as? Data
        pendingURL = url
        tearDown()
    }

    func close() {
        if readingAloud { MainActor.assumeIsolated { ReadAloud.shared.stop() } }
        tearDown()
    }

    private func tearDown() {
        observers = []
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        appliedLists = nil
        isLoading = false
        load.value = 0
        isPlayingAudio = false
        hoverURL = nil
    }

    func snapshot() -> TabSnapshot {
        TabSnapshot(url: url ?? pendingURL, title: title, pinned: isPinned,
                    state: (webView?.interactionState as? Data) ?? restoreState, group: groupID, lastActive: lastActive)
    }

    private func titleChanged(_ raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        title = t.isEmpty ? (url.map { InputResolver.displayHost($0) } ?? L("New Tab")) : t
        if browser?.selectedID == id { browser?.window?.title = title }
        if !isPrivate, !isReader, failedURL == nil, let u = url, !t.isEmpty { History.shared.updateTitle(url: u, title: t) }
    }

    // MARK: Actions

    func load(_ url: URL) {
        guard let wv = webView else {
            pendingURL = url
            self.url = url
            return
        }
        failedURL = nil
        if url.isFileURL {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.load(URLRequest(url: url))
        }
    }

    func load(input: String) {
        if let u = InputResolver.resolve(input) { load(u) }
    }

    func reload() {
        if let f = failedURL { load(f) } else if isReader, let o = readerOrigin { load(o) } else { webView?.reload() }
    }

    func hardReload() { webView?.reloadFromOrigin() }
    func stop() { webView?.stopLoading() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        webView?.evaluateJavaScript("window.__lumenSetMuted && window.__lumenSetMuted(\(muted))", in: nil, in: .defaultClient)
    }

    /// Throws the web view away and makes a new one for the same address, with the right settings for it.
    func remakeWebView() {
        guard let u = url ?? pendingURL else { return }
        tearDown()
        restoreState = nil
        pendingURL = u
        if isSelected { ensureWebView() }
    }

    /// The page Reader shows, while it shows one.
    var readerSource: URL? { isReader ? readerOrigin : nil }

    func toggleReader(completion: ((Bool) -> Void)? = nil) {
        guard let wv = webView else { completion?(false); return }
        if isReader {
            isReader = false
            if let o = readerOrigin { load(o) }
            completion?(false)
            return
        }
        wv.evaluateJavaScript(Scripts.reader, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let value) = result, let d = value as? [String: Any],
                  let html = d["html"] as? String, let origin = wv.url else {
                NSSound.beep()
                completion?(false)
                return
            }
            let words = (d["words"] as? Int) ?? (d["words"] as? Double).map(Int.init) ?? 0
            let page = Scripts.readerPage(title: d["title"] as? String ?? self.title,
                                          site: d["site"] as? String ?? "",
                                          byline: d["byline"] as? String ?? "",
                                          html: html, minutes: max(1, words / 230))
            self.showReader(html: page, origin: origin)
            completion?(true)
        }
    }

    // MARK: Site styles

    /// Applies this site's style to the open page without reloading it.
    func applySiteStyleLive() {
        guard let wv = webView, url != nil, !isReader else { return }
        let style = Settings.shared.siteStyle(for: host).flatMap { $0.enabled ? $0 : nil }
        let args: [String: Any] = ["css": style?.effectiveCSS ?? "", "floating": style?.hideFloating ?? false,
                                   "dark": style?.theme == .dark]
        Task { @MainActor in
            _ = try? await wv.callAsyncJavaScript("if (window.__lumenSiteStyle) window.__lumenSiteStyle(css, floating, dark);",
                                                  arguments: args, in: nil, contentWorld: .defaultClient)
        }
    }

    /// Lets the user click elements on the page to hide them on this site; Esc or `stopPickingElements` ends it.
    func startPickingElements() {
        guard let wv = webView, url != nil, !isReader, !pickingElements else { return }
        pickingElements = true
        let tip = L("Click what you want to hide on this site · ↑ for a bigger block · Esc when you're done")
        let data = (try? JSONSerialization.data(withJSONObject: [tip])).map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        wv.evaluateJavaScript(Scripts.picker.replacingOccurrences(of: "__TIP__", with: data + "[0]"), in: nil, in: .defaultClient)
        wv.window?.makeFirstResponder(wv)
    }

    func stopPickingElements() {
        guard pickingElements else { return }
        pickingElements = false
        webView?.evaluateJavaScript("window.__lumenPicker && window.__lumenPicker.stop()", in: nil, in: .defaultClient)
    }

    /// Shows a Reader page (live or saved offline) in place of `origin`, which Reader's exit goes back to.
    func showReader(html: String, origin: URL) {
        ensureWebView()
        guard let wv = webView else { return }
        readerOrigin = origin
        internalLoad = true
        internalNavigation = wv.loadHTMLString(html, baseURL: origin)
        isReader = true
    }

    func zoom(_ direction: Int) {
        let steps = Tab.zoomSteps
        let next: Double
        if direction == 0 {
            next = Settings.shared.defaultZoom
        } else if direction > 0 {
            next = steps.first { $0 > zoom + 0.001 } ?? steps.last!
        } else {
            next = steps.last { $0 < zoom - 0.001 } ?? steps.first!
        }
        setZoom(next)
    }

    func setZoom(_ z: Double) {
        zoom = z
        webView?.pageZoom = z
        guard !isPrivate, let host else { return }
        var map = Settings.shared.siteZoom
        map[host] = abs(z - Settings.shared.defaultZoom) < 0.01 ? nil : z
        Settings.shared.siteZoom = map
    }

    func find(_ text: String, backwards: Bool, done: @escaping (Bool) -> Void) {
        guard let wv = webView, !text.isEmpty else { done(true); return }
        let c = WKFindConfiguration()
        c.backwards = backwards
        c.caseSensitive = false
        c.wraps = true
        wv.find(text, configuration: c) { done($0.matchFound) }
    }

    func printPage() {
        guard let wv = webView, let window = wv.window else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = true
        let op = wv.printOperation(with: info)
        op.view?.frame = wv.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Saves the whole page as a PDF.
    func exportPDF() {
        guard let wv = webView, let window = wv.window else { return }
        wv.createPDF { result in
            guard case .success(let data) = result else { NSSound.beep(); return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = Self.fileName(self.title) + ".pdf"
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? data.write(to: url)
            }
        }
    }

    /// Saves what's visible on the page as a PNG where you choose, and copies it to the clipboard.
    func screenshot() {
        guard let wv = webView, let window = wv.window else { return }
        wv.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "\(Self.fileName(self.title)) \(stamp).png"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                try? png.write(to: url)
            }
        }
    }

    private static func fileName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Tacet" : String(cleaned.prefix(80))
    }

    var certificateSummary: String? {
        guard let trust = webView?.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let subject = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
        let issuer = chain.count > 1 ? ((SecCertificateCopySubjectSummary(chain[1]) as String?) ?? "") : ""
        return issuer.isEmpty ? subject : "\(subject), issued by \(issuer)"
    }

    // MARK: Blocking

    func applyBlocking(for url: URL?) {
        guard let c = webView?.configuration.userContentController else { return }
        let lists = ContentBlocker.shared.lists(for: url?.host)
        let key = lists.map(\.identifier).joined(separator: ",")
        guard key != appliedLists else { return }
        appliedLists = key
        c.removeAllContentRuleLists()
        lists.forEach(c.add)
    }

    private func observeNotifications() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: .blockerChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.webView != nil else { return }
            let before = self.appliedLists
            self.applyBlocking(for: self.url)
            if before != nil, before != self.appliedLists, self.isSelected, self.url != nil { self.webView?.reload() }
        })
        tokens.append(nc.addObserver(forName: .settingChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, let wv = self.webView, let key = note.userInfo?["key"] as? String else { return }
            switch key {
            case "gpc", "cookieBanners", "rejectCookies", "youtubeAds", "forceDark", "siteStyles", "adBlock", "allowlist":
                Scripts.install(on: wv.configuration.userContentController)
                if key == "siteStyles" {
                    // The page follows style changes as they're made; your JavaScript waits for the next load.
                    self.applySiteStyleLive()
                } else if ["forceDark", "cookieBanners", "rejectCookies", "youtubeAds", "gpc"].contains(key), self.isSelected, self.url != nil {
                    wv.reload()
                }
            case "developer":
                wv.isInspectable = Settings.shared.developer
            case "uaMode", "customUA":
                wv.customUserAgent = UserAgent.custom
            default:
                break
            }
        })
    }

    // MARK: Messages from the bridge script

    func handleMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "pickedElement":
            guard pickingElements, let selector = body["selector"] as? String, !selector.isEmpty, selector.count < 600,
                  let host else { return }
            let s = Settings.shared
            var style = s.siteStyle(for: host) ?? SiteStyle(host: SiteStyle.normalizedHost(host))
            if !style.hidden.contains(selector) { style.hidden.append(selector) }
            style.enabled = true
            s.saveSiteStyle(style)
        case "pickerDone":
            pickingElements = false
        case "favicon":
            guard let href = body["href"] as? String, let iconURL = URL(string: href), let host else { return }
            if faviconHost == host, favicon != nil { return }
            faviconHost = host
            if let cached = Favicons.shared.cached(host) { favicon = cached; return }
            let persist = !isPrivate
            Task { @MainActor [weak self] in
                guard await Favicons.mayFetch(iconURL, forPageHost: host) else { return }
                Favicons.shared.fetch(iconURL, host: host, persist: persist) { [weak self] img in
                    if self?.host == host { self?.favicon = img }
                }
            }
        case "hover":
            let link = body["url"] as? String
            if hoverURL != link { hoverURL = link }
        case "top":
            pull.atTop = body["top"] as? Bool ?? true
        case "media":
            let playing = body["playing"] as? Bool ?? false
            if isPlayingAudio != playing { isPlayingAudio = playing }
        case "loginFocus":
            guard Settings.shared.autofillPasswords else { return }
            let isNew = body["newPassword"] as? Bool ?? false
            let saved = isNew ? [] : PasswordStore.shared.logins(for: host)
            let strong = isNew && Settings.shared.suggestStrongPasswords ? PasswordStore.generate() : nil
            guard !saved.isEmpty || strong != nil || (!isNew && ExternalPasswordManager.current != nil) else { return }
            let x = (body["x"] as? Double) ?? 0, y = (body["y"] as? Double) ?? 0, w = (body["w"] as? Double) ?? 200
            loginMenu = LoginMenu(origin: CGPoint(x: x * zoom, y: y * zoom + 4), width: max(260, w * zoom), logins: saved, strongPassword: strong)
        case "loginBlur":
            if loginMenu != nil { loginMenu = nil }
        case "insecurePassword":
            insecureWarning = true
        case "loginUsername":
            if let host, let name = body["username"] as? String, !name.isEmpty { rememberedUser = (host, name, Date()) }
        case "loginSubmit":
            if loginMenu != nil { loginMenu = nil }
            offerToSave(username: body["username"] as? String ?? "", password: body["password"] as? String ?? "")
        default:
            break
        }
    }

    // MARK: Passwords

    private func offerToSave(username raw: String, password: String) {
        let s = Settings.shared
        guard s.savePasswords, s.passwordManager.isEmpty, !isPrivate, !password.isEmpty, let host,
              !s.neverSaveHosts.contains(PasswordStore.site(host)) else { return }
        var username = raw
        if username.isEmpty, let r = rememberedUser, PasswordStore.site(r.host) == PasswordStore.site(host),
           Date().timeIntervalSince(r.at) < 600 {
            username = r.name
        }
        let store = PasswordStore.shared
        let existing = store.logins(for: host).first { $0.username == username }
        if let existing, store.matches(host: existing.host, username: username, password: password) { return }
        let pending = PendingLogin(host: existing?.host ?? host, username: username, password: password, isUpdate: existing != nil)
        // Wait for the sign-in to navigate, so the banner doesn't flash on the login page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.pendingSave = pending }
    }

    func savePending() {
        guard let p = pendingSave else { return }
        PasswordStore.shared.save(host: p.host, username: p.username, password: p.password)
        pendingSave = nil
    }

    func neverSavePending() {
        guard let p = pendingSave else { return }
        Settings.shared.neverSaveHosts = Array(Set(Settings.shared.neverSaveHosts + [PasswordStore.site(p.host)])).sorted()
        pendingSave = nil
    }

    func fill(_ login: SavedLogin) {
        loginMenu = nil
        let reason = String(format: L("fill your password for %@"), login.host)
        PasswordStore.shared.password(for: login, reason: reason) { [weak self] password in
            guard let password, let wv = self?.webView else { return }
            wv.window?.makeFirstResponder(wv)
            wv.callAsyncJavaScript("return window.__lumenFill && window.__lumenFill(u, p)",
                                   arguments: ["u": login.username, "p": password], in: nil, in: .defaultClient) { _ in }
        }
    }

    /// Puts a generated password into the sign-up form; saving is offered when the form is sent.
    func fillStrong(_ password: String) {
        loginMenu = nil
        guard let wv = webView else { return }
        wv.window?.makeFirstResponder(wv)
        wv.callAsyncJavaScript("return window.__lumenFillNew && window.__lumenFillNew(p)",
                               arguments: ["p": password], in: nil, in: .defaultClient) { _ in }
    }

    private func showHTTPSOnlyPage(_ url: URL, in webView: WKWebView) {
        failedURL = url
        internalLoad = true
        internalNavigation = webView.loadHTMLString(Scripts.httpsOnlyPage(url: url), baseURL: nil)
    }

    private func openExternal(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return }
        if url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path)
        Dialogs.confirm(webView?.window, title: String(format: L("Open “%@”?"), name),
                        message: String(format: L("%@ wants to open a “%@” link in %@."), InputResolver.displayHost(self.url), url.scheme ?? "", name),
                        ok: L("Open")) { if $0 { NSWorkspace.shared.open(url) } }
    }

    private func handleError(_ error: Error, in webView: WKWebView) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain && e.code == NSURLErrorCancelled { return }
        // 102: interrupted by a policy change (downloads, our own redirects). 204: handled by a plug-in.
        if e.domain == "WebKitErrorDomain" && (e.code == 102 || e.code == 204) { return }
        let failing = (e.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? webView.url
        if let up = upgrade, let f = failing, f.scheme == "https", f.host?.lowercased() == up.host, HTTPSUpgrade.shouldFallBack(e) {
            HTTPSUpgrade.httpOnly.insert(up.host)
            upgrade = nil
            if Settings.shared.httpsOnly && !HTTPSUpgrade.userAllowed.contains(up.host) {
                showHTTPSOnlyPage(up.original, in: webView)
            } else {
                webView.load(URLRequest(url: up.original))
            }
            return
        }
        guard let f = failing else { return }
        failedURL = f
        internalLoad = true
        internalNavigation = webView.loadHTMLString(Scripts.errorPage(url: f, error: e), baseURL: f)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = Settings.shared.javaScript
        if internalLoad {
            internalLoad = false
            decisionHandler(.allow, preferences)
            return
        }
        if action.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }
        guard let url = action.request.url else {
            decisionHandler(.allow, preferences)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "lumen-continue-http" {
            decisionHandler(.cancel, preferences)
            let raw = String(url.absoluteString.dropFirst("lumen-continue-http:".count))
            if let target = URL(string: raw), let h = target.host?.lowercased() {
                HTTPSUpgrade.userAllowed.insert(h)
                load(target)
            }
            return
        }
        // Extension pages (settings, popups opened in a tab) use their own scheme.
        if !["http", "https", "file", "about", "data", "blob", "javascript", "webkit-extension"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame == true { openExternal(url) }
            return
        }
        if action.navigationType == .linkActivated,
           action.modifierFlags.contains(.command) || action.buttonNumber == 2 {
            decisionHandler(.cancel, preferences)
            browser?.openInBackground(url, from: self, select: action.modifierFlags.contains(.shift))
            return
        }
        // In an installed web app, links to other sites open in the browser.
        if WebApp.isActive, action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           let host = url.host, PasswordStore.site(host) != WebApp.site {
            decisionHandler(.cancel, preferences)
            WebApp.openInBrowser(url)
            return
        }
        if action.targetFrame?.isMainFrame == true {
            let s = Settings.shared
            let fresh = action.navigationType != .backForward && action.navigationType != .reload
                && (action.request.httpMethod ?? "GET") == "GET"
            if fresh, s.stripTracking, let clean = URLCleaner.unwrap(url) ?? URLCleaner.clean(url) {
                decisionHandler(.cancel, preferences)
                webView.load(URLRequest(url: clean))
                return
            }
            if fresh, s.httpsUpgrade || s.httpsOnly, HTTPSUpgrade.eligible(url), let host = url.host?.lowercased() {
                if let up = upgrade, up.host == host, Date().timeIntervalSince(up.at) < 5 {
                    // The HTTPS site redirected back to HTTP, so it doesn't want HTTPS.
                    HTTPSUpgrade.httpOnly.insert(host)
                    upgrade = nil
                    if s.httpsOnly && !HTTPSUpgrade.userAllowed.contains(host) {
                        decisionHandler(.cancel, preferences)
                        showHTTPSOnlyPage(url, in: webView)
                        return
                    }
                } else if let https = HTTPSUpgrade.upgraded(url) {
                    upgrade = (host, url, Date())
                    decisionHandler(.cancel, preferences)
                    webView.load(URLRequest(url: https))
                    return
                }
            }
            if s.httpsOnly, url.scheme == "http", let host = url.host?.lowercased(),
               HTTPSUpgrade.httpOnly.contains(host), !HTTPSUpgrade.userAllowed.contains(host) {
                decisionHandler(.cancel, preferences)
                showHTTPSOnlyPage(url, in: webView)
                return
            }
            applyBlocking(for: url)
        }
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = response.response as? HTTPURLResponse,
           (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        DownloadManager.shared.track(download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Each assignment redraws the views watching the tab, so only changes are made.
        if hoverURL != nil { hoverURL = nil }
        if loginMenu != nil { loginMenu = nil }
        if insecureWarning { insecureWarning = false }
        if navigation !== internalNavigation {
            if failedURL != nil { failedURL = nil }
            if isReader { isReader = false }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if !blockedHere.isEmpty { blockedHere = [:] }
        // A new page isn't translated, and isn't the one being read aloud.
        if translatedFrom != nil { translatedFrom = nil }
        if translationError != nil { translationError = nil }
        if readingAloud { ReadAloud.shared.stop() }
        let host = webView.url?.host?.lowercased()
        let z = host.flatMap { Settings.shared.siteZoom[$0] } ?? Settings.shared.defaultZoom
        if abs(webView.pageZoom - z) > 0.001 { webView.pageZoom = z }
        if zoom != z { zoom = z }
        if host != faviconHost {
            faviconHost = nil
            favicon = Favicons.shared.cached(host)
        }
        if isPlayingAudio { isPlayingAudio = false }
        browser?.tabDidNavigate(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if waking { finishWaking(restoreScroll: true) }
        guard navigation !== internalNavigation, !isPrivate, !isReader, let u = webView.url else { return }
        History.shared.record(url: u, title: webView.title ?? "")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleError(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A page that keeps crashing its process would otherwise reload forever, using all the CPU.
        if let last = lastCrash, Date().timeIntervalSince(last) < 15, let u = url ?? webView.url {
            lastCrash = nil
            let e = NSError(domain: "WebKitErrorDomain", code: 0, userInfo: [
                NSLocalizedDescriptionKey: L("This page stopped working more than once, so Tacet stopped reloading it."),
            ])
            failedURL = u
            internalLoad = true
            internalNavigation = webView.loadHTMLString(Scripts.errorPage(url: u, error: e), baseURL: u)
            return
        }
        lastCrash = Date()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard challenge.previousFailureCount < 3 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        Dialogs.credentials(webView.window, host: challenge.protectionSpace.host,
                            realm: challenge.protectionSpace.realm) { result in
            if let (user, pass) = result {
                completionHandler(.useCredential, URLCredential(user: user, password: pass, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - UI

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        browser?.openPopup(configuration: configuration, from: self, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        Dialogs.alert(webView.window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Dialogs.confirm(webView.window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        Dialogs.prompt(webView.window, title: frame.securityOrigin.host, message: prompt,
                       defaultText: defaultText ?? "", done: completionHandler)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = webView.window {
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        } else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kind = MediaPermission.Kind(type)
        let key = MediaPermission.key(host: origin.host, kind: kind)
        // Private windows remember a choice only in the tab; other windows remember it for the site.
        if let remembered = isPrivate ? mediaPermissions[key] : Settings.shared.mediaPermissions[key] {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        Dialogs.confirm(webView.window, title: String(format: L("Allow “%@” to use your %@?"), origin.host, kind.label),
                        message: L(isPrivate ? "Tacet remembers your choice until you close this tab."
                                             : "Tacet remembers your choice for this site. You can change it in Settings › Sites."),
                        ok: L("Allow"), cancel: L("Don't Allow")) { [weak self] allowed in
            guard let self else { decisionHandler(.deny); return }
            if self.isPrivate {
                self.mediaPermissions[key] = allowed
            } else {
                Settings.shared.mediaPermissions[key] = allowed
            }
            decisionHandler(allowed ? .grant : .deny)
        }
    }
}

// MARK: - Web view subclass

/// Adds Tacet's items to the page context menu.
final class LumenWebView: WKWebView {
    weak var tab: Tab?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard let tab, Settings.shared.pullToRefresh, tab.url != nil else { return }
        if tab.pull.track(event) { tab.reload() }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let renames = [
            "WKMenuItemIdentifierOpenLinkInNewWindow": L("Open Link in New Tab"),
            "WKMenuItemIdentifierOpenImageInNewWindow": L("Open Image in New Tab"),
            "WKMenuItemIdentifierOpenFrameInNewWindow": L("Open Frame in New Tab"),
            "WKMenuItemIdentifierOpenMediaInNewWindow": L("Open Video in New Tab"),
        ]
        for item in menu.items {
            if let id = item.identifier?.rawValue, let title = renames[id] { item.title = title }
        }
        addAssistantItems(to: menu)
        addExtensionItems(to: menu)
        guard let tab, let browser = tab.browser, let link = tab.hoverURL, let url = URL(string: link) else { return }
        let anchor = menu.items.firstIndex { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }
        var index = (anchor ?? -1) + 1
        let extra = [
            ActionMenuItem(L("Open Link in Background Tab")) { browser.openInBackground(url, from: tab) },
            ActionMenuItem(L("Open Link in Split View")) {
                let t = browser.newTab(url: url, select: false, after: tab)
                browser.openSplit(t)
            },
            ActionMenuItem(L("Copy Link Without Tracking")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((URLCleaner.clean(url) ?? url).absoluteString, forType: .string)
            },
        ]
        for item in extra {
            menu.insertItem(item, at: min(index, menu.items.count))
            index += 1
        }
    }
}

extension LumenWebView {
    /// The items extensions add to the page's right-click menu, at the end.
    func addExtensionItems(to menu: NSMenu) {
        guard #available(macOS 15.4, *), let tab, tab.browser?.isPrivate == false else { return }
        let items = Extensions.shared.loaded.flatMap { $0.context.menuItems(for: tab) }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    /// One quiet item for selected text, after Copy: Tacet Assistant › Explain, Translate, Summarise, Ask About It.
    func addAssistantItems(to menu: NSMenu) {
        guard Settings.shared.aiEnabled, let tab, let browser = tab.browser,
              let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) else { return }
        let sub = NSMenu()
        for action in AssistantChat.SelectionAction.allCases {
            sub.addItem(ActionMenuItem(action.title) { [weak self] in
                self?.evaluateJavaScript("String(window.getSelection ? window.getSelection() : '')", in: nil, in: .defaultClient) { result in
                    guard case .success(let value) = result, let text = value as? String,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    browser.assistantVisible = true
                    browser.assistant.act(on: text, action)
                }
            })
        }
        let item = NSMenuItem(title: L("Tacet Assistant"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        item.submenu = sub
        menu.insertItem(item, at: copy + 1)
    }
}

final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}

// MARK: - Dialogs

enum Dialogs {
    private static func present(_ alert: NSAlert, in window: NSWindow?, done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: done)
        } else {
            done(alert.runModal())
        }
    }

    static func alert(_ window: NSWindow?, title: String, message: String, done: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        present(a, in: window) { _ in done() }
    }

    static func confirm(_ window: NSWindow?, title: String, message: String, ok: String = L("OK"),
                        cancel: String = L("Cancel"), done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: ok)
        a.addButton(withTitle: cancel)
        present(a, in: window) { done($0 == .alertFirstButtonReturn) }
    }

    static func prompt(_ window: NSWindow?, title: String, message: String, defaultText: String,
                       done: @escaping (String?) -> Void) {
        let a = NSAlert()
        a.messageText = title.isEmpty ? L("This page says") : title
        a.informativeText = message
        a.addButton(withTitle: L("OK"))
        a.addButton(withTitle: L("Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText
        a.accessoryView = field
        a.window.initialFirstResponder = field
        present(a, in: window) { done($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    static func credentials(_ window: NSWindow?, host: String, realm: String?, done: @escaping ((String, String)?) -> Void) {
        let a = NSAlert()
        a.messageText = String(format: L("Sign in to %@"), host)
        a.informativeText = realm.map { String(format: L("The site says: “%@”"), $0) } ?? L("This site requires a username and password.")
        a.addButton(withTitle: L("Sign In"))
        a.addButton(withTitle: L("Cancel"))
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        user.placeholderString = L("Username")
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        pass.placeholderString = L("Password")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        box.addSubview(user)
        box.addSubview(pass)
        a.accessoryView = box
        a.window.initialFirstResponder = user
        present(a, in: window) { done($0 == .alertFirstButtonReturn ? (user.stringValue, pass.stringValue) : nil) }
    }
}

@Observable
final class LoadProgress {
    var value = 0.0
}

/// Scrolling up past the top of a page with the trackpad reloads it.
@Observable
final class PullToRefresh {
    /// 0 when idle, 1 when letting go reloads the page.
    private(set) var progress: CGFloat = 0
    @ObservationIgnored var atTop = true {
        didSet { if !atTop { reset() } }
    }
    @ObservationIgnored private var pulling = false
    @ObservationIgnored private var distance: CGFloat = 0
    static let threshold: CGFloat = 190

    /// Feeds a scroll event in. Returns true when the gesture ended past the threshold.
    func track(_ e: NSEvent) -> Bool {
        // Momentum after a flick never counts, and neither do mouse wheels, which have no gesture phases.
        guard e.momentumPhase == [], e.hasPreciseScrollingDeltas else { return false }
        switch e.phase {
        case .began:
            // Only a gesture that starts at the top counts, so a long scroll up doesn't reload on arrival.
            pulling = atTop
            distance = 0
        case .changed:
            guard pulling else { return false }
            distance = max(0, distance + e.scrollingDeltaY)
            let p = min(1, distance / Self.threshold)
            if abs(p - progress) > 0.02 || (p == 1) != (progress == 1) { progress = p }
        case .ended:
            let fire = pulling && distance >= Self.threshold
            reset()
            return fire
        case .cancelled:
            reset()
        default:
            break
        }
        return false
    }

    private func reset() {
        pulling = false
        distance = 0
        if progress != 0 { progress = 0 }
    }
}

// MARK: - What Tacet Shield blocked

extension Tab {
    /// WebKit tells its own browser about every request a content rule list blocked; it isn't public API, so the
    /// name is matched exactly and nothing breaks if a WebKit version stops calling it.
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func contentRuleList(_ webView: WKWebView, identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard webView === self.webView, action.responds(to: NSSelectorFromString("blockedLoad")),
              (action.value(forKey: "blockedLoad") as? Bool) == true else { return }
        let site = url.host.map { PasswordStore.site($0) } ?? url.absoluteString
        blockedHere[site, default: 0] += 1
    }

    var blockedCount: Int { blockedHere.values.reduce(0, +) }
}
