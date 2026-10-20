import AppKit
import Combine
import GlanceCore
import GlanceKit

/// What the Glance browser panel shows (spec 2026-10-14-agent-browser-design.md): every page of every broker browser,
/// watched over CDP; the followed page's screencast; its viewport following the panel's size (Claude's pages only);
/// the user's mouse and keys while they take over; screenshots.
@MainActor
final class AgentBrowserModel: ObservableObject {
    static let shared = AgentBrowserModel()

    struct Page: Identifiable, Equatable {
        let id: String // CDP targetId
        let browserId: String
        let kind: AgentBrowserEvent.Kind
        let version: String
        var title: String
        var url: String
    }

    /// The panel's page size: its own size, or a fixed device size (letterboxed).
    enum Viewport: Hashable {
        case fit
        case fixed(width: Int, height: Int)

        static let presets: [(String, Viewport)] = [
            ("Desktop · 1280 × 800", .fixed(width: 1280, height: 800)),
            ("Tablet · 768 × 1024", .fixed(width: 768, height: 1024)),
            ("Phone · 390 × 844", .fixed(width: 390, height: 844)),
        ]
    }

    @Published private(set) var pages: [Page] = []
    @Published private(set) var followedId: String?
    /// The user picked a page from the Pages menu: stay on it until another page opens.
    @Published private(set) var pinned = false
    @Published private(set) var frame: CGImage?
    /// The followed page's size in CSS pixels (from the screencast's metadata).
    @Published private(set) var pageSize: CGSize = .zero
    @Published private(set) var lastFrameAt: Date?
    @Published var takingOver = false
    @Published var viewport: Viewport = .fit { didSet { applyViewport() } }
    @Published private(set) var toast: String?

    /// Opens the panel when a page appears (Settings → Browser).
    var onPageOpened: (() -> Void)?

    let broker = AgentBrowserBroker.shared
    private var clients: [String: CDPClient] = [:] // browserId → client
    private var session: (targetId: String, sessionId: String, client: CDPClient)?
    private var viewSize: CGSize = .zero
    private var viewScale: CGFloat = 2
    private var metricsWork: DispatchWorkItem?
    private var brokerWatch: Any?

    var followed: Page? { pages.first { $0.id == followedId } }

    private init() {
        brokerWatch = broker.$browsers.sink { [weak self] browsers in
            MainActor.assumeIsolated { self?.sync(browsers) }
        }
    }

    // MARK: Browsers and pages

    private func sync(_ browsers: [AgentBrowserBroker.Browser]) {
        for (id, client) in clients where !browsers.contains(where: { $0.id == id }) {
            client.close()
            clients[id] = nil
            pages.removeAll { $0.browserId == id }
        }
        for browser in browsers where clients[browser.id] == nil {
            connect(browser)
        }
        if followedId != nil, followed == nil { follow(pages.last?.id, pin: false) }
    }

