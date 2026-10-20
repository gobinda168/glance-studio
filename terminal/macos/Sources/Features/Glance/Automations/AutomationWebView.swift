import AppKit
import Combine
import GlanceCore
import GlanceKit
import WebKit

/// An automation's own UI in its tab (spec 2026-10-09-automations-design.md, "Web UI contract"): ui/index.html from
/// `glance-automation://<id>/`, with Glance's tokens.css and glance.js, and no network (the CSP on every response, a
/// content rule list, no WebRTC, navigation kept inside the package). glance.js talks to Studio through the `glance`
/// handler: run, cancel, the run list, state, links and Finder; the runs the page starts tell it each step, output and
/// the end. One per automation tab, made the first time the tab shows the UI. If the content rules can't be built the
/// page is not loaded at all: the tab says so.
@MainActor
final class AutomationWebHost: NSObject, WKNavigationDelegate, WKUIDelegate {
    let id: String
    let view: StudioWebView
    /// A run the page asked for needs this version approved first: the tab shows its inline approval.
    var onNeedsApproval: (([String: AutomationValue]) -> Void)?

    /// Before any page script: the WebRTC classes are gone (ICE and STUN reach the network around the CSP and the
    /// rule list) and can't be put back. Runs in every frame.
    static let noWebRTC = """
    (() => {
      for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCSessionDescription",
                          "RTCIceCandidate"]) {
        try { delete window[name]; } catch (error) {}
        try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); }
        catch (error) {}
      }
    })();
    """

    private let contentController = WKUserContentController()
    /// The version the page was loaded with: a save that changes it reloads the page.
    private var loadedVersion: Int?
    /// Runs this page started: their lines go to the page.
    private var pageRuns: Set<String> = []
    private var dark = false
    private var rulesReady = false
    private var tornDown = false
    /// Why the page isn't loaded (the content rules didn't compile); the tab shows it instead.
    private var failure: String?
    /// When the page's process last died (`webViewWebContentProcessDidTerminate`).
    private var lastTerminated: Date?
    private static let crashWindow: TimeInterval = 10
    private var activityWatch: AnyCancellable?
    private var appearanceWatch: NSKeyValueObservation?

