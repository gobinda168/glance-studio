import AppKit
import Combine
import GlanceCore
import WebKit

/// One Slack workspace's web client (or a sign-in page before it has one), alive whether or not a tab shows it
/// (spec 2026-10-09-chats-slack-design.md, "Sessions").
@MainActor
final class SlackSession: NSObject, ObservableObject {
    let webView: SlackWebView
    /// The workspace's team id; nil while this is a sign-in page.
    private(set) var teamID: String?
    @Published private(set) var name: String
    /// The page went back to Slack's sign-in.
    @Published private(set) var signedOut = false
    /// From the page title (`SlackTitle`): mentions waiting, and whether anything is unread.
    @Published private(set) var mentions = 0
    @Published private(set) var unread = false
    /// The last download's failure, shown at the bottom of the tab for 6 s.
    @Published var downloadError: String?
    /// The page's process died twice within a minute: the tab shows "Slack stopped." with Reload.
    @Published private(set) var stopped = false
    private var lastCrash: Date?
    /// Called once when a sign-in page reaches a workspace's client address.
    var onSignedIn: ((SlackSession, String) -> Void)?

    private var navigation: SlackNavigation!
    private var titleToken: NSKeyValueObservation?

    /// A workspace's session, or a sign-in page when `workspace` is nil.
    init(workspace: ChatWorkspace?, configuration: WKWebViewConfiguration) {
        teamID = workspace?.teamID
        name = workspace?.name ?? "Sign in to Slack"
        webView = SlackWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.isInspectable = true
        SlackNoticeBridge.install(on: webView, session: self)
        navigation = SlackNavigation(session: self)
        webView.navigationDelegate = navigation
        webView.uiDelegate = navigation
        titleToken = webView.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.titleChanged(view.title ?? "") }
        }
    }

    /// While signing in (a sign-in page, or a workspace that was signed out), every web page stays in the view.
    var signingIn: Bool { teamID == nil || signedOut }

    func load() {
        let url = teamID.map { ChatWorkspace(teamID: $0, name: name, iconURL: nil).clientURL } ?? SlackURL.signInURL
        webView.load(URLRequest(url: url))
    }

    /// The main frame committed `url`: a sign-in page found its workspace, or a workspace signed out or back in.
    func pageCommitted(_ url: URL) {
        if let team = SlackURL.teamID(url) {
            signedOut = false
            if teamID == nil {
                teamID = team
                onSignedIn?(self, team)
            }
        } else if teamID != nil, SlackURL.isSignIn(url) {
            signedOut = true
            mentions = 0
            unread = false
        }
    }

    /// The workspace this session now serves, after `SlackSessions.adopt` (a sign-in page becoming its workspace).
    /// The title may already name it, with no change left for the title watch to see, so it's read again here.
    func becomeWorkspace(_ workspace: ChatWorkspace) {
        teamID = workspace.teamID
        name = workspace.name
        titleChanged(webView.title ?? "")
    }

    private func titleChanged(_ title: String) {
        let parsed = SlackTitle(title)
        if teamID != nil {
            mentions = signedOut ? 0 : parsed.mentions
            unread = signedOut ? false : parsed.unread
        }
        if teamID != nil, let workspace = parsed.workspace, workspace != name {
            name = workspace
            if let teamID { SlackSessions.shared.rename(teamID: teamID, to: workspace) }
        }
    }

    /// The page's process died: reload once; a second time within a minute stops, and the counts clear.
    func crashed() {
        let now = Date()
        if let last = lastCrash, now.timeIntervalSince(last) < 60 {
            stopped = true
            mentions = 0
            unread = false
        } else {
            webView.reload()
        }
        lastCrash = now
    }

    func restart() {
        stopped = false
        lastCrash = nil
        load()
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
