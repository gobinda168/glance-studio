import AppKit
import GlanceCore
import WebKit

/// The editor tab's web view: VS Code's web workbench from the local server. VS Code gets every key except Glance
/// Terminal's tab- and app-level shortcuts (`EditorShortcuts`), which go straight to the menu.
final class VSCodeWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let key = EditorShortcuts.Key(characters: event.charactersIgnoringModifiers ?? "",
                                      command: flags.contains(.command), shift: flags.contains(.shift),
                                      option: flags.contains(.option), control: flags.contains(.control))
        if EditorShortcuts.belongsToApp(key), NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps the editor tab on the server's pages: other links open in the default browser, as do pages asking for a new
/// window. Frames inside the page (extension webviews) are allowed wherever they come from.
final class VSCodeNavigation: NSObject, WKNavigationDelegate, WKUIDelegate {
    var port: Int?

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.targetFrame?.isMainFrame == false || EditorServer.isWorkbench(url, port: port) {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    /// VS Code reports a blocked pop-up when `window.open` gives it nothing, and in WebKit it opens a blank window
    /// first and sets its address after. So the page gets a window that never shows (`PopupCatcher`).
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        PopupCatcher(configuration: configuration).webView
    }
}

/// A window the page opened: it stays hidden, its first real address goes to the default browser, and then it goes
/// away. It keeps itself alive until then, or for 30 s at most.
@MainActor
private final class PopupCatcher: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private var keepAlive: PopupCatcher?

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        keepAlive = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finish() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, url.scheme != "about" else { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        finish()
    }

    func webViewDidClose(_ webView: WKWebView) { finish() }

    private func finish() {
        guard keepAlive != nil else { return }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        keepAlive = nil
    }
}
