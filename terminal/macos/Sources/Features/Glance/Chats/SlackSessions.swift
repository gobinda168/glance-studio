import AppKit
import Combine
import GlanceCore
import WebKit

/// Every Slack workspace under Chats, alive from launch whether or not a tab shows it (spec
/// 2026-10-09-chats-slack-design.md, "Sessions"): one web view each, all in one persistent data store, so Slack's
/// sign-in covers every workspace and survives relaunch.
@MainActor
final class SlackSessions: ObservableObject {
    static let shared = SlackSessions()
    static let dataStoreID = UUID(uuidString: "5C1A0C4E-6A11-4C3B-9F0E-0D1A5E5C1A0C")!

    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
    private static let storeKey = "chatWorkspaces"

    @Published private(set) var store: ChatWorkspaceStore
    private var sessions: [String: SlackSession] = [:]
    private var changes: [ObjectIdentifier: AnyCancellable] = [:]
    private var started = false

    private init() {
        store = ChatWorkspaceStore(data: Self.defaults.data(forKey: Self.storeKey))
    }

    /// At launch: a running session for every saved workspace.
    func start() {
        guard !started else { return }
        started = true
        for workspace in store.workspaces {
            let session = make(workspace)
            sessions[workspace.teamID] = session
            session.load()
        }
    }

    func session(teamID: String) -> SlackSession? { sessions[teamID] }

    /// Mentions across every workspace, for the strip's Chats badge.
    var totalMentions: Int { sessions.values.reduce(0) { $0 + $1.mentions } }
    /// Something is unread somewhere, for the strip's dot when there are no mentions.
    var anyUnread: Bool { sessions.values.contains { $0.unread } }

    /// A sign-in page, not yet any workspace's. It becomes one through `adopt` when it reaches a client address.
    func makeSignInSession() -> SlackSession {
        let session = make(nil)
        session.load()
        return session
    }

    /// `session` (a sign-in page) reached `teamID`'s client. A team already saved keeps its own session, which is
    /// returned, and `session` is closed; otherwise `session` becomes the team's and is saved.
    @discardableResult
    func adopt(_ session: SlackSession, teamID: String) -> SlackSession {
        if let existing = sessions[teamID], existing !== session {
            session.close()
            changes[ObjectIdentifier(session)] = nil
            return existing
        }
        let workspace = ChatWorkspace(teamID: teamID, name: session.name == "Sign in to Slack" ? teamID : session.name,
                                      iconURL: nil)
        store.add(workspace)
        save()
        session.becomeWorkspace(store.workspace(teamID: teamID) ?? workspace)
        sessions[teamID] = session
        return session
    }

    func rename(teamID: String, to name: String) {
        store.update(teamID: teamID, name: name, iconURL: nil)
        save()
    }

    func setIcon(teamID: String, url: String) {
        guard store.workspace(teamID: teamID)?.iconURL != url else { return }
        store.update(teamID: teamID, name: nil, iconURL: url)
        save()
    }

    /// Forgets `teamID`: its tab closes, its page ends. Slack's sign-in cookie stays in the data store.
    func remove(teamID: String) {
        BrowserTabController.closeTabs(slackTeam: teamID)
        if let session = sessions.removeValue(forKey: teamID) {
            session.close()
            changes[ObjectIdentifier(session)] = nil
        }
        store.remove(teamID: teamID)
        save()
    }

    func reload(teamID: String) {
        sessions[teamID]?.webView.reload()
    }

    /// A sign-in page closed before it reached a workspace.
    func discard(_ session: SlackSession) {
        guard session.teamID == nil else { return }
        session.close()
        changes[ObjectIdentifier(session)] = nil
    }

    private func make(_ workspace: ChatWorkspace?) -> SlackSession {
        let session = SlackSession(workspace: workspace, configuration: Self.configuration())
        // The side bar and the strip redraw when any session's state changes.
        changes[ObjectIdentifier(session)] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return session
    }

    private func save() {
        Self.defaults.set(store.encoded(), forKey: Self.storeKey)
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        configuration.applicationNameForUserAgent = StudioWebView.safariApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        return configuration
    }
}
