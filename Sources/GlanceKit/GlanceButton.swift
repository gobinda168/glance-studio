import SwiftUI

/// The design system's button (MASTER §8, `.g-btn`), shared by the meeting card and the update toast: primary is
/// coral with dark text, secondary outlined, quiet muted until the pointer is on it. It presses to .97 and shows a 2 pt
/// coral ring at a 2 pt offset while it has keyboard focus. A glowing one wears the aurora ring and its halo (the
/// meeting card's Join: the one action Claude can take right now), turning while `turning`, brighter on hover or when
/// `bright`.
public struct GlanceButton: View {
  public enum Style: Sendable { case primary, secondary, quiet }

  private let title: String
  private let systemImage: String?
  private let style: Style
  private let label: String
  private let height: CGFloat
  private let cornerRadius: CGFloat
  private let glowing: Bool
  private let turning: Bool
  private let bright: Bool
  private let action: () -> Void

  /// `systemImage`: an SF Symbol before the title (12 pt), e.g. `touchid` on a button that asks for Touch ID.
  public init(_ title: String, systemImage: String? = nil, style: Style, label: String? = nil, height: CGFloat = 28,
              cornerRadius: CGFloat = 8, glowing: Bool = false, turning: Bool = false, bright: Bool = false,
              action: @escaping () -> Void) {
    self.title = title
    self.systemImage = systemImage
    self.style = style
    self.label = label ?? title
    self.height = height
    self.cornerRadius = cornerRadius
    self.glowing = glowing
    self.turning = turning
    self.bright = bright
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      if let systemImage {
        HStack(spacing: 6) {
          Image(systemName: systemImage).font(.system(size: 12, weight: .regular)).accessibilityHidden(true)
          Text(title)
        }
      } else {
        Text(title)
      }
    }
      .buttonStyle(Face(style: style, height: height, cornerRadius: cornerRadius, glowing: glowing, turning: turning,
                        bright: bright))
      .focusEffectDisabled()
      .accessibilityLabel(label)
  }
}

private struct Face: ButtonStyle {
  let style: GlanceButton.Style
  let height: CGFloat
  let cornerRadius: CGFloat
  let glowing: Bool
  let turning: Bool
  let bright: Bool

  func makeBody(configuration: Configuration) -> some View {
    FaceBody(configuration: configuration, style: style, height: height, cornerRadius: cornerRadius, glowing: glowing,
             turning: turning, bright: bright)
  }
}

private struct FaceBody: View {
  let configuration: ButtonStyleConfiguration
  let style: GlanceButton.Style
  let height: CGFloat
  let cornerRadius: CGFloat
  let glowing: Bool
  let turning: Bool
  let bright: Bool
  @State private var hovering = false
  @Environment(\.isFocused) private var focused
  @Environment(\.isEnabled) private var enabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    configuration.label
      .font(GlanceFont.sans(12, style == .primary ? .semibold : .medium))
      .foregroundStyle(foreground)
      .lineLimit(1)
      .padding(.horizontal, 12)
      .frame(height: height)
      .background(shape.fill(fill))
      .overlay {
        if style == .secondary { shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1) }
      }
      .overlay {
        if glowing { GlowLight(shape: shape.inset(by: -2), live: turning, part: .ring) }
      }
      .background {
        if glowing { GlowLight(shape: shape, live: turning, part: .halo, bright: hovering || bright).padding(-3) }
      }
      .overlay {
        if focused {
          // 2 pt wide, 2 pt out: its outer edge sits 4 pt out, so its corners are 4 pt rounder (concentric).
          RoundedRectangle(cornerRadius: cornerRadius + 4, style: .continuous)
            .strokeBorder(GlanceColor.coral, lineWidth: 2)
            .padding(-4)
        }
      }
      .contentShape(shape)
      .opacity(enabled ? 1 : 0.45)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.16), value: hovering)
      .animation(.easeOut(duration: 0.42), value: bright)
  }

  private var foreground: Color {
    switch style {
    case .primary: GlanceColor.rgb(0x1C1A17)
    case .secondary: GlanceColor.ink
    case .quiet: hovering ? GlanceColor.ink : GlanceColor.muted
    }
  }

  private var fill: Color {
    switch style {
    case .primary: hovering ? GlanceColor.rgb(0xEE7650) : GlanceColor.coral
    case .secondary, .quiet: hovering ? Color.primary.opacity(0.08) : .clear
    }
  }
}
