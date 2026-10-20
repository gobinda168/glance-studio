import AppKit
import GlanceCore
import WebKit

/// A Jira or Confluence tab's navigation and UI delegate (spec 2026-10-09-jira-confluence-design.md, "Links and
/// downloads"):
/// - the site's pages of this product stay, and the other product's go to its tab;
/// - other addresses open in the default browser;
/// - attachments download to ~/Downloads;
/// - a page that opens a window gets a pop-up while signing in, and otherwise a tab.
@MainActor
final class AtlassianNavigation: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private weak var page: AtlassianPage?

    init(page: AtlassianPage) {
        self.page = page
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let page else { return decisionHandler(.cancel) }
        // Frames inside the page (previews, embeds) load wherever they come from.
        if action.targetFrame?.isMainFrame == false { return decisionHandler(.allow) }
        switch AtlassianURL.route(url, from: page.product, site: page.site, signingIn: page.signingIn) {
        case .stay:
            decisionHandler(action.shouldPerformDownload ? .download : .allow)
        case .other(let product):
            decisionHandler(.cancel)
            BrowserTabController.openAtlassian(site: page.site, product: product, url: url, from: webView.window)
        case .browser:
            BrowserTabController.open(url: url, from: webView.window)
            decisionHandler(.cancel)
        }
    }

    /// A response WebKit can't show, or one marked as an attachment, downloads.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url { page?.pageCommitted(url) }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Jira and Confluence don't need the camera or microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        page?.crashed()
    }

    // MARK: Windows

    /// While signing in, a window becomes a pop-up (identity providers use them). Otherwise a link that opens a window
    /// goes where its address belongs: the browser, the other product's tab, or a new tab of this product.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let page else { return nil }
        if let url = action.request.url, url.scheme != "about", !url.absoluteString.isEmpty, !page.signingIn {
            switch AtlassianURL.route(url, from: page.product, site: page.site, signingIn: false) {
            case .browser:
                BrowserTabController.open(url: url, from: webView.window)
            case .other(let product):
                BrowserTabController.openAtlassian(site: page.site, product: product, url: url, from: webView.window)
            case .stay:
                BrowserTabController.openAtlassian(site: page.site, product: page.product, url: url,
                                                   from: webView.window, newTab: true)
            }
            return nil
        }
        let site = page.site
        let product = page.product
        return WebPopupWindow(configuration: configuration, title: product.title, over: webView.window) { url in
            AtlassianURL.route(url, from: product, site: site, signingIn: true) == .stay
        }.webView
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
