import AppKit
import GlanceCore
import WebKit

/// A Browser tab's page floating above everything else (the top bar's PiP button): the same live page, so a call
/// keeps going. The window stays above every app and Space, drags from its top strip and resizes from any edge. Its
/// top strip has buttons to switch between the mobile and desktop site, to fill the screen (and back) and to attach the
/// page back to its tab; closing the window attaches it back too, so a call is never hung up by accident. The page
/// floats on its mobile site (Settings → Browser), unless reloading it would end a call or restart a playing video.
@MainActor
final class FloatingCallWindow: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 440, height: 300)

    private let panel: NSPanel
    private let webView: WKWebView
    private let attachBack: () -> Void
    /// The window's frame before it filled the screen; nil while it's small.
    private var smallFrame: NSRect?
    private var expandButton: NSButton?
    private var siteButton: NSButton?
    /// Whether the page is on its mobile site (the iPhone user agent).
    private var showsMobile = false

    /// Takes `webView` out of its tab and floats it. `attachBack` runs when the user asks for the page back.
    init(webView: WKWebView, title: String, attachBack: @escaping () -> Void) {
        self.webView = webView
        self.attachBack = attachBack
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 280, height: 190)
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.addTitlebarAccessoryViewController(accessory())

        let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        panel.contentView = container
        place()
        panel.orderFrontRegardless()
        if BrowserData.floatsMobileSite { whenIdle { [weak self] in self?.showMobile(true) } }
    }

    /// Ends the window: the page goes back to its tab (on its desktop site again), or the tab is closing.
    func dismiss(backToTab: Bool = false) {
        panel.delegate = nil
        panel.close()
        guard backToTab, showsMobile else { return }
        // Desktop from the next page on; reloaded now unless that ends a call or restarts a video.
        showsMobile = false
        webView.customUserAgent = nil
        whenIdle { [webView] in webView.reload() }
    }

    /// Runs `body` when the page has no call (camera or microphone) and no playing media, which a reload would end.
    private func whenIdle(_ body: @escaping @MainActor () -> Void) {
        guard webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { return }
        Task { @MainActor [webView] in
            if await webView.requestMediaPlaybackState() != .playing { body() }
        }
    }

    /// Switches the page to its mobile or desktop site and reloads it.
    private func showMobile(_ mobile: Bool) {
        showsMobile = mobile
        webView.customUserAgent = mobile ? StudioWebView.iPhoneUserAgent : nil
        webView.reload()
        let help = mobile ? "Show the desktop site" : "Show the mobile site"
        siteButton?.image = NSImage(systemSymbolName: mobile ? "desktopcomputer" : "iphone", accessibilityDescription: help)
        siteButton?.toolTip = help
    }

    /// Bottom-right of the screen under the mouse, clear of the Dock.
    private func place() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return panel.center() }
        panel.setFrameOrigin(NSPoint(x: area.maxX - Self.size.width - 20, y: area.minY + 20))
    }

    /// The top strip's buttons, at its trailing edge.
    private func accessory() -> NSTitlebarAccessoryViewController {
        let expand = button("arrow.up.left.and.arrow.down.right", "Fill the screen", #selector(toggleFill))
        expandButton = expand
        let site = button("iphone", "Show the mobile site", #selector(toggleSite))
        siteButton = site
        let stack = NSStackView(views: [site, expand, button("pip.exit", "Attach back to the tab", #selector(attach))])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 10)
        let controller = NSTitlebarAccessoryViewController()
        controller.view = stack
        controller.layoutAttribute = .trailing
        return controller
    }

    private func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = help
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    /// Fills the screen the window is on (menu bar and Dock stay), and back to where it was. It still floats, so
    /// the call stays on top while full.
    @objc private func toggleFill() {
        if let small = smallFrame {
            panel.setFrame(small, display: true, animate: true)
            smallFrame = nil
        } else if let area = (panel.screen ?? NSScreen.main)?.visibleFrame {
            smallFrame = panel.frame
            panel.setFrame(area, display: true, animate: true)
        }
        let full = smallFrame != nil
        let help = full ? "Back to the small window" : "Fill the screen"
        let symbol = full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        expandButton?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        expandButton?.toolTip = help
    }

    @objc private func toggleSite() { showMobile(!showsMobile) }

    @objc private func attach() { attachBack() }

    // The close button attaches the page back instead of closing: the call goes on in its tab.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        attachBack()
        return false
    }
}
