import AppKit
import WebKit

/// A small separate window for pop-ups (sign-in dialogs, payment pages) when tabs aren't wanted.
final class PopupWindow: NSObject, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var titleObservation: NSKeyValueObservation?
    private let onClose: (PopupWindow) -> Void

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, parent: NSWindow?, onClose: @escaping (PopupWindow) -> Void) {
        self.onClose = onClose
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
        titleObservation = webView.observe(\.title) { [weak self] w, _ in
            self?.window.title = w.title?.isEmpty == false ? w.title! : (w.url?.host ?? "")
        }
        if let parent {
            let f = parent.frame
            window.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.midY - height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func windowWillClose(_ notification: Notification) {
        titleObservation = nil
        onClose(self)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { WindowRegistry.shared.open([url]) }
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
