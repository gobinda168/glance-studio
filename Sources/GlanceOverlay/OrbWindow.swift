import AppKit
import GlanceCore
import GlanceKit
import WebKit

/// The orb Glance floats over code editors (Claude Design "Glance Panel v11", VS Code "orb" placement): the panel's
/// orb on its own (Web/orb.html), at the bottom right of the editor. Click it to open or close the popover, drag it
/// anywhere. Like the panel it never becomes key or activates Glance, so the editor keeps keyboard focus.
@MainActor
final class OrbWindow: NSPanel, WKNavigationDelegate {
  static let side = DockGeometry.orbDiameter + 2 * DockGeometry.orbHalo

  var onClick: (() -> Void)?
  /// The orb is being dragged; its centre so far.
  var onDrag: ((CGPoint) -> Void)?
  /// Dropped at this centre.
  var onDrop: ((CGPoint) -> Void)?

  private let web: WKWebView
  private var ready = false
  private var mode = "idle"
  /// The panel's own status; a due meeting shows over it (`OrbAttention`).
  private var panelMode = "idle"
  private var open = false

  init(webDirectory: URL) {
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side), configuration: WKWebViewConfiguration())
    super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isReleasedWhenClosed = false
    animationBehavior = .none

    web.setValue(false, forKey: "drawsBackground")
    web.underPageBackgroundColor = .clear
    web.navigationDelegate = self
    web.autoresizingMask = [.width, .height]
    web.loadFileURL(webDirectory.appendingPathComponent("orb.html"), allowingReadAccessTo: webDirectory)

    let handle = OrbHandle(frame: web.frame)
    handle.autoresizingMask = [.width, .height]
    handle.orb = self
    let container = NSView(frame: web.frame)
    container.addSubview(web)
    container.addSubview(handle)
    contentView = container

    // A meeting nudge: the orb's meeting mode, and its frame to set the nudge's card beside.
    NotificationCenter.default.addObserver(forName: OrbAttention.changed, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyMode() }
    }
    OrbAttention.register(self) { [weak self] in
      guard let self, self.isVisible, self.alphaValue > 0 else { return nil }
      return self.frame.insetBy(dx: DockGeometry.orbHalo, dy: DockGeometry.orbHalo)
    }
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

  func place(center: CGPoint, animated: Bool = false) {
    let target = NSRect(x: (center.x - Self.side / 2).rounded(), y: (center.y - Self.side / 2).rounded(),
                        width: Self.side, height: Self.side)
    guard animated, isVisible else { setFrame(target, display: true); return }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.35
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1, 0.4, 1)
      animator().setFrame(target, display: true)
    }
  }

  /// Fades in where the orb belongs (or just moves there if it's already showing).
  func appear(at center: CGPoint) {
    place(center: center)
    guard !isVisible || alphaValue < 1 else { return }
    if !isVisible {
      alphaValue = 0
      orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1, 0.4, 1)
      animator().alphaValue = 1
    }
  }

  func disappear() {
    guard isVisible else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.18
      animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.alphaValue == 0 else { return }
        self.orderOut(nil)
      }
    })
  }

  /// `mode` is `PanelStatus.mode`: idle, thinking, reading or speaking.
  func setMode(_ mode: String) {
    panelMode = mode
    applyMode()
  }

  /// The mode to show (the panel's, a meeting nudge, or the orb channel's), and the session's caption as the tooltip.
  private func applyMode() {
    contentView?.toolTip = OrbAttention.tooltip
    let mode = OrbAttention.mode(panelMode)
    guard mode != self.mode else { return }
    self.mode = mode
    call("glanceOrb.state('\(mode)')")
  }

  /// The popover is open: the orb rests.
  func setOpen(_ open: Bool) {
    guard open != self.open else { return }
    self.open = open
    call("glanceOrb.open(\(open))")
  }

  func level(_ value: Float) {
    guard ready, isVisible else { return }
    web.evaluateJavaScript("void glanceOrb.level(\(String(format: "%.4f", value)))", completionHandler: nil)
  }

  private func call(_ script: String) {
    guard ready else { return }
    web.evaluateJavaScript("void " + script, completionHandler: nil)
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      ready = true
      call("glanceOrb.state('\(mode)')")
      call("glanceOrb.open(\(open))")
    }
  }

  /// A click brings back a snoozed meeting nudge first; otherwise it opens or closes the popover.
  fileprivate func clicked() {
    guard !OrbAttention.orbClicked() else { return }
    onClick?()
  }
  fileprivate func dragged() { onDrag?(center) }
  fileprivate func dropped() { onDrop?(center) }
}

/// Takes the mouse over the orb: a click opens or closes the popover, a drag moves the orb. The page underneath only
/// draws.
private final class OrbHandle: NSView {
  weak var orb: OrbWindow?
  private var start: NSPoint?
  private var origin: NSPoint = .zero
  private var dragging = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Only the orb itself (and a little around it) is clickable, not the whole glow.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    let reach = DockGeometry.orbDiameter / 2 + 6
    return hypot(local.x - bounds.midX, local.y - bounds.midY) <= reach ? self : nil
  }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  override func mouseDown(with event: NSEvent) {
    start = NSEvent.mouseLocation
    origin = window?.frame.origin ?? .zero
    dragging = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start, let window = orb else { return }
    let now = NSEvent.mouseLocation
    let dx = now.x - start.x, dy = now.y - start.y
    if !dragging, hypot(dx, dy) < 3 { return }
    dragging = true
    window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    window.dragged()
  }

  override func mouseUp(with event: NSEvent) {
    defer { start = nil; dragging = false }
    guard start != nil else { return }
    if dragging { orb?.dropped() } else { orb?.clicked() }
  }
}
