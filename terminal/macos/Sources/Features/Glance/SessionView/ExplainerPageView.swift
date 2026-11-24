import AppKit
import GlanceCore
import GlanceKit
import SwiftUI
import WebKit

/// A page Claude wrote, in the sandbox from `ExplainerPageWeb`. Everything around it is native; the page itself is
/// treated as untrusted (spec 2026-11-03-explainer-mode-design.md §8).
struct ExplainerPageView: NSViewRepresentable {
    let key: String
    let page: ExplainerPage
    let dark: Bool
    let onMessage: (ExplainerBridge.Message) -> Void
    let onUnavailable: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(key: key, onMessage: onMessage, onUnavailable: onUnavailable) }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.load(page: page, dark: dark, into: container)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.theme(dark: dark)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let key: String
        var onMessage: (ExplainerBridge.Message) -> Void
        let onUnavailable: (String) -> Void
        private var web: WKWebView?
        private var html: String?
        private var dark = true
        private var loaded = false
        private var closed = false
        private var reloaded = false

        init(key: String, onMessage: @escaping (ExplainerBridge.Message) -> Void, onUnavailable: @escaping (String) -> Void) {
            self.key = key
            self.onMessage = onMessage
            self.onUnavailable = onUnavailable
        }

        func load(page: ExplainerPage, dark: Bool, into container: NSView) {
            self.dark = dark
            Task { [weak self, weak container] in
                guard let self else { return }
                do {
                    let configuration = try await ExplainerPageWeb.configuration(handler: WeakHandler(self))
                    let css = try ExplainerPageWeb.css()
                    guard !self.closed, let container else { return }
                    let view = ExplainerWebView(frame: container.bounds, configuration: configuration)
                    view.autoresizingMask = [.width, .height]
                    view.setValue(false, forKey: "drawsBackground")
                    view.navigationDelegate = self
                    container.addSubview(view)
                    self.web = view
                    let html = page.document(css: css, dark: self.dark)
                    self.html = html
                    view.loadHTMLString(html, baseURL: nil)
                    ExplainerPageRegistry.shared.add(self)
                } catch {
                    self.onUnavailable((error as? ExplainerPageWeb.Unavailable)?.reason ?? error.localizedDescription)
                }
            }
        }

        func close() {
            closed = true
            ExplainerPageRegistry.shared.remove(key)
            web?.configuration.userContentController.removeAllScriptMessageHandlers()
            web?.stopLoading()
            web = nil
        }

        func theme(dark next: Bool) {
            guard next != dark else { return }
            dark = next
            call("window.__explainer?.theme('\(next ? "dark" : "light")')")
        }

        func time(beat: Int, at time: Double, of duration: Double) {
            call("window.__explainer?.time(\(beat), \(time), \(duration))")
        }

        func rest() {
            call("window.__explainer?.stop()")
        }

        private func call(_ script: String) {
            web?.evaluateJavaScript(script + "; 0", in: nil, in: ExplainerPageWeb.world) { _ in }
        }

        nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard message.world.name == ExplainerPageWeb.world.name, let parsed = ExplainerBridge.parse(message.body) else { return }
                if case .beat(_, let top) = parsed { follow(top: top) }
                onMessage(parsed)
            }
        }

        /// While the voice plays, the view keeps the beat being said in sight, unless the reader scrolled in the last 4 s.
        private func follow(top: Double) {
            guard let web, let scroller = web.enclosingScrollView, let document = scroller.documentView,
                  Date().timeIntervalSince(ExplainerPageRegistry.shared.lastWheel) > 4 else { return }
            let target = web.convert(CGPoint(x: 0, y: top), to: document)
            let clip = scroller.contentView
            let highest = max(0, document.frame.height - clip.bounds.height)
            let y = document.isFlipped ? min(max(0, target.y - 24), highest) : min(max(0, target.y - clip.bounds.height + 24), highest)
            let origin = CGPoint(x: clip.bounds.origin.x, y: y)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                clip.setBoundsOrigin(origin)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    clip.animator().setBoundsOrigin(origin)
                }
            }
            scroller.reflectScrolledClipView(clip)
        }

        nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            MainActor.assumeIsolated {
                let allowed = ExplainerPageWeb.allows(navigation: action, loaded: loaded)
                if allowed { loaded = true }
                decisionHandler(allowed ? .allow : .cancel)
            }
        }

        /// The page's process died: load it once more, then leave it.
        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated {
                guard !reloaded, let html else { return }
                reloaded = true
                loaded = false
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }
}

/// Up-and-down scrolling goes to the timeline around the page; only sideways stays here.
private final class ExplainerWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The content controller keeps its handler alive; this keeps the coordinator from being kept with it.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Which pages are on screen, so the voice's position reaches the one it's for. A page scrolled away has no view to
/// tell; the voice goes on, and it catches up when the page comes back.
@MainActor
final class ExplainerPageRegistry {
    static let shared = ExplainerPageRegistry()

    private final class Entry {
        weak var page: ExplainerPageView.Coordinator?
        init(_ page: ExplainerPageView.Coordinator) { self.page = page }
    }

    private var pages: [String: Entry] = [:]
    /// When the reader last scrolled: the voice's follow leaves them alone for a while.
    private(set) var lastWheel = Date.distantPast
    private var wheelMonitor: Any?

    private init() {
        let player = ExplainerVoicePlayer.shared
        player.onPosition = { [weak self] page, beat, time, duration in
            self?.pages[page]?.page?.time(beat: beat, at: time, of: duration)
        }
        player.onStop = { [weak self] page in
            self?.pages[page]?.page?.rest()
        }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.lastWheel = Date() }
            return event
        }
    }

    func add(_ page: ExplainerPageView.Coordinator) { pages[page.key] = Entry(page) }
    func remove(_ key: String) { pages[key] = nil }
}
