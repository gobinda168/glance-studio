import AppKit
import ApplicationServices
import GlanceCore
import GlanceKit

/// Keeps the panel docked to the front window of the terminal in use (any app in `TerminalApps`).
/// Window moves and resizes arrive as Accessibility notifications (no polling); which app is
/// frontmost comes from NSWorkspace (no permission needed). Switching terminals moves the panel along.
@MainActor
final class Docker {
  /// The panel frame changed because the terminal's window moved or resized.
  var onFrame: ((NSRect) -> Void)?
  /// A terminal (or Glance) became or stopped being the frontmost app.
  var onTerminalFront: ((Bool) -> Void)?
  private(set) var isTerminalFront = false
  var isTrusted: Bool { AXIsProcessTrusted() }
  /// Whether code editors count (Settings → "Show Glance over code editors"). Call `refresh()` after changing it.
  var includesEditors = true
  /// The attached app is a code editor: Glance shows there as an orb with a popover.
  var isEditor: Bool { TerminalApps.isEditor(attachedBundleID) }

  private var observer: AXObserver?
  private var attachedPID: pid_t?
  private var attachedBundleID: String?
  private var app: AXUIElement?
  private var window: AXUIElement?
  private var trustTimer: Timer?
  private var workspaceObservers: [NSObjectProtocol] = []
  /// Whether this app's own front window (Settings) counts as a terminal being in front.
  var ownAppCountsAsFront: () -> Bool = { true }

  func start() {
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated { self.activated(app) }
    })
    workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      MainActor.assumeIsolated {
        guard let app, app.processIdentifier == self.attachedPID else { return }
        self.detach()
        self.attachToRunningTerminal()
      }
    })

    // First Light asks for Accessibility itself, with its reason; until it has run, wait without the system prompt.
    let prompt = !Prefs.onboardingPending
    if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary) {
      // Wait for the user to grant Accessibility in System Settings, then attach.
      trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        MainActor.assumeIsolated {
          guard AXIsProcessTrusted() else { return }
          self.trustTimer?.invalidate()
          self.attachToRunningTerminal()
          self.onFrame?(self.frame())
        }
      }
    }
    attachToRunningTerminal()
    activated(NSWorkspace.shared.frontmostApplication)
  }

  /// Stops following anything: observers removed, the attached window let go.
  func stop() {
    workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    workspaceObservers.removeAll()
    trustTimer?.invalidate()
    trustTimer = nil
    detach()
    isTerminalFront = false
  }

  /// Where the panel belongs right now.
  func frame() -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
    if let window, let axFrame = Self.axFrame(window) {
      return DockGeometry.panelFrame(axWindow: axFrame, primaryScreenHeight: primaryHeight)
    }
    let screen = NSScreen.main ?? NSScreen.screens.first
    return DockGeometry.fallbackFrame(visibleScreen: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
  }

  /// The terminal's window in AppKit coordinates, when Glance is attached to one.
  func terminalWindowFrame() -> NSRect? {
    guard let window, let ax = Self.axFrame(window) else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 900
    return NSRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
  }

  /// Re-checks the front app, e.g. after `includesEditors` changed.
  func refresh() {
    if !includesEditors, isEditor { detach() }
    attachToRunningTerminal()
    activated(NSWorkspace.shared.frontmostApplication)
  }

  private func supports(_ bundleID: String?) -> Bool {
    TerminalApps.isSupported(bundleID) && (includesEditors || !TerminalApps.isEditor(bundleID))
  }

  private func activated(_ running: NSRunningApplication?) {
    let isTerminal = supports(running?.bundleIdentifier)
    if isTerminal, let running, running.processIdentifier != attachedPID {
      detach()
      attach(to: running)
      onFrame?(frame())
    }
    isTerminalFront = isTerminal || (running == NSRunningApplication.current && ownAppCountsAsFront())
    onTerminalFront?(isTerminalFront)
  }

  /// At launch, or when the attached terminal quits: the frontmost terminal, else the first one running.
  private func attachToRunningTerminal() {
    guard app == nil else { return }
    let front = NSWorkspace.shared.frontmostApplication
    if supports(front?.bundleIdentifier), let front { return attach(to: front) }
    let running = NSWorkspace.shared.runningApplications
    for terminal in TerminalApps.all where supports(terminal.bundleID) {
      if let match = running.first(where: { $0.bundleIdentifier == terminal.bundleID }) { return attach(to: match) }
    }
  }

  private func attach(to terminal: NSRunningApplication) {
    guard AXIsProcessTrusted(), app == nil else { return }
    let element = AXUIElementCreateApplication(terminal.processIdentifier)
    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, notification, refcon in
      guard let refcon else { return }
      let docker = Unmanaged<Docker>.fromOpaque(refcon).takeUnretainedValue()
      MainActor.assumeIsolated { docker.handle(notification as String) }
    }
    guard AXObserverCreate(terminal.processIdentifier, callback, &created) == .success, let created else { return }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
      AXObserverAddNotification(created, element, name as CFString, refcon)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
    observer = created
    app = element
    attachedPID = terminal.processIdentifier
    attachedBundleID = terminal.bundleIdentifier
    bindFrontWindow()
  }

  private func detach() {
    if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
    observer = nil
    app = nil
    window = nil
    attachedPID = nil
    attachedBundleID = nil
  }

  private func handle(_ notification: String) {
    switch notification {
    case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
      bindFrontWindow()
      onFrame?(frame())
    case kAXUIElementDestroyedNotification:
      window = nil
      bindFrontWindow()
    default:
      onFrame?(frame())
    }
  }

  private func bindFrontWindow() {
    guard let app, let observer else { return }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    if let window {
      for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
        AXObserverRemoveNotification(observer, window, name as CFString)
      }
    }
    window = Self.element(app, kAXFocusedWindowAttribute) ?? Self.element(app, kAXMainWindowAttribute)
    if let window {
      for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
        AXObserverAddNotification(observer, window, name as CFString, refcon)
      }
    }
  }

  private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private static func axFrame(_ window: AXUIElement) -> CGRect? {
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
      AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
      let position, let size
    else { return nil }
    var origin = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return extent.width > 0 && extent.height > 0 ? CGRect(origin: origin, size: extent) : nil
  }
}
