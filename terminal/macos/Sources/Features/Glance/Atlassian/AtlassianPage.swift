import AppKit
import Combine
import GlanceCore
import WebKit

/// One Jira or Confluence tab's page (spec 2026-10-09-jira-confluence-design.md, "Tabs"): its web view on the shared
/// data store, its title, and what goes over it (a download's failure, "Jira stopped."). It also notices the user
/// signing in and out on the way.
@MainActor
final class AtlassianPage: NSObject, ObservableObject {
    let site: AtlassianSite
    let product: AtlassianProduct
    let webView: StudioWebView
    @Published private(set) var title: String
    /// The last download's failure, shown at the bottom of the tab for 6 s.
    @Published var downloadError: String?
    /// The page's process died twice within a minute: the tab shows "<Product> stopped." with Reload.
    @Published private(set) var stopped = false
    private var lastCrash: Date?
    private var lastURL: URL?
    private var navigation: AtlassianNavigation!
    private var titleToken: NSKeyValueObservation?

    init(site: AtlassianSite, product: AtlassianProduct, configuration: WKWebViewConfiguration) {
        self.site = site
        self.product = product
        title = product.title
        webView = StudioWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.isInspectable = true
        navigation = AtlassianNavigation(page: self)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        titleToken = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.titleChanged(view.title ?? "") }
        }
    }

    /// While the site isn't signed in, every web page stays in the tab, so the company's sign-in can run.
    var signingIn: Bool {
        if case .signedIn = AtlassianSessions.shared.signIn(site.id) { return false }
        return true
    }

    func load(_ url: URL) {
        lastURL = url
        webView.load(URLRequest(url: url))
    }

    /// The main frame committed `url`: a sign-in page means signed out; a page of the site while not signed in may be
    /// the sign-in finishing, so the site is checked.
    func pageCommitted(_ url: URL) {
        if AtlassianURL.product(of: url, site: site) != nil { lastURL = url }
        if AtlassianURL.isSignIn(url, site: site) {
            AtlassianSessions.shared.signedOut(site.id)
        } else if signingIn, AtlassianURL.product(of: url, site: site) != nil {
            AtlassianSessions.shared.refresh(site.id)
        }
    }

    private func titleChanged(_ raw: String) {
        let current = AtlassianSessions.shared.store.site(id: site.id) ?? site
        title = AtlassianTitle.clean(raw, product: product, site: current)
    }

    /// The page's process died: reload once; a second time within a minute stops.
    func crashed() {
        let now = Date()
        if let last = lastCrash, now.timeIntervalSince(last) < 60 {
            stopped = true
        } else if let url = lastURL ?? site.url(product) {
            webView.load(URLRequest(url: url))
        }
        lastCrash = now
    }

    func restart() {
        stopped = false
        lastCrash = nil
        if let url = lastURL ?? site.url(product) { load(url) }
    }

    /// Ends the page: no more connection, timers or sound.
    func close() {
        titleToken = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
}
