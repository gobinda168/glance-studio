import AppKit
import Combine
import GlanceCore
import SwiftUI
import WebKit

/// What a Browser tab shows: the start page (no web view at all), a plain page, a Slack workspace's session, or a
/// Jira or Confluence page.
enum BrowserContent {
    case start
    case web(WebPage)
    case slack(SlackSession)
    case atlassian(AtlassianPage)

    @MainActor var webView: WKWebView? {
        switch self {
        case .start: nil
        case .web(let page): page.webView
        case .slack(let session): session.webView
        case .atlassian(let page): page.webView
        }
    }
}

/// Bumped whenever a Browser tab opens, closes or retitles, for the side bar's Tabs list and the tiles' badges.
@MainActor
final class BrowserTabChanges: ObservableObject {
    static let shared = BrowserTabChanges()
    @Published private(set) var revision = 0
    func changed() { revision &+= 1 }
}

/// A Browser tab (spec 2026-10-10-browser-design.md, "Surface"): the top bar over a page, in a Studio tab. A saved
/// app has one main tab (key `app:<id>`); every other tab is `tab:<n>`.
@MainActor
final class BrowserTabController: NSWindowController, NSWindowDelegate, GlanceTabController, GlancePaneOwner,
    ObservableObject {
    static let kind = "browser"

    var tabKind: String { Self.kind }
    private(set) var tabKey: String
    /// The saved app this is the main tab of; nil for any other tab.
    @Published private(set) var appID: String?
    @Published private(set) var content: BrowserContent
    @Published private(set) var state = WebViewState()
    /// Going up puts the caret in the address field (⌘L, a new tab).
    @Published var addressFocus = 0
    /// The page's floating window (the top bar's PiP button) while it floats; the tab then holds a placeholder.
    @Published private(set) var floatingCall: FloatingCallWindow?
    @Published var findVisible = false
    @Published var findFocus = 0
    @Published var glancePaneOpen: Bool = GlanceTerminalHost.paneOpenDefault
    @Published var glancePlacement: PaneLayout.Placement?
    /// The pane follows the window's terminal, as on Home.
    var glanceDirectory: String? { HomeTabs.terminal(near: window)?.glanceDirectory }

    private var titleTokens: Set<AnyCancellable> = []
    private static var nextTab = 0
    /// Closed tabs' addresses, newest last, for ⌘⇧T.
    private static var closed: [URL] = []

    private init(content: BrowserContent, key: String, appID: String?) {
        self.content = content
        tabKey = key
        self.appID = appID
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.contentView = PullRequestHostingView(rootView: BrowserTabView(controller: self))
        follow()
        attachCapture()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Finding tabs

    static var all: [BrowserTabController] {
        GlanceTabHost.controllers(kind: kind).compactMap { $0 as? BrowserTabController }
    }

    /// The Browser tab in front of `window`'s tab group.
    static func front(in window: NSWindow?) -> BrowserTabController? {
        (window?.tabGroup?.selectedWindow ?? window)?.windowController as? BrowserTabController
    }

    static func main(appID: String) -> BrowserTabController? {
        all.first { $0.appID == appID }
    }

    // MARK: Opening

    /// A new tab beside `parent`: `url`'s page, or the start page with the caret in the address field.
    @discardableResult
    static func open(url: URL?, from parent: NSWindow?, background: Bool = false) -> BrowserTabController? {
        guard let url else { return present(.start, key: newKey(), appID: nil, from: parent, background: false) }
        if BrowserURL.destination(url) == .system {
            NSWorkspace.shared.open(url)
            return nil
        }
        let page = WebPage()
        page.load(url)
        return present(.web(page), key: newKey(), appID: nil, from: parent, background: background)
    }

    /// Shows `app`: its main tab brought forward wherever it is, or made in `parent`'s window. `newTab` opens another
    /// tab on its address instead, except for a Slack workspace, whose one page lives on with no tab.
    @discardableResult
    static func openApp(_ app: SavedApp, from parent: NSWindow?, newTab: Bool = false) -> BrowserTabController? {
        let single: Bool
        if case .slack = app.addOn { single = true } else { single = false }
        if newTab && !single {
            guard let content = content(for: app, url: nil) else { return nil }
            return present(content, key: newKey(), appID: nil, from: parent, background: false)
        }
        if let existing = main(appID: app.id) {
            existing.bringForward()
            return existing
        }
        guard let content = content(for: app, url: nil) else { return nil }
        return present(content, key: "app:\(app.id)", appID: app.id, from: parent, background: false)
    }

    /// A page for `app` at `url`, else its own address: a plain page, the workspace's running Slack session, or a
    /// new Jira or Confluence page on the site's store.
    private static func content(for app: SavedApp, url: URL?) -> BrowserContent? {
        switch app.addOn {
        case .none:
            let page = WebPage()
            page.load(url ?? app.url)
            return .web(page)
        case .slack(let team):
            return SlackSessions.shared.session(teamID: team).map { .slack($0) }
        case .atlassian(let siteID, let product):
            guard let site = AtlassianSessions.shared.store.site(id: siteID), let target = url ?? site.url(product)
            else { return nil }
            let page = AtlassianPage(site: site, product: product, configuration: AtlassianSessions.shared.configuration())
            page.load(target)
            return .atlassian(page)
        }
    }

    /// A Slack workspace's tab (a notification, an automation's link).
    static func openSlack(teamID: String, from parent: NSWindow?) {
        BrowserApps.shared.syncNow()
        guard let app = BrowserApps.shared.store.app(addOn: .slack(teamID: teamID)) else { return }
        openApp(app, from: parent)
    }

    /// A Slack sign-in tab; it becomes the workspace's main tab once Slack reaches a workspace.
    static func openSlackSignIn(from parent: NSWindow?) {
        let session = SlackSessions.shared.makeSignInSession()
        let controller = present(.slack(session), key: "slack-signin", appID: nil, from: parent, background: false)
        session.onSignedIn = { [weak controller] signIn, team in controller?.slackSignedIn(signIn, team: team) }
    }

    /// The sign-in page reached `team`: this tab becomes the workspace's, or, when the workspace already has a tab,
    /// that one comes forward and this one closes.
    private func slackSignedIn(_ signIn: SlackSession, team: String) {
        let served = SlackSessions.shared.adopt(signIn, teamID: team)
        BrowserApps.shared.syncNow()
        if served !== signIn {
            Self.openSlack(teamID: team, from: window)
            window?.close()
            return
        }
        setApp(BrowserApps.shared.store.app(addOn: .slack(teamID: team))?.id)
        show(.slack(served))
    }

    /// `url` (else the product's home) in the site's main `product` tab, brought forward and navigated wherever it is;
    /// `newTab` makes another tab.
    @discardableResult
    static func openAtlassian(site: AtlassianSite, product: AtlassianProduct, url: URL? = nil,
                              from parent: NSWindow?, newTab: Bool = false) -> BrowserTabController? {
        BrowserApps.shared.syncNow()
        guard let app = BrowserApps.shared.store.app(addOn: .atlassian(siteID: site.id, product: product)) else {
            return nil
        }
        if !newTab, let existing = main(appID: app.id) {
            existing.bringForward()
            if let url, case .atlassian(let page) = existing.content { page.load(url) }
            return existing
        }
        guard let content = content(for: app, url: url) else { return nil }
        return present(content, key: newTab ? newKey() : "app:\(app.id)", appID: newTab ? nil : app.id,
                       from: parent, background: false)
    }

    /// Every tab showing the workspace, when it leaves Glance.
    static func closeTabs(slackTeam: String) {
        for tab in all {
            if case .slack(let session) = tab.content, session.teamID == slackTeam { tab.window?.close() }
        }
    }

    /// Every tab showing the site, when it leaves Glance.
    static func closeTabs(atlassianSite id: String) {
        for tab in all {
            if case .atlassian(let page) = tab.content, page.site.id == id { tab.window?.close() }
        }
    }

    /// A page a site opened (a link to a new window, `window.open`), already holding its opener.
    @discardableResult
    static func open(page: WebPage, from parent: NSWindow?, background: Bool) -> BrowserTabController? {
        present(.web(page), key: newKey(), appID: nil, from: parent, background: background)
    }

    /// ⌘⇧T: the last closed tab's address again.
    static func reopenClosed(from parent: NSWindow?) {
        guard let url = closed.popLast() else { return NSSound.beep() }
        open(url: url, from: parent)
    }

    /// The tab whose page `window.close()`d itself.
    static func closeTab(showing webView: WKWebView) {
        all.first { $0.content.webView === webView }?.window?.close()
    }

    static func newKey() -> String {
        nextTab += 1
        return "tab:\(nextTab)"
    }

    /// Makes the tab in `parent`'s window and shows the Browser side bar; a background tab leaves the front tab in
    /// front.
    @discardableResult
    static func present(_ content: BrowserContent, key: String, appID: String?, from parent: NSWindow?,
                        background: Bool) -> BrowserTabController? {
        SidebarModeModel.shared.show(.browser)
        let previous = parent?.tabGroup?.selectedWindow ?? parent
        let controller = GlanceTabHost.open(kind: kind, key: key, from: parent, reuse: false) {
            BrowserTabController(content: content, key: key, appID: appID)
        }
        if case .start = content { controller?.addressFocus += 1 }
        if background, let previous {
            previous.tabGroup?.selectedWindow = previous
            previous.makeKeyAndOrderFront(nil)
        }
        BrowserTabChanges.shared.changed()
        return controller
    }

    func bringForward() {
        window?.tabGroup?.selectedWindow = window
        showWindowSafely(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// This tab becomes (or stops being) a saved app's main tab.
    func setApp(_ id: String?) {
        appID = id
        tabKey = id.map { "app:\($0)" } ?? Self.newKey()
        BrowserTabChanges.shared.changed()
    }

    /// The page this tab shows changed (the start page became a page, a Slack sign-in became its workspace).
    func show(_ content: BrowserContent) {
        self.content = content
        follow()
        attachCapture()
    }

    // MARK: Console and network log

    /// A plain page records its console and network in a file named for the tab (`glance-browser`).
    private func attachCapture() {
        if case .web(let page) = content { page.capture.attach(tabKey: tabKey) }
    }

    /// This tab's line in `tabs.json`; nil when it keeps no log.
    var logTab: WebLogTab? {
        guard case .web(let page) = content, let key = page.capture.tabKey, let file = page.capture.fileName else {
            return nil
        }
        return WebLogTab(key: key, title: displayTitle, url: state.url?.absoluteString ?? "", file: file,
                         focused: page.capture.focused)
    }

    /// A new terminal tab following this tab's console and network.
    func showLogsInTerminal() {
        guard case .web(let page) = content, let key = page.capture.tabKey else { return }
        WebLogCommand.openWatch(tabKey: key, near: window)
    }

    var keepsLog: Bool {
        guard case .web(let page) = content else { return false }
        return page.capture.tabKey != nil
    }

    // MARK: Floating

    /// Whether the PiP button applies: a plain page, not already floating.
    var canFloat: Bool {
        if case .web = content { return floatingCall == nil && state.url != nil }
        return false
    }

    /// The page leaves the tab for a small window above everything else; the call (or video) keeps playing.
    func floatPage() {
        guard canFloat, case .web(let page) = content else { return }
        floatingCall = FloatingCallWindow(webView: page.webView, title: displayTitle) { [weak self] in
            self?.attachPage()
        }
    }

    /// The floating page goes back into this tab, which comes forward.
    func attachPage() {
        guard let call = floatingCall else { return }
        floatingCall = nil
        call.dismiss(backToTab: true)
        bringForward()
    }

    // MARK: Navigating

    var webView: WKWebView? { content.webView }

    /// The address field's Return: `text` as an address or a search.
    func go(_ text: String) {
        guard let url = BrowserURL.resolve(text, engine: BrowserData.searchEngine) else { return }
        go(url)
    }

    func go(_ url: URL) {
        if BrowserURL.destination(url) == .system {
            NSWorkspace.shared.open(url)
            return
        }
        switch content {
        case .start:
            let page = WebPage()
            page.load(url)
            show(.web(page))
        case .web(let page): page.load(url)
        case .slack(let session): session.webView.load(URLRequest(url: url))
        case .atlassian(let page): page.load(url)
        }
    }

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }

    /// Reload, or Stop while loading.
    func reload() {
        if state.isLoading { webView?.stopLoading() } else { webView?.reload() }
    }

    /// ⌘+ (1), ⌘− (-1), ⌘0 (0): 10% steps between 50% and 300%.
    func zoom(_ step: Int) {
        guard let webView else { return }
        webView.pageZoom = step == 0 ? 1 : min(3, max(0.5, webView.pageZoom + CGFloat(step) * 0.1))
    }

    func openInDefaultBrowser() {
        if let url = state.url { NSWorkspace.shared.open(url) }
    }

    func copyLink() {
        guard let url = state.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    // MARK: Title

    /// The tab's name: the app's or the page's title, else its host, else "New Tab".
    var displayTitle: String {
        switch content {
        case .start: return "New Tab"
        case .slack(let session): return session.name
        case .atlassian(let page): return page.title
        case .web:
            if !state.title.isEmpty { return state.title }
            return state.url.map(BrowserURL.displayHost) ?? "New Tab"
        }
    }

    private func follow() {
        state = content.webView.map(WebViewState.init) ?? WebViewState()
        titleTokens = []
        let retitle: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.window?.title = self.displayTitle
                    BrowserTabChanges.shared.changed()
                    WebCaptureRegistry.refresh()
                }
            }
        }
        state.objectWillChange.sink { _ in retitle() }.store(in: &titleTokens)
        switch content {
        case .slack(let session): session.$name.sink { _ in retitle() }.store(in: &titleTokens)
        case .atlassian(let page): page.$title.sink { _ in retitle() }.store(in: &titleTokens)
        case .start, .web: break
        }
        retitle()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if case .web(let page) = content {
            page.capture.touch()
            WebCaptureRegistry.refresh()
        }
        GlanceTerminalHost.shared.focusChanged(self)
        BrowserTabChanges.shared.changed()
    }

    /// Closing the front tab leaves the neighbouring Browser tab in front (the next one, else the one before), not
    /// whichever tab AppKit picks. With no Browser tab left the front tab goes to AppKit, but the Browser side bar
    /// stays up. Closing a tab in the background changes nothing.
    private func keepBrowserInFront() {
        guard let window, let group = window.tabGroup, group.selectedWindow === window,
              let index = group.windows.firstIndex(of: window) else { return }
        let isBrowser: (NSWindow) -> Bool = { ($0.windowController as? BrowserTabController) != nil }
        let others = group.windows.filter { $0 !== window }
        let after = group.windows[(index + 1)...].filter { $0 !== window && isBrowser($0) }
        let before = group.windows[..<index].filter(isBrowser)
        if let next = after.first ?? before.last {
            group.selectedWindow = next
            DispatchQueue.main.async { next.makeKey() }
        } else if !others.isEmpty {
            DispatchQueue.main.async { SidebarModeModel.shared.show(.browser) }
        }
    }

    func windowWillClose(_ notification: Notification) {
        keepBrowserInFront()
        floatingCall?.dismiss()
        floatingCall = nil
        GlanceTabHost.closed(self)
        titleTokens = []
        if let url = state.url, BrowserURL.destination(url) == .tab { Self.closed.append(url) }
        switch content {
        case .start: break
        case .web(let page):
            page.capture.detach()
            page.close()
        // A workspace keeps running with no tab; a sign-in page that never reached one ends.
        case .slack(let session): SlackSessions.shared.discard(session)
        case .atlassian(let page): page.close()
        }
        BrowserTabChanges.shared.changed()
        WebCaptureRegistry.refresh()
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}
