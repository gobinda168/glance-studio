import AppKit
import GlanceCore
import UniformTypeIdentifiers
import WebKit

/// A plain Browser tab's navigation and UI delegate (spec 2026-10-10-browser-design.md, "Links"):
/// - web addresses stay; mail, calls and apps' schemes go to macOS;
/// - ⌘-click opens a background tab (⌘⇧-click a front one);
/// - a link or script that opens a window gets a new tab holding its opener, a sized window a pop-up;
/// - downloads go to ~/Downloads; file inputs, alerts, confirms and prompts are native.
@MainActor
final class BrowserNavigation: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private weak var page: WebPage?

    init(page: WebPage) {
        self.page = page
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
        if BrowserURL.destination(url) == .system {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) {
            BrowserTabController.open(url: url, from: webView.window,
                                      background: !action.modifierFlags.contains(.shift))
            return decisionHandler(.cancel)
        }
        decisionHandler(action.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse { page?.capture.document(http) }
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        page?.committed()
        if let url = webView.url { BrowserData.recordVisit(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, let title = webView.title, !title.isEmpty { BrowserData.recordTitle(title, for: url) }
        Favicons.shared.read(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        page?.failed(error, url: webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        page?.failed(error, url: nil)
    }

    /// This Mac's own servers with a self-signed certificate, once the user chose Continue Anyway.
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
           page?.trusts(host: space.host) == true {
            return completionHandler(.useCredential, URLCredential(trust: trust))
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Camera and microphone: macOS asks once for Glance Studio, WebKit once per site (B5 adds meeting rules).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.prompt)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.crashed()
    }

    // MARK: Windows

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if windowFeatures.width != nil || windowFeatures.height != nil {
            let title = action.request.url.map(BrowserURL.displayHost) ?? "Sign in"
            return WebPopupWindow(configuration: configuration, title: title, over: webView.window) { _ in true }.webView
        }
        let opened = WebPage(configuration: configuration)
        BrowserTabController.open(page: opened, from: webView.window, background: false)
        return opened.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        BrowserTabController.closeTab(showing: webView)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            return completionHandler(panel.runModal() == .OK ? panel.urls : nil)
        }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { completionHandler(response == .OK ? panel.urls : nil) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = Self.alert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = Self.alert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = Self.alert(prompt, frame: frame)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// A page's alert, titled with the site that asked.
    private static func alert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "This page says" : "\(frame.securityOrigin.host) says"
        alert.informativeText = message
        return alert
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping @MainActor (URL?) -> Void) {
        completionHandler(WebDownloads.destination(for: suggestedFilename))
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = download.progress.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        page?.downloadError = "Couldn't download: \(error.localizedDescription)"
    }
}
