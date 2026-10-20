import AppKit
import GlanceCore
import WebKit

/// A Slack session's navigation and UI delegate (spec 2026-10-09-chats-slack-design.md, "Links and downloads"):
/// Slack's pages stay, other sites open in the default browser, file downloads go to ~/Downloads, pages that open
/// windows get a `SlackPopupWindow`.
@MainActor
final class SlackNavigation: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private weak var session: SlackSession?

    init(session: SlackSession) {
        self.session = session
    }

    private var signingIn: Bool { session?.signingIn ?? true }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        // Frames inside the page (link previews, embeds) load wherever they come from.
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
        switch SlackURL.route(url, signingIn: signingIn) {
        case .stay: decisionHandler(action.shouldPerformDownload ? .download : .allow)
        case .download: decisionHandler(.download)
        case .browser:
            BrowserTabController.open(url: url, from: webView.window)
            decisionHandler(.cancel)
        }
    }

    /// A response WebKit can't show, or one Slack marks as an attachment, downloads.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { session?.pageCommitted(url) }
    }

    /// Slack changes the address without loading a page (a channel switch): a committed load doesn't see it.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { session?.pageCommitted(url) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// A huddle's camera or microphone: macOS asks once for Glance Studio, WebKit once per Slack origin. Other origins
    /// (an embed) are refused.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(SlackURL.isSlackHost(origin.host) ? .prompt : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session?.crashed()
    }

    // MARK: Windows

    /// A window a page opens (`SlackURL.newWindow`): a Slack page loads here (the workspace picker opens the chosen
    /// workspace that way), a blank window or an identity provider becomes a pop-up, anything else opens in the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let url = action.request.url ?? URL(string: "about:blank")!
        switch SlackURL.newWindow(url, signingIn: signingIn) {
        case .sameView:
            webView.load(action.request)
            return nil
        case .browser:
            BrowserTabController.open(url: url, from: webView.window)
            return nil
        case .popUp:
            return SlackPopupWindow(configuration: configuration, signingIn: signingIn, over: webView.window).webView
        }
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(Self.destination(for: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        session?.downloadError = "Couldn't download: \(error.localizedDescription)"
    }

    /// ~/Downloads/<name>, with " 2", " 3"… before the extension when the name is taken.
    static func destination(for name: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }
}
