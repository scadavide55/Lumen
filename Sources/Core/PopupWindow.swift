import AppKit
import WebKit

/// A small separate window for pop-ups (sign-in dialogs, payment pages) when tabs aren't wanted.
final class PopupWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var observations: [NSKeyValueObservation] = []
    private let onClose: (PopupWindow) -> Void
    /// The window that opened the pop-up; links it opens go there, so a private window's stay private.
    private weak var opener: BrowserState?

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, opener: BrowserState?, onClose: @escaping (PopupWindow) -> Void) {
        self.onClose = onClose
        self.opener = opener
        let parent = opener?.window
        let width = features.width.map { CGFloat($0.doubleValue) } ?? 620
        let height = features.height.map { CGFloat($0.doubleValue) } ?? 720
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        webView.uiDelegate = self
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // The address is always shown, so a fake sign-in pop-up can't pass for the real site.
        observations = [
            webView.observe(\.title, options: .initial) { [weak self] w, _ in
                self?.window.title = w.title?.isEmpty == false ? w.title! : (w.url?.host ?? "")
            },
            webView.observe(\.url, options: .initial) { [weak self] w, _ in self?.updateSubtitle(w) },
            webView.observe(\.hasOnlySecureContent) { [weak self] w, _ in self?.updateSubtitle(w) },
        ]
        if let parent {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func updateSubtitle(_ w: WKWebView) {
        guard let url = w.url, let host = url.host else { window.subtitle = ""; return }
        let secure = url.scheme == "https" && w.hasOnlySecureContent
        window.subtitle = (secure ? "🔒 " : "⚠️ ") + host
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func windowWillClose(_ notification: Notification) {
        observations = []
        onClose(self)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if let opener {
            opener.newTab(url: url)
            opener.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowRegistry.shared.open([url])
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        Dialogs.alert(window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        Dialogs.confirm(window, title: frame.securityOrigin.host, message: message, done: completionHandler)
    }
}
