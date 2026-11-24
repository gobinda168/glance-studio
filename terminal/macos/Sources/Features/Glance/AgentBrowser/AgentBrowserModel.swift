import AppKit
import ApplicationServices
import Combine
import GlanceCore
import GlanceKit

/// The pages open in the Glance browser's windows (spec 2026-10-14-agent-browser-design.md; real Chromium windows since
/// 2026-10-29), watched over CDP: they keep the broker from quitting idle, and a new one brings its window forward.
@MainActor
final class AgentBrowserModel: ObservableObject {
    static let shared = AgentBrowserModel()

    struct Page: Identifiable, Equatable {
        let id: String // CDP targetId
        let browserId: String
        var url: String
    }

    @Published private(set) var pages: [Page] = []

    /// A page opened in the browser `browserId` (Settings → Browser decides what happens).
    var onPageOpened: ((_ browserId: String) -> Void)?

    let broker = AgentBrowserBroker.shared
    private var clients: [String: CDPClient] = [:] // browserId → client
    private var brokerWatch: Any?
    private var sessionsWatch: Any?
    /// Blank pages (the new-tab window Chromium opens at start) that were there when Studio connected, per browser.
    private var startupBlanks: [String: Set<String>] = [:]
    /// Browsers whose first burst of targetCreated (everything already open) hasn't ended.
    private var discovering: Set<String> = []
    private var sweepScheduled = false

    private init() {
        brokerWatch = broker.$browsers.sink { [weak self] browsers in
            MainActor.assumeIsolated { self?.sync(browsers) }
        }
        sessionsWatch = AgentBrowserSessions.shared.$table.sink { [weak self] table in
            MainActor.assumeIsolated { self?.sessionsChanged(table) }
        }
    }

    // MARK: Windows of Claude's sessions (Command Center)

    /// Closes pages in Claude's browser (what a dead session left): nothing to do when the browser is gone.
    func close(targets: [String]) {
        guard !targets.isEmpty, let client = claudeClient() else { return }
        for target in targets { client.post("Target.closeTarget", ["targetId": .string(target)]) }
    }

    /// Makes `targetId` the active tab of its window and that window the browser's front one. Tabs open in the active
    /// window, so this comes before bringing the app forward. False when the page or its browser isn't known.
    @discardableResult
    func activate(targetId: String) async -> Bool {
        let browserId = pages.first { $0.id == targetId }?.browserId
        guard let client = browserId.flatMap({ clients[$0] }) ?? claudeClient() else { return false }
        return (try? await client.send("Target.activateTarget", ["targetId": .string(targetId)])) != nil
    }

    /// View → Glance Browser with no window left (the sweep or a closed session took the last one): a blank window.
    func openBlankWindowIfNone() {
        guard let browser = broker.browsers.first(where: { $0.kind == .claude }), let client = clients[browser.id],
              !pages.contains(where: { $0.browserId == browser.id }) else { return }
        client.post("Target.createTarget", ["url": "about:blank", "newWindow": true])
    }

    private func claudeClient() -> CDPClient? {
        broker.browsers.first { $0.kind == .claude }.flatMap { clients[$0.id] }
    }

    private static func isBlank(_ url: String) -> Bool {
        url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab") || url.hasPrefix("chrome://new-tab-page")
    }

    /// With a window for each session, the window Chromium opened at start has no owner and would stay for good (and
    /// keep the browser from quitting idle): once a session's first page exists, the blank pages that were open at the
    /// start and still belong to nobody are closed. Never a tab opened later.
    private func sessionsChanged(_ table: BrowserSessionTable) {
        guard !startupBlanks.isEmpty, !sweepScheduled, broker.launchedWithSessionWindows,
              table.clients.values.contains(where: { !$0.targets.isEmpty }) else { return }
        scheduleSweep()
    }

    private func scheduleSweep() {
        sweepScheduled = true
        Task { [weak self] in
            // A second session's page may be announced a moment after the first's.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.closeUnownedStartupPages()
        }
    }

    private func closeUnownedStartupPages() {
        sweepScheduled = false
        guard broker.launchedWithSessionWindows else { return }
        let table = AgentBrowserSessions.shared.table
        guard table.clients.values.contains(where: { !$0.targets.isEmpty }) else { return }
        // A session whose tool call is running and has no page yet is opening its window: not now.
        if table.clients.values.contains(where: { $0.inFlight > 0 && $0.targets.isEmpty }) { return scheduleSweep() }
        for (browserId, ids) in startupBlanks {
            let stale = ids.filter { id in
                guard let page = pages.first(where: { $0.id == id }) else { return false }
                return Self.isBlank(page.url) && table.client(owning: id) == nil
            }
            startupBlanks[browserId] = nil
            if let client = clients[browserId] {
                for id in stale { client.post("Target.closeTarget", ["targetId": .string(id)]) }
            }
        }
    }

