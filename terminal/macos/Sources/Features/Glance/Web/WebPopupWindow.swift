import AppKit
import WebKit

/// A window a page opened (sign-in steps use them), 480×640 over its tab. An address `stays` accepts loads in it;
/// any other opens in a Browser tab, and a window that never showed a page goes away. It keeps itself alive
/// until it closes.
@MainActor
final class WebPopupWindow: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private let stays: (URL) -> Bool
    private var showedPage = false
    private var keepAlive: WebPopupWindow?

    init(configuration: WKWebViewConfiguration, title: String, over parent: NSWindow?,
         stays: @escaping (URL) -> Bool) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.stays = stays
        super.init()
        keepAlive = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = webView
        window.delegate = self
        if let parent {
            let frame = parent.frame
            window.setFrameOrigin(NSPoint(x: frame.midX - 240, y: frame.midY - 320))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.targetFrame?.isMainFrame == false || stays(url) {
            if url.scheme != "about" { showedPage = true }
            return decisionHandler(.allow)
        }
        BrowserTabController.open(url: url, from: NSApp.mainWindow)
        decisionHandler(.cancel)
        if !showedPage { window.close() }
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func windowWillClose(_ notification: Notification) {
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        keepAlive = nil
    }
}
