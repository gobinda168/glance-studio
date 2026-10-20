import AppKit
import GlanceCore
import Observation
import SwiftUI

@Observable
final class PillModel {
  enum Mode: Equatable {
    case listening
    case finishing
    case message(String, isError: Bool)
  }

  var mode = Mode.listening
  var text = ""
  var notice: String?
}

/// The floating dictation readout. Never takes focus or clicks.
@MainActor
final class DictationPill {
  static let size = CGSize(width: 520, height: 56)
  private let model = PillModel()
  private let panel: NSPanel
  private var hideWork: DispatchWorkItem?

  init(level: LevelMeter) {
    panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = NSHostingView(rootView: PillView(model: model, level: level))
  }

  func show(_ mode: PillModel.Mode, near window: NSRect?) {
    hideWork?.cancel()
    model.mode = mode
    if mode == .listening {
      model.text = ""
      model.notice = nil
    }
    let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    panel.setFrame(DockGeometry.pillFrame(window: window, visibleScreen: screen, size: Self.size), display: true)
    guard !panel.isVisible || panel.alphaValue < 1 else { return }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      panel.animator().alphaValue = 1
    }
  }

  func set(_ mode: PillModel.Mode) {
    hideWork?.cancel()
    model.mode = mode
  }

  func update(text: String) { model.text = text }

  func setNotice(_ text: String?) { model.notice = text }

  func hide(after delay: TimeInterval = 0) {
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let panel = self?.panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
          context.duration = 0.2
          panel.animator().alphaValue = 0
        }, completionHandler: {
          MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
      }
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
}

private struct PillView: View {
  let model: PillModel
  let level: LevelMeter

  var body: some View {
    HStack(spacing: 12) {
      indicator.frame(width: 46, height: 26)
      Text(label)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.white.opacity(isPlaceholder ? 0.5 : 0.94))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let notice = model.notice {
        Text(notice.uppercased())
          .font(.system(size: 9.5, weight: .bold, design: .monospaced))
          .tracking(1.2)
          .foregroundStyle(Palette.pink)
      }
    }
    .padding(.horizontal, 18)
    .frame(width: DictationPill.size.width, height: DictationPill.size.height)
    .background(
      Capsule().fill(LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.12).opacity(0.95),
                                             Color(red: 0.03, green: 0.03, blue: 0.07).opacity(0.97)],
                                    startPoint: .top, endPoint: .bottom)))
    .overlay(Capsule().strokeBorder(LinearGradient(colors: rim, startPoint: .leading, endPoint: .trailing), lineWidth: 1))
    .shadow(color: (isError ? Palette.pink : Palette.cyan).opacity(0.35), radius: 14)
    .padding(1)
  }

  private var label: String {
    switch model.mode {
    case .listening: model.text.isEmpty ? "Listening…" : model.text
    case .finishing: model.text.isEmpty ? "Finishing…" : model.text
    case .message(let text, _): text
    }
  }

  private var isPlaceholder: Bool {
    if case .message = model.mode { return false }
    return model.text.isEmpty
  }

  private var isError: Bool {
    if case .message(_, true) = model.mode { true } else { false }
  }

  private var rim: [Color] { isError ? [Palette.pink, Palette.violet] : [Palette.cyan, Palette.violet, Palette.pink] }

  @ViewBuilder private var indicator: some View {
    if case .message(_, let error) = model.mode {
      Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(error ? Palette.pink : Palette.cyan)
    } else {
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let t = timeline.date.timeIntervalSinceReferenceDate
        let energy = model.mode == .finishing ? 0.12 : min(1, Double(level.value) * 8)
        HStack(spacing: 3) {
          ForEach(0..<7, id: \.self) { i in
            let wave = 0.5 + 0.5 * sin(t * 9 + Double(i) * 0.9)
            Capsule()
              .fill(LinearGradient(colors: [Palette.cyan, Palette.violet], startPoint: .top, endPoint: .bottom))
              .frame(width: 3, height: 4 + 20 * energy * wave)
          }
        }
        .shadow(color: Palette.cyan.opacity(0.6), radius: 4)
      }
    }
  }
}