    private func connect(_ browser: AgentBrowserBroker.Browser) {
        Task { [weak self] in
            guard let self else { return }
            // The browser's DevTools server can take a moment after launchServer returns.
            var client: CDPClient?
            for _ in 0..<20 {
                client = try? await CDPClient.connect(port: browser.cdpPort)
                if client != nil { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let client, self.broker.browsers.contains(where: { $0.id == browser.id }) else { client?.close(); return }
            self.clients[browser.id] = client
            client.onEvent = { [weak self] method, params, sessionId in
                self?.handle(method, params, sessionId: sessionId, browser: browser)
            }
            client.onClose = { [weak self] in
                guard let self else { return }
                self.clients[browser.id] = nil
                self.pages.removeAll { $0.browserId == browser.id }
                if self.followed == nil { self.follow(self.pages.last?.id, pin: false) }
            }
            _ = try? await client.send("Target.setDiscoverTargets", ["discover": true])
        }
    }

    private func handle(_ method: String, _ params: JSONValue, sessionId: String?, browser: AgentBrowserBroker.Browser) {
        switch method {
        case "Target.targetCreated":
            guard let info = params["targetInfo"], info["type"]?.string == "page", let id = info["targetId"]?.string else { return }
            pages.append(Page(id: id, browserId: browser.id, kind: browser.kind, version: browser.version,
                              title: info["title"]?.string ?? "", url: info["url"]?.string ?? ""))
            follow(id, pin: false)
            onPageOpened?()
        case "Target.targetInfoChanged":
            guard let info = params["targetInfo"], let id = info["targetId"]?.string,
                  let index = pages.firstIndex(where: { $0.id == id }) else { return }
            let url = info["url"]?.string ?? pages[index].url
            let navigated = url != pages[index].url
            pages[index].title = info["title"]?.string ?? pages[index].title
            pages[index].url = url
            if navigated, !pinned, followedId != id { follow(id, pin: false) }
        case "Target.targetDestroyed":
            guard let id = params["targetId"]?.string else { return }
            pages.removeAll { $0.id == id }
            if followedId == id { follow(pages.last?.id, pin: false) }
        case "Page.screencastFrame":
            guard let sessionId, sessionId == session?.sessionId else { return }
            if let ack = params["sessionId"] {
                session?.client.post("Page.screencastFrameAck", ["sessionId": ack], session: sessionId)
            }
            guard let base64 = params["data"]?.string, let data = Data(base64Encoded: base64),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let metadata = params["metadata"]
            if case .number(let width)? = metadata?["deviceWidth"], case .number(let height)? = metadata?["deviceHeight"] {
                pageSize = CGSize(width: width, height: height)
            }
            frame = image
            lastFrameAt = Date()
        default:
            break
        }
    }

    /// Shows `id` in the panel: the old page's screencast stops, the new one's starts.
    func follow(_ id: String?, pin: Bool) {
        pinned = pin && id != nil
        guard id != followedId || session == nil else { return }
        if let old = session {
            old.client.post("Page.stopScreencast", session: old.sessionId)
            old.client.post("Target.detachFromTarget", ["sessionId": .string(old.sessionId)])
            session = nil
        }
        followedId = id
        frame = nil
        pageSize = .zero
        guard let id, let page = pages.first(where: { $0.id == id }), let client = clients[page.browserId] else { return }
        Task {
            guard let attached = try? await client.send("Target.attachToTarget", ["targetId": .string(id), "flatten": true]),
                  let sessionId = attached["sessionId"]?.string, followedId == id else { return }
            session = (id, sessionId, client)
            _ = try? await client.send("Page.enable", session: sessionId)
            applyViewport(now: true)
            startScreencast()
        }
    }

    private func startScreencast() {
        guard let session else { return }
        let pixels = CGSize(width: max(viewSize.width, 320) * viewScale, height: max(viewSize.height, 200) * viewScale)
        session.client.post("Page.startScreencast", ["format": "jpeg", "quality": 70,
                                                     "maxWidth": .number(Double(Int(pixels.width))),
                                                     "maxHeight": .number(Double(Int(pixels.height)))],
                            session: session.sessionId)
    }

    // MARK: Size

    /// The page view's size changed (the panel was resized).
    func viewResized(_ size: CGSize, scale: CGFloat) {
        guard size != viewSize || scale != viewScale else { return }
        viewSize = size
        viewScale = scale
        metricsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.applyViewport()
                self?.startScreencast() // a new max size
            }
        }
        metricsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Claude's pages take the panel's size (or a preset); test pages keep the size their test gave them.
    private func applyViewport(now: Bool = false) {
        guard let session, let page = followed, page.kind == .claude, viewSize.width > 0 else { return }
        let metrics: (width: Int, height: Int, scale: Double)
        switch viewport {
        case .fit: metrics = AgentBrowserFit.metrics(view: viewSize, scale: viewScale)
        case .fixed(let width, let height): metrics = (width, height, Double(viewScale))
        }
        session.client.post("Emulation.setDeviceMetricsOverride",
                            ["width": .number(Double(metrics.width)), "height": .number(Double(metrics.height)),
                             "deviceScaleFactor": .number(metrics.scale), "mobile": false],
                            session: session.sessionId)
    }

    // MARK: Taking over

    func mouse(_ type: String, at point: CGPoint, button: String = "none", clicks: Int = 0, modifiers: Int = 0) {
        guard takingOver, let session else { return }
        session.client.post("Input.dispatchMouseEvent",
                            ["type": .string(type), "x": .number(point.x), "y": .number(point.y), "button": .string(button),
                             "clickCount": .number(Double(clicks)), "modifiers": .number(Double(modifiers))],
                            session: session.sessionId)
    }

    func wheel(at point: CGPoint, dx: CGFloat, dy: CGFloat) {
        guard takingOver, let session else { return }
        session.client.post("Input.dispatchMouseEvent",
                            ["type": "mouseWheel", "x": .number(point.x), "y": .number(point.y),
                             "deltaX": .number(-dx), "deltaY": .number(-dy)], session: session.sessionId)
    }

    func key(_ params: JSONValue) {
        guard takingOver, let session else { return }
        session.client.post("Input.dispatchKeyEvent", params, session: session.sessionId)
    }

    func insertText(_ text: String) {
        guard takingOver, let session else { return }
        session.client.post("Input.insertText", ["text": .string(text)], session: session.sessionId)
    }

    // MARK: Screenshot

    /// The page at full resolution → ~/Desktop and the clipboard.
    func screenshot() {
        guard let session else { return }
        Task {
            guard let result = try? await session.client.send("Page.captureScreenshot", ["format": "png"], session: session.sessionId),
                  let base64 = result["data"]?.string, let data = Data(base64Encoded: base64) else {
                show("Couldn't take a screenshot")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
            let file = desktop.appendingPathComponent("Claude browser \(formatter.string(from: Date())).png")
            do {
                try data.write(to: file)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([file as NSURL])
                NSPasteboard.general.setData(data, forType: .png)
                show("Saved to Desktop and copied")
            } catch {
                show("Couldn't save the screenshot")
            }
        }
    }

    private func show(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