    private func sync(_ browsers: [AgentBrowserBroker.Browser]) {
        for (id, client) in clients where !browsers.contains(where: { $0.id == id }) {
            client.close()
            clients[id] = nil
            pages.removeAll { $0.browserId == id }
            startupBlanks[id] = nil
            discovering.remove(id)
        }
        for browser in browsers where clients[browser.id] == nil {
            connect(browser)
        }
    }

    private func connect(_ browser: AgentBrowserBroker.Browser) {
        Task { [weak self] in
            guard let self else { return }
            // The browser's DevTools server can take a moment after it starts.
            var client: CDPClient?
            for _ in 0..<20 {
                client = try? await CDPClient.connect(port: browser.cdpPort)
                if client != nil { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let client, self.broker.browsers.contains(where: { $0.id == browser.id }) else { client?.close(); return }
            self.clients[browser.id] = client
            self.discovering.insert(browser.id)
            client.onEvent = { [weak self] method, params, _ in
                self?.handle(method, params, browser: browser)
            }
            client.onClose = { [weak self] in
                self?.clients[browser.id] = nil
                self?.pages.removeAll { $0.browserId == browser.id }
                self?.startupBlanks[browser.id] = nil
                self?.discovering.remove(browser.id)
            }
            // Everything already open is reported before the reply; what comes after is new.
            _ = try? await client.send("Target.setDiscoverTargets", ["discover": true])
            self.discovering.remove(browser.id)
        }
    }

    private func handle(_ method: String, _ params: JSONValue, browser: AgentBrowserBroker.Browser) {
        switch method {
        case "Target.targetCreated":
            guard let info = params["targetInfo"], info["type"]?.string == "page", let id = info["targetId"]?.string,
                  !pages.contains(where: { $0.id == id }) else { return }
            let url = info["url"]?.string ?? ""
            pages.append(Page(id: id, browserId: browser.id, url: url))
            if browser.kind == .claude, discovering.contains(browser.id), Self.isBlank(url) { startupBlanks[browser.id, default: []].insert(id) }
            onPageOpened?(browser.id)
        case "Target.targetInfoChanged":
            guard let info = params["targetInfo"], let id = info["targetId"]?.string,
                  let index = pages.firstIndex(where: { $0.id == id }), let url = info["url"]?.string else { return }
            let opened = AgentBrowserPageOpening.opens(from: pages[index].url, to: url)
            pages[index].url = url
            if opened { onPageOpened?(browser.id) }
        case "Target.targetDestroyed":
            guard let id = params["targetId"]?.string else { return }
            pages.removeAll { $0.id == id }
        default:
            break
        }
    }
}

/// The Glance browser's window: Chromium's own, so Studio only brings it forward.
@MainActor
enum AgentBrowserWindow {
    /// "Show Glance Browser" asked while it wasn't running: activate it once it is.
    private static var showWhenReady = false
    private static var watch: Any?

    /// A session's window ("Show browser"): its tab becomes the active one, then the browser comes forward. Tabs open in
    /// the active window, so the activation is first. Without the browser running this is `show()`.
    static func show(targetId: String) {
        let broker = AgentBrowserBroker.shared
        guard broker.engine == .chromium else { return }
        guard let app = application(of: broker.browsers.first { $0.kind == .claude }) else { return show() }
        Task {
            await AgentBrowserModel.shared.activate(targetId: targetId)
            app.activate(options: [])
        }
    }

    /// View → Glance Browser and the palette: the window comes forward with focus; starts the browser if needed.
    static func show() {
        let broker = AgentBrowserBroker.shared
        guard broker.engine == .chromium else { return } // Lightpanda has no window
        if let app = application(of: broker.browsers.first { $0.kind == .claude }) {
            AgentBrowserModel.shared.openBlankWindowIfNone()
            app.activate(options: [])
            return
        }
        showWhenReady = true
        watch = watch ?? broker.$browsers.sink { browsers in
            MainActor.assumeIsolated {
                guard showWhenReady, let app = application(of: browsers.first { $0.kind == .claude }) else { return }
                showWhenReady = false
                app.activate(options: [])
            }
        }
        if case .failed = broker.state { broker.restart() } else { broker.start() }
    }

    /// A page opened: its browser's front window rises above other windows without taking focus from the terminal
    /// Claude runs in (an Accessibility raise; without Studio's Accessibility access the window stays where it is).
    /// Not with a window for each session: a new window appears by itself, and the front one isn't the page's.
    static func raise(browserId: String) {
        guard !AgentBrowserSessions.shared.sessionWindows, AXIsProcessTrusted(),
              let browser = AgentBrowserBroker.shared.browsers.first(where: { $0.id == browserId }), browser.pid > 0
        else { return }
        let app = AXUIElementCreateApplication(browser.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], let front = windows.first else { return }
        AXUIElementPerformAction(front, kAXRaiseAction as CFString)
    }

    private static func application(of browser: AgentBrowserBroker.Browser?) -> NSRunningApplication? {
        guard let browser, browser.pid > 0 else { return nil }
        return NSRunningApplication(processIdentifier: browser.pid)
    }
}
