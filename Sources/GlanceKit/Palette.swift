import AppKit
import SwiftUI

/// Accent colours for the Settings window and the dictation pill.
enum Palette {
  static let cyan = Color(red: 0.31, green: 0.86, blue: 1.0)
  static let violet = Color(red: 0.58, green: 0.47, blue: 1.0)
  static let pink = Color(red: 1.0, green: 0.42, blue: 0.75)
  static let blue = Color(red: 0.22, green: 0.45, blue: 1.0)
  static let spectrum = [cyan, violet, pink, cyan]
}

/// The design system's colours for native surfaces (Home, the window chrome), with the values of
/// design-system/glance/MASTER.md §3. Colour carries meaning, never decoration: coral is Glance and Claude (and the
/// selection), teal is thinking and plan usage, amber reading, green done, warn and critical a limit closing in.
public enum GlanceColor {
  public static let coral = rgb(0xE8643C)
  public static let coralHi = rgb(0xFFB28F)
  public static let coralLo = rgb(0xB8431F)
  public static let teal = rgb(0x2A8F94)
  public static let amber = rgb(0xD9A441)
  public static let ok = rgb(0x2EA043)
  public static let warn = rgb(0xD9A21B)
  public static let critical = rgb(0xD9402F)
  /// The glow ring's light: coral, peach, violet, sky, and round to coral.
  public static let aurora: [Color] = [coral, coralHi, rgb(0xC96DF2), rgb(0x6AA8FF), coral]

  /// Text and thin glyphs, each measured at 4.5:1 or more on the graphite and off-white grounds. Coral as light-theme
  /// text is MASTER's #c4471f deepened to #b0401c: on Home's ground (#f4f1ea) the lighter one measures 4.4:1.
  public static let ink = adaptive(light: 0x1C1A17, dark: 0xF1EDE4)
  public static let body = adaptive(light: 0x4A453D, dark: 0xC5BFB3)
  public static let muted = adaptive(light: 0x6B655C, dark: 0x9A948A)
  public static let coralInk = adaptive(light: 0xB0401C, dark: 0xFF9B7A)
  public static let tealInk = adaptive(light: 0x13656A, dark: 0x8FD9DC)
  public static let okInk = adaptive(light: 0x197A35, dark: 0x56D364)
  public static let warnInk = adaptive(light: 0x8A5A00, dark: 0xE3B65C)
  public static let criticalInk = adaptive(light: 0xB42318, dark: 0xFF9189)

  /// Home's ground: warm graphite, or warm off-white.
  public static let ground = adaptive(light: 0xF4F1EA, dark: 0x131211)
  /// An opaque surface: under the glow ring, and glass under Reduce Transparency.
  public static let solid = adaptive(light: 0xFFFAF6, dark: 0x221F1D)

  static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      nsColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
    })
  }

  static func rgb(_ hex: UInt32) -> Color { Color(nsColor: nsColor(hex)) }

  private static func nsColor(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}
