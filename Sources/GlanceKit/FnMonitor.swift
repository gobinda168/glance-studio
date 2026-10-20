import AppKit
import Carbon

/// Watches the fn (🌐) key system-wide. Global monitors need the Accessibility permission Glance already has
/// for docking; the local monitor covers Glance's own Settings window.
@MainActor
final class FnMonitor {
  var onFnDown: (() -> Void)?
  var onFnUp: (() -> Void)?
  /// Any other key or modifier while fn is down: true for a key press, false for a modifier change.
  var onOtherKey: ((_ isKeyDown: Bool) -> Void)?

  private var monitors: [Any] = []
  private var fnDown = false

  func start() {
    guard monitors.isEmpty else { return }
    let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
      monitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
      monitors.append(local)
    }
  }

  func stop() {
    monitors.forEach(NSEvent.removeMonitor)
    monitors.removeAll()
    fnDown = false
  }

  private func handle(_ event: NSEvent) {
    switch event.type {
    case .flagsChanged where event.keyCode == UInt16(kVK_Function):
      let down = event.modifierFlags.contains(.function)
      guard down != fnDown else { return }
      fnDown = down
      down ? onFnDown?() : onFnUp?()
    case .flagsChanged:
      if fnDown { onOtherKey?(false) }
    case .keyDown:
      if fnDown { onOtherKey?(true) }
    default:
      break
    }
  }
}
