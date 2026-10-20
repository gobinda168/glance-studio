import Foundation

/// A terminal theme file's colours (spec 2026-10-08-settings-design.md, "Terminal preferences"): its background,
/// foreground and 16 palette colours as `#rrggbb`, for Settings' swatches and preview. Lines it doesn't know are
/// skipped; a theme whose colours can't be read still lists, without a swatch.
public struct TerminalTheme: Equatable, Sendable {
  public let name: String
  public private(set) var background: String?
  public private(set) var foreground: String?
  /// Colours 0 to 15; nil where the theme sets none.
  public private(set) var palette: [String?] = Array(repeating: nil, count: 16)

  public init(name: String, text: String) {
    self.name = name
    for line in text.split(whereSeparator: \.isNewline) {
      guard let (key, value) = TerminalConfig.entry(String(line)) else { continue }
      switch key {
      case "background":
        background = Self.hex(value)
      case "foreground":
        foreground = Self.hex(value)
      case "palette":
        // `palette = N=#rrggbb`
        guard let equals = value.firstIndex(of: "="),
              let index = Int(value[..<equals].trimmingCharacters(in: .whitespaces)), palette.indices.contains(index)
        else { continue }
        palette[index] = Self.hex(String(value[value.index(after: equals)...]))
      default:
        continue
      }
    }
  }

  /// Whether any colour was read.
  public var hasColors: Bool { background != nil || foreground != nil || palette.contains { $0 != nil } }

  /// Dark by the background's perceived luminance; a theme without a background counts as dark.
  public var isDark: Bool {
    guard let background, let rgb = Self.rgb(background) else { return true }
    return 0.299 * rgb.red + 0.587 * rgb.green + 0.114 * rgb.blue < 0.5
  }

  /// A `#rrggbb` (or `rrggbb`) colour's components, 0 to 1.
  public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
    guard let normalized = Self.hex(hex), let value = UInt32(normalized.dropFirst(), radix: 16) else { return nil }
    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
  }

  /// The terminal's own 16 colours (src/terminal/color.zig's `Name.default`): what it shows where a theme sets none.
  public static let defaultPalette: [String] = [
    "#1d1f21", "#cc6666", "#b5bd68", "#f0c674", "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
    "#666666", "#d54e53", "#b9ca4a", "#e7c547", "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
  ]

  /// `#rrggbb` in lower case from six hex digits, `#` optional; nil for anything else.
  static func hex(_ value: String) -> String? {
    var digits = value.trimmingCharacters(in: .whitespaces).lowercased()
    if digits.hasPrefix("#") { digits.removeFirst() }
    guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return nil }
    return "#" + digits
  }
}
