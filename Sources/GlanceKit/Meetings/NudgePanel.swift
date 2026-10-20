import AppKit
import GlanceCore
import SwiftUI

/// The nudge's window (spec 2026-10-08-meeting-nudges-design.md, "NudgePanel + NudgeCard"): floats over every app and
/// Space, takes clicks but never keyboard focus, at the top centre of the screen with the mouse. The window holds
/// still; the nudge moves inside it (`NudgeStageView`), with room around it for its glow and shadow.
@MainActor
final class NudgePanel {
  /// A button on the card, with its nudge's id.
  var onAction: ((Nudge.Action, String) -> Void)?
  private let panel: NudgeWindow
  private let stage = NudgeStage()
  private let host: NudgeHostingView

  init() {
    panel = NudgeWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 168),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The card draws its own shadow inside the window's margin.
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    host = NudgeHostingView(rootView: NudgeStageView(stage: stage, act: { _, _ in }))
    host.rootView = NudgeStageView(stage: stage) { [weak self] action, id in self?.onAction?(action, id) }
    panel.contentView = host
  }

  var isVisible: Bool { stage.shown && panel.isVisible }

  /// The window's frame while the nudge shows (its card plus `NudgeStageView.margin` all round), else nil: the
  /// notification cards stack under it.
  var frame: NSRect? { isVisible ? panel.frame : nil }

  /// Shows `nudge`: a new one drops in from the top with its glow flaring; an update redraws it in place.
  func show(_ nudge: Nudge, arriving: Bool) {
    let wasShowing = isVisible
    stage.nudge = nudge
    host.layoutSubtreeIfNeeded()
    let margin = NudgeStageView.margin
    let size = host.fittingSize
    let card = placement(CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin))
    panel.setFrame(card.insetBy(dx: -margin, dy: -margin), display: true)
    guard arriving || !wasShowing else { return }
    // Off stage above, then in on the spring; the glow blooms and settles.
    var still = Transaction()
    still.disablesAnimations = true
    withTransaction(still) {
      stage.leaving = false
      stage.shown = false
      stage.flare = true
    }
    panel.orderFrontRegardless()
    DispatchQueue.main.async { [weak self] in
      guard let self, self.stage.nudge?.id == nudge.id else { return }
      withAnimation(Self.reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.86)) {
        self.stage.shown = true
      }
      withAnimation(.easeOut(duration: 1.4).delay(0.5)) { self.stage.flare = false }
    }
  }

  /// Leaves faster than it came, 8 px back up, then orders out.
  func hide() {
    guard stage.shown else { return }
    let id = stage.nudge?.id
    withAnimation(.easeIn(duration: 0.16)) {
      stage.leaving = true
      stage.shown = false
    } completion: { [weak self] in
      guard let self, !self.stage.shown, self.stage.nudge?.id == id else { return }
      self.panel.orderOut(nil)
    }
  }

  private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// The top centre of the screen with the mouse.
  private func placement(_ size: CGSize) -> NSRect {
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NudgePlacement.frame(card: size, screen: frame, visible: screen?.visibleFrame ?? frame)
  }
}

/// Never key or main: the app in front keeps the keyboard.
private final class NudgeWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The first click on the card presses its button, not just focuses the window.
private final class NudgeHostingView: NSHostingView<NudgeStageView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
