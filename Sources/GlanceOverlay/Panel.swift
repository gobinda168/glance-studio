import AppKit
import GlanceCore
import WebKit

/// A floating panel that never becomes key or activates Glance, so the terminal keeps keyboard focus. The page
/// (Web/index.html) draws everything inside it; the panel adds the Liquid Glass behind the page on macOS 26, or a
/// system blur before that.
final class GlancePanel: NSPanel {
  static let cornerRadius: CGFloat = 18

  init(content: NSView) {
    super.init(contentRect: NSRect(x: 0, y: 0, width: DockGeometry.width, height: 700),
               styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
               backing: .buffered, defer: false)
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    appearance = NSAppearance(named: .darkAqua)

    content.wantsLayer = true
    content.layer?.cornerRadius = Self.cornerRadius
    content.layer?.cornerCurve = .continuous
    content.layer?.masksToBounds = true

    if #available(macOS 26.0, *) {
      let glass = NSGlassEffectView()
      glass.style = .regular
      glass.cornerRadius = Self.cornerRadius
      glass.contentView = content
      contentView = glass
    } else {
      let blur = NSVisualEffectView()
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      blur.maskImage = Self.roundedMask(radius: Self.cornerRadius)
      content.translatesAutoresizingMaskIntoConstraints = false
      blur.addSubview(content)
      NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        content.topAnchor.constraint(equalTo: blur.topAnchor),
        content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
      ])
      contentView = blur
    }
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  /// Light or dark glass, following the panel's theme.
  func setTheme(_ theme: PanelPrefs.Theme) {
    appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
  }

  /// Glides in and settles: from the right when docked to a terminal, up from the orb as an editor's popover
  /// (`from`). The page plays its own spring on top (`ContentWeb.appear`).
  func fadeIn(to frame: NSRect, from offset: CGVector = CGVector(dx: 28, dy: 0)) {
    guard !isVisible || alphaValue < 1 else { setFrame(frame, display: true); return }
    if !isVisible {
      setFrame(frame.offsetBy(dx: offset.dx, dy: offset.dy), display: false)
      alphaValue = 0
      orderFrontRegardless()
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.42
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
      animator().setFrame(frame, display: true)
      animator().alphaValue = 1
    }
  }

  func fadeOut(to offset: CGVector = CGVector(dx: 18, dy: 0)) {
    guard isVisible else { return }
    let target = frame.offsetBy(dx: offset.dx, dy: offset.dy)
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.2
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().setFrame(target, display: true)
      animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.alphaValue == 0 else { return }
        self.orderOut(nil)
      }
    })
  }

  private static func roundedMask(radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}
