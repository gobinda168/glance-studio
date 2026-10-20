import GlanceCore
import SwiftUI

/// Glance Studio's update toast (agreed in chat 2026-10-09, after Cursor's "New update available · Later · Install
/// Now"): a slim card of Regular glass at the window's bottom left with the step's symbol, its words, the version or
/// percentage in mono, and its buttons; a coral line fills along the bottom edge while the update downloads. A new step
/// blur-swaps in place; the card keeps one width, so it never jumps. The fork's `UpdateToast` moves it in and out.
public struct UpdateToastCard: View {
  /// Wide enough for the widest step on one line ("New update available", a build's version, Later and Install Now).
  public static let width: CGFloat = 436

  private let notice: UpdateNotice
  private let act: (UpdateNotice.Action) -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(notice: UpdateNotice, act: @escaping (UpdateNotice.Action) -> Void) {
    self.notice = notice
    self.act = act
  }

  public var body: some View {
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    // The old step and the new one overlap while they swap.
    ZStack {
      HStack(spacing: 10) {
        words
          .frame(maxWidth: .infinity, alignment: .leading)
        if !notice.buttons.isEmpty {
          buttons
        }
      }
      .id(notice.title)
      .transition(.blurSwap(reduceMotion))
    }
    // The buttons sit 6 pt in from the corner they share with the card: 12 − 6 = their 6 pt corners (concentric).
    .padding(.leading, 13)
    .padding(.trailing, notice.buttons.isEmpty ? 14 : 6)
    .padding(.vertical, notice.note == nil ? 6 : 9)
    .frame(width: Self.width)
    .frame(minHeight: 40)
    .animation(reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.24), value: notice.title)
    .modifier(GlassSurface(shape: shape))
    // Over the glass, not inside it: Liquid Glass refracts a bright line at its edge into a coral smear behind the words.
    .overlay(alignment: .bottom) { progressLine.clipShape(shape) }
    .overlay(shape.strokeBorder(rim, lineWidth: 1))
    .shadow(color: shadow.opacity(scheme == .dark ? 0.42 : 0.16), radius: 16, y: 7)
    .shadow(color: shadow.opacity(scheme == .dark ? 0.3 : 0.08), radius: 1.5, y: 1)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(notice.title))
  }

  @ViewBuilder private var symbol: some View {
    if notice.symbol == .checking {
      ProgressView().controlSize(.small)
    } else {
      Image(systemName: symbolName)
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(toneColor)
        .accessibilityHidden(true)
    }
  }

  /// The symbol sits on the title's line; a second line hangs under the title, not under the symbol.
  private var words: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 10) {
        symbol
          .frame(width: 16, height: 16)
        title
      }
      if let note = notice.note {
        Text(note)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, 26)
      }
    }
    // A failure's whole message, when two lines cut it short.
    .help(notice.note ?? notice.title)
  }

  private var title: some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(notice.title)
        .font(GlanceFont.sans(13, .medium))
        .foregroundStyle(GlanceColor.ink)
        .lineLimit(1)
        .layoutPriority(1)
      if let detail = notice.detail {
        Text(detail)
          .font(GlanceFont.mono(11.5))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(1)
          .contentTransition(.numericText())
          .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: detail)
      }
    }
  }

  private var buttons: some View {
    HStack(spacing: 4) {
      ForEach(notice.buttons, id: \.action) { button in
        GlanceButton(button.title, style: button.role == .primary ? .primary : .quiet, height: 28, cornerRadius: 6) {
          act(button.action)
        }
      }
    }
  }

  /// The download's or the preparation's progress: coral filling a faint track along the bottom edge.
  @ViewBuilder private var progressLine: some View {
    if let progress = notice.progress {
      ZStack(alignment: .leading) {
        Rectangle().fill(Color.primary.opacity(0.08))
        Rectangle()
          .fill(GlanceColor.coral)
          .scaleEffect(x: progress, anchor: .leading)
          .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
      }
      .frame(height: 2)
      .frame(maxHeight: .infinity, alignment: .bottom)
      .accessibilityHidden(true)
    }
  }

  private var symbolName: String {
    switch notice.symbol {
    case .gift: "gift"
    case .question: "questionmark.circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .download: "arrow.down.circle"
    case .prepare: "shippingbox"
    case .restart: "arrow.clockwise"
    case .upToDate: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var toneColor: Color {
    switch notice.tone {
    case .coral: GlanceColor.coralInk
    case .quiet: GlanceColor.muted
    case .ok: GlanceColor.okInk
    case .critical: GlanceColor.criticalInk
    }
  }

  /// MASTER's rim: a lit top edge fading into the hairline round the rest of the card.
  private var rim: LinearGradient {
    let top = Color.white.opacity(scheme == .dark ? 0.16 : 0.7)
    let line = scheme == .dark ? Color.white.opacity(0.08) : GlanceColor.rgb(0x1C1A17).opacity(0.1)
    return LinearGradient(stops: [.init(color: top, location: 0), .init(color: line, location: 0.5)],
                          startPoint: .top, endPoint: .bottom)
  }

  /// Warm in light mode (MASTER §5: never a hard black shadow there), black in dark.
  private var shadow: Color { scheme == .dark ? .black : GlanceColor.rgb(0x1C1A17) }
}
