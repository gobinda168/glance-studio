import AppKit
import Combine
import GlanceCore

/// The Browser's saved apps (spec 2026-10-10-browser-design.md, "Saved apps"): the tiles, kept in Application Support
/// (Browser/apps.json) and in step with Slack's workspaces and Atlassian's sites, and each tile's badge.
@MainActor
final class BrowserApps: ObservableObject {
    static let shared = BrowserApps()

    struct Badge: Equatable {
        var count = 0
        var unread = false
        var signedOut = false
    }

    @Published private(set) var store: SavedAppStore
    private let file = BrowserData.folder.appendingPathComponent("apps.json")
    private var tokens: Set<AnyCancellable> = []
    private var started = false

    private init() {
        store = SavedAppStore(data: try? Data(contentsOf: BrowserData.folder.appendingPathComponent("apps.json")))
    }

    /// At launch, and when the Develop menu switches the Browser on: Slack's workspaces and Atlassian's sites start,
    /// and the tiles follow their stores from now on.
    func start() {
        guard !started else { return }
        started = true
        SlackSessions.shared.start()
        AtlassianSessions.shared.start()
        syncNow()
        BrowserKeys.install()
        SlackSessions.shared.$store.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncNow() } } }
            .store(in: &tokens)
        AtlassianSessions.shared.$store.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncNow() } } }
            .store(in: &tokens)
        // Counts, sign-ins and plain apps' titles redraw the tiles and the strip.
        SlackSessions.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
        AtlassianSessions.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &tokens)
        BrowserTabChanges.shared.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &tokens)
    }

    /// The add-on tiles brought in line with Slack's and Atlassian's stores right now.
    func syncNow() {
        var next = store
        if next.sync(slack: SlackSessions.shared.store.workspaces, atlassian: AtlassianSessions.shared.store.sites) {
            store = next
            save()
        }
    }

    @discardableResult
    func add(name: String, url: URL) -> SavedApp {
        var next = store
        let app = next.add(SavedApp(name: name, url: url))
        store = next
        save()
        return app
    }

    /// ☆ on a tab: its page saved as an app, named after the page, and the tab becomes that app's main tab.
    func save(_ tab: BrowserTabController) {
        guard let url = tab.state.url, BrowserURL.destination(url) == .tab else { return }
        let app = add(name: tab.displayTitle, url: url)
        if BrowserTabController.main(appID: app.id) == nil { tab.setApp(app.id) }
    }

    /// A plain app or a Slack workspace takes the new name; a Jira or Confluence tile is named after its site.
    func rename(_ app: SavedApp, to name: String) {
        switch app.addOn {
        case .none:
            var next = store
            next.rename(id: app.id, to: name)
            store = next
            save()
        case .slack(let team): SlackSessions.shared.rename(teamID: team, to: name)
        case .atlassian(let site, _): AtlassianSessions.shared.rename(site, to: name)
        }
    }

    func move(_ app: SavedApp, to index: Int) {
        var next = store
        next.move(id: app.id, to: index)
        store = next
        save()
    }

    /// Forgets `app`. A workspace or site leaves Glance with its tabs; a plain app's tab stays open as an ordinary tab.
    func remove(_ app: SavedApp) {
        switch app.addOn {
        case .none:
            BrowserTabController.main(appID: app.id)?.setApp(nil)
            var next = store
            next.remove(id: app.id)
            store = next
            save()
        case .slack(let team): SlackSessions.shared.remove(teamID: team)
        case .atlassian(let site, _): AtlassianSessions.shared.remove(site)
        }
    }

    /// Shows `app` in its main tab (or, with `newTab`, a new tab on its address).
    func open(_ app: SavedApp, from window: NSWindow?, newTab: Bool) {
        BrowserTabController.openApp(app, from: window, newTab: newTab)
    }

    func badge(_ app: SavedApp) -> Badge {
        switch app.addOn {
        case .slack(let team):
            guard let session = SlackSessions.shared.session(teamID: team) else { return Badge() }
            return Badge(count: session.mentions, unread: session.unread, signedOut: session.signedOut)
        case .atlassian(let site, _):
            return Badge(signedOut: AtlassianSessions.shared.signIn(site) == .signedOut)
        case .none:
            let title = BrowserTabController.main(appID: app.id)?.state.title ?? ""
            return Badge(count: TitleBadge.count(title) ?? 0)
        }
    }

    /// The strip's Browser badge: every app's count.
    var stripBadge: Int { store.apps.reduce(0) { $0 + badge($1).count } }
    /// The strip's dot when nothing counts but something is unread.
    var stripUnread: Bool { stripBadge == 0 && store.apps.contains { badge($0).unread } }

    private func save() {
        try? FileManager.default.createDirectory(at: BrowserData.folder, withIntermediateDirectories: true)
        try? store.encoded().write(to: file, options: .atomic)
    }
}