    init(id: String) {
        self.id = id
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(AutomationSchemeHandler(owner: id), forURLScheme: AutomationWeb.scheme)
        // Nothing a page stores outlives its tab: glance.state is where a UI keeps things.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = contentController
        view = StudioWebView(frame: .zero, configuration: configuration)
        super.init()
        contentController.addScriptMessageHandler(AutomationBridgeHandler(self), contentWorld: .page,
                                                  name: AutomationBridge.handlerName)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        #if DEBUG
        view.isInspectable = true
        #endif
        dark = Self.isDark(view.effectiveAppearance)
        appearanceWatch = view.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appearanceChanged() } }
        }
        activityWatch = AutomationEngine.shared.activity.sink { [weak self] activity in
            MainActor.assumeIsolated { self?.heard(activity) }
        }
        // The content rules first (a few milliseconds, once), then the page.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "glance-automation-offline", encodedContentRuleList: AutomationWeb.blockRules
        ) { [weak self] list, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let list {
                        self.contentController.add(list)
                    } else {
                        // Without the rules the page would have one lock fewer: it doesn't load.
                        let why = error?.localizedDescription ?? "no reason given"
                        NSLog("Glance Studio: the offline rules for automation UIs didn't compile (\(why)); "
                            + "\(self.id)'s page is not loaded")
                        self.failure = "Glance couldn't turn off this page's network access (\(why)), so the page "
                            + "isn't shown. Restart Glance Studio; if this stays, update it."
                    }
                    self.rulesReady = true
                    self.load()
                }
            }
        }
    }

    /// The tab closed: the page stops (its process, its timers, its pending calls) and the host answers nothing more.
    func tearDown() {
        tornDown = true
        activityWatch = nil
        appearanceWatch = nil
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.load(URLRequest(url: URL(string: "about:blank")!))
        contentController.removeAllUserScripts()
        contentController.removeScriptMessageHandler(forName: AutomationBridge.handlerName, contentWorld: .page)
        onNeedsApproval = nil
        view.removeFromSuperview()
    }

    /// (Re)loads ui/index.html with this version's glance.automation.
    func load() {
        guard rulesReady, !tornDown else { return }
        if let failure { return showFailure(failure) }
        guard let manifest = AutomationEngine.shared.entry(id)?.manifest else { return }
        loadedVersion = manifest.version
        pageRuns.removeAll()
        contentController.removeAllUserScripts()
        contentController.addUserScript(WKUserScript(source: Self.noWebRTC, injectionTime: .atDocumentStart,
                                                     forMainFrameOnly: false))
        let boot = AutomationBridge.boot(manifest, dark: dark).json
        contentController.addUserScript(WKUserScript(source: "window.__glanceBoot = \(boot);",
                                                     injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let script = try? String(contentsOf: Resources.automationScript, encoding: .utf8) {
            contentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        }
        view.load(URLRequest(url: AutomationWeb.pageURL(id)))
    }

    /// The library changed: a new version of this automation reloads its page.
    func entriesChanged() {
        guard failure == nil, rulesReady,
              let version = AutomationEngine.shared.entry(id)?.manifest?.version, version != loadedVersion else {
            return
        }
        load()
    }

    /// A page of plain text, no script and no loads: the tab's reason for not showing the automation's page.
    private func showFailure(_ text: String) {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let page = """
        <!doctype html><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>:root { color-scheme: light dark; } body { font: 13px/1.5 -apple-system, sans-serif; margin: 0;
        padding: 32px; max-width: 480px; }</style>
        <body><p>\(escaped)</p></body>
        """
        view.loadHTMLString(page, baseURL: nil)
    }

    // MARK: glance.js

    /// A call from the page's own main frame, answered as JSON text (or refused with a reason).
    func received(_ message: WKScriptMessage, reply: @escaping @MainActor (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        guard message.webView === view, message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              case .package(let owner, _) = AutomationWeb.route(url), owner == id,
              origin.protocol.lowercased() == AutomationWeb.scheme, origin.host.lowercased() == id else {
            return reply(nil, "This page isn't \(id)'s.")
        }
        guard let text = message.body as? String else { return reply(nil, "glance.js sends its calls as JSON text.") }
        let request: AutomationBridgeRequest
        switch AutomationBridge.decode(text) {
        case .failure(let error): return reply(nil, error.message)
        case .success(let decoded): request = decoded
        }
        // A link from a script may need the user's answer first: the reply waits for it.
        if case .openURL(let text) = request {
            return AutomationLinkOpener.openFromPage(text, from: view.window, roots: allowedRoots()) { reason in
                reason == nil ? reply("null", nil) : reply(nil, reason)
            }
        }
        var replay: (ref: AutomationRunRef, lines: [RunLogLine])?
        switch perform(request, replay: &replay) {
        case .success(let value): reply(value.json, nil)
        case .failure(let error): reply(nil, error.message)
        }
        // The lines a new run wrote before the page had its id, right after the reply (glance.js keeps lines of a
        // run it doesn't know yet, so the order between them doesn't matter).
        if let replay { replay.lines.forEach { forward(replay.ref, $0.event) } }
    }

    private func perform(_ request: AutomationBridgeRequest,
                         replay: inout (ref: AutomationRunRef, lines: [RunLogLine])?)
        -> Result<AutomationValue, AutomationBridgeError> {
        let engine = AutomationEngine.shared
        guard let entry = engine.entry(id) else {
            return .failure(AutomationBridgeError("This automation was deleted."))
        }
        switch request {
        case .run(let inputs):
            if engine.isRunning(id) { return .failure(AutomationBridgeError("\(entry.name) is already running.")) }
            // The page's inputs are checked against the manifest before the engine sees them: each field's reason.
            if let manifest = entry.manifest {
                let problems = manifest.resolveInputs(inputs).problems
                if !problems.isEmpty { return .failure(AutomationBridgeError(AutomationCheck.report(problems))) }
            }
            switch engine.run(id, inputs: inputs) {
            case .started(let ref):
                pageRuns.insert(ref.run)
                replay = (ref, engine.log(ref))
                return .success(.object(["runID": .string(ref.run)]))
            case .queued:
                return .failure(AutomationBridgeError("\(entry.name) is busy; this run waits its turn."))
            case .refused(let reason):
                if entry.problems.isEmpty, !entry.approval.isApproved { onNeedsApproval?(inputs) }
                return .failure(AutomationBridgeError(reason))
            }
        case .cancel(let run):
            let ref = AutomationRunRef(automation: id, run: run)
            guard engine.live.contains(where: { $0.ref == ref }) else {
                return .failure(AutomationBridgeError("That run isn't going."))
            }
            engine.cancel(ref)
            return .success(.null)
        case .runs(let limit):
            return .success(AutomationBridge.runs(engine.runs(id, limit: limit)))
        case .stateGet(let key):
            return .success(AutomationUIState.get(try? Data(contentsOf: engine.stateFile(id)), key: key))
        case .stateSet(let key, let value):
            let file = engine.stateFile(id)
            switch AutomationUIState.set(try? Data(contentsOf: file), key: key, value: value) {
            case .failure(let error):
                return .failure(error)
            case .success(let data):
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try data.write(to: file, options: .atomic)
                    return .success(.null)
                } catch {
                    return .failure(AutomationBridgeError("Couldn't save glance.state: \(error.localizedDescription)"))
                }
            }
        case .openURL:
            return .failure(AutomationBridgeError("glance.openURL is answered by received()."))
        case .reveal(let path):
            // Absolute, "~" or "~/…" (not another user's home), or inside the automation's folder; and in all cases
            // inside the automation's folders. The answer is the same whether or not the path exists.
            let target = path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
                ? path : engine.library.folder(id).appendingPathComponent(path).path
            guard let absolute = AutomationLinkOpener.insideRoots(target, roots: allowedRoots()) else {
                return .failure(AutomationBridgeError(AutomationLinkOpener.outsideFolders))
            }
            guard FileManager.default.fileExists(atPath: absolute) else {
                return .failure(AutomationBridgeError("There's nothing at \(path)."))
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolute)])
            return .success(.null)
        }
    }

    /// The folders a page may open or reveal files in: the automation's package, the whole library, and the folders
    /// its permissions list.
    private func allowedRoots() -> [String] {
        let library = AutomationEngine.shared.library
        var roots = [library.folder(id).path, library.root.path]
        for folder in AutomationEngine.shared.entry(id)?.manifest?.permissions.folders ?? []
        where folder.hasPrefix("/") || folder == "~" || folder.hasPrefix("~/") {
            roots.append((folder as NSString).expandingTildeInPath)
        }
        return roots
    }

    private func heard(_ activity: AutomationActivity) {
        guard case .logged(let ref, let event) = activity, ref.automation == id else { return }
        forward(ref, event)
    }

    /// A line of a run the page started: a step or output event, or at run.end the `done` with every step's result.
    private func forward(_ ref: AutomationRunRef, _ event: RunLogEvent) {
        guard pageRuns.contains(ref.run) else { return }
        if case .runEnd(let status) = event {
            pageRuns.remove(ref.run)
            guard var record = RunLog.summarize(AutomationEngine.shared.log(ref), id: ref.run, live: false) else {
                return
            }
            record.status = status
            send(AutomationBridge.done(record))
        } else if let value = AutomationBridge.event(run: ref.run, event) {
            send(value)
        }
    }

    private func send(_ value: AutomationValue) {
        view.evaluateJavaScript("window.__glanceReceive && window.__glanceReceive(\(value.json))",
                                completionHandler: nil)
    }

    private func appearanceChanged() {
        let now = Self.isDark(view.effectiveAppearance)
        guard now != dark else { return }
        dark = now
        send(AutomationBridge.theme(dark: now))
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: Navigation

    /// The page stays in its package. A link out of it goes through Studio's routes (or the browser), never into
    /// the tab; anything else is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if case .package(let owner, _) = AutomationWeb.route(url), owner == id { return decisionHandler(.allow) }
        // The tab's own message page, when the automation's page isn't loaded.
        if failure != nil, url.absoluteString == "about:blank" { return decisionHandler(.allow) }
        // A click on a link goes through Studio's routes (a web page asks first); anything else off the package is
        // dropped.
        if action.navigationType == .linkActivated { openLink(url, from: webView) }
        decisionHandler(.cancel)
    }

    /// `target="_blank"` and window.open: the same routes; no pop-up windows.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target="_blank" and window.open: the same routes, the same question for a web page.
        if let url = action.request.url { openLink(url, from: webView) }
        return nil
    }

    private func openLink(_ url: URL, from webView: WKWebView) {
        AutomationLinkOpener.openFromPage(url.absoluteString, from: webView.window, roots: allowedRoots()) { _ in }
    }

    /// The page's process died: reload it, but not in a loop. A second crash within ten seconds of the last one shows
    /// the tab's message instead.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        if let last = lastTerminated, now.timeIntervalSince(last) < Self.crashWindow {
            NSLog("Glance Studio: \(id)'s page crashed twice in \(Int(Self.crashWindow)) seconds; not reloading")
            failure = "This page crashed twice in a row, so it isn't shown. Close the tab and open it again."
        }
        lastTerminated = now
        load()
    }
}

/// The `glance` handler, holding its host weakly (the content controller keeps its handlers alive).
@MainActor
private final class AutomationBridgeHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var host: AutomationWebHost?

    init(_ host: AutomationWebHost) {
        self.host = host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard let host else { return replyHandler(nil, "The automation's tab closed.") }
        host.received(message, reply: replyHandler)
    }
}
