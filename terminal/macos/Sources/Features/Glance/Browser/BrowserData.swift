import AppKit
import GlanceCore
import WebKit

/// What every plain Browser tab shares (spec 2026-10-10-browser-design.md, "Sessions and data"): one persistent data
/// store and configuration, the history, the search engine. Slack and Atlassian apps keep their own stores.
@MainActor
enum BrowserData {
    static let dataStoreID = UUID(uuidString: "B4D5E0C2-7E1A-4C55-9A0B-2F6C8E9D1B07")!
    static let dataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
    private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

    /// ~/Library/Application Support/Glance Studio/Browser.
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glance Studio/Browser", isDirectory: true)

    /// nil when the file can't be opened: the address field then suggests no history.
    static let history: BrowserHistory? = try? BrowserHistory(url: folder.appendingPathComponent("history.sqlite"))

    static var searchEngine: SearchEngine {
        get { SearchEngine(saved: defaults.string(forKey: "browserSearchEngine")) }
        set { defaults.set(newValue.rawValue, forKey: "browserSearchEngine") }
    }

    /// Dev servers' pages from Studio's terminals open in a Browser tab (Settings → Browser); on until switched off.
    static var opensDevServers: Bool {
        get { DevServerLinks.isEnabled(in: defaults) }
        set { defaults.set(newValue, forKey: DevServerLinks.settingKey) }
    }

    /// A page floated in the PiP window shows its mobile site, the one made for a window that size; on until switched off.
    static var floatsMobileSite: Bool {
        get { defaults.object(forKey: "floatsMobileSite") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "floatsMobileSite") }
    }

    /// Console and network of plain tabs are recorded for `glance-browser` (Settings → Browser); on until switched off.
    /// Takes effect for tabs opened after the change.
    static var capturesLogs: Bool {
        get { defaults.object(forKey: "browserCapturesLogs") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "browserCapturesLogs") }
    }

    /// Passwords, tokens, cookies and authorization headers are masked before they are written to a log; on until
    /// switched off.
    static var masksLogSecrets: Bool {
        get { defaults.object(forKey: "browserMasksLogSecrets") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "browserMasksLogSecrets") }
    }

    /// Glance browser's panel opens by itself when Claude or a test opens a page (Settings → Browser); on until
    /// switched off.
    static var showsAgentBrowser: Bool {
        get { defaults.object(forKey: "agentBrowserAutoShow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "agentBrowserAutoShow") }
    }

    /// Studio's shells get PW_TEST_CONNECT_WS_ENDPOINT, so Playwright tests run in the Glance browser; on until switched
    /// off. Takes effect for terminals opened after the change.
    static var testsInAgentBrowser: Bool {
        get { defaults.object(forKey: "agentBrowserTests") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "agentBrowserTests") }
    }

    /// Glance browser quits after 5 minutes with no client, no page and the panel hidden; on until switched off.
    static var agentBrowserQuitsWhenIdle: Bool {
        get { defaults.object(forKey: "agentBrowserIdleQuit") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "agentBrowserIdleQuit") }
    }

    /// A plain tab's configuration: the Browser's store, and Safari's user agent so sites serve their full app.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = StudioWebView.safariApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }

    static func recordVisit(_ url: URL) {
        guard let history else { return }
        Task.detached(priority: .utility) { try? history.record(url, title: nil, at: Date()) }
    }

    static func recordTitle(_ title: String, for url: URL) {
        guard let history else { return }
        Task.detached(priority: .utility) { try? history.setTitle(title, for: url) }
    }

    static func recent(limit: Int) async -> [GlanceCore.HistoryEntry] {
        guard let history else { return [] }
        return await Task.detached(priority: .userInitiated) { (try? history.recent(limit: limit)) ?? [] }.value
    }

    static func clearHistory() {
        guard let history else { return }
        Task.detached(priority: .utility) { try? history.clear() }
    }

    /// Every site's cookies and storage in the Browser, Slack's and Atlassian's stores too; open pages reload, Slack
    /// workspaces and Atlassian sign-ins are checked again.
    static func clearSiteData() {
        let stores = [dataStore, WKWebsiteDataStore(forIdentifier: SlackSessions.dataStoreID),
                      AtlassianSessions.shared.dataStore]
        let group = DispatchGroup()
        for store in stores {
            group.enter()
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                BrowserTabController.all.forEach { $0.webView?.reload() }
                SlackSessions.shared.store.workspaces.forEach { SlackSessions.shared.reload(teamID: $0.teamID) }
                AtlassianSessions.shared.store.sites.forEach { AtlassianSessions.shared.refresh($0.id) }
            }
        }
    }
}
