import AppKit
import Combine
import GlanceCore
import WebKit

/// A plain Browser tab's page (spec 2026-10-10-browser-design.md, "Surface"): a web view on the Browser's data store,
/// and what goes over it (a failed load's page, "This page stopped.", a download's failure).
@MainActor
final class WebPage: NSObject, ObservableObject {
    struct LoadError: Equatable {
        let url: URL
        let message: String
        /// The server's certificate wasn't trusted.
        let certificate: Bool
    }

    let webView: StudioWebView
    /// The tab's console and network log (WebCapture).
    let capture: WebCapture
    @Published var downloadError: String?
    @Published private(set) var stopped = false
    @Published private(set) var loadError: LoadError?
    private var lastCrash: Date?
    private var trustedHosts: Set<String> = []
    private var navigation: BrowserNavigation!

    /// A new page; `configuration` is WebKit's own for a window a site opened, so it keeps its opener.
    init(configuration: WKWebViewConfiguration? = nil) {
        let capture = WebCapture()
        let own = configuration ?? BrowserData.configuration()
        // A window a site opened shares its opener's controller, which already records.
        if configuration == nil { capture.install(on: own) }
        self.capture = capture
        webView = StudioWebView(frame: .zero, configuration: own)
        super.init()
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        navigation = BrowserNavigation(page: self)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
    }

    func load(_ url: URL) {
        loadError = nil
        webView.load(URLRequest(url: url))
    }

    func committed() {
        loadError = nil
    }

    /// A load failed: the error page, unless it was only replaced by another load or turned into a download.
    func failed(_ error: Error, url: URL?) {
        let error = error as NSError
        capture.documentFailed(error, url: url)
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        // 102: the load became a download or was stopped by a policy decision; 204: a plug-in took it.
        if error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code) { return }
        guard let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? url else { return }
        let certificate = error.domain == NSURLErrorDomain && [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected, NSURLErrorSecureConnectionFailed,
        ].contains(error.code)
        loadError = LoadError(url: failing, message: error.localizedDescription, certificate: certificate)
    }

    /// The error page's "Continue Anyway", offered only for this Mac's own servers: their certificate is trusted for
    /// this page from now on.
    func continueAnyway() {
        guard let error = loadError, BrowserURL.isLocal(error.url), let host = error.url.host else { return }
        trustedHosts.insert(host)
        load(error.url)
    }

    func trusts(host: String) -> Bool { trustedHosts.contains(host) }

    /// The page's process died: reload once; a second time within a minute stops.
    func crashed() {
        let now = Date()
        if let last = lastCrash, now.timeIntervalSince(last) < 60 {
            stopped = true
        } else {
            webView.reload()
        }
        lastCrash = now
    }

    func restart() {
        stopped = false
        lastCrash = nil
        if let url = loadError?.url ?? webView.url { load(url) }
    }

    /// Ends the page: no more connection, timers or sound.
    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
}
