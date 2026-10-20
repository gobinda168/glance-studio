import AppKit
import CoreText
import SwiftUI

/// The design system's faces for native pages (MASTER §4): DM Sans for words, JetBrains Mono for numbers, paths,
/// branches and keys. They are the variable fonts the web pages use (`Web/vendor/fonts`), registered for this process
/// once; each weight is set on their `wght` axis. Until `register` has found them, or if the files are missing, the
/// faces fall back to SF Pro and SF Mono.
@MainActor
public enum GlanceFont {
  private static let sansName = "DMSans-9ptRegular"
  private static let monoName = "JetBrainsMono-Regular"
  private static let weightAxis = NSNumber(value: 0x7767_6874) // 'wght'
  private static var available: Set<String> = []
  private static var cache: [String: Font] = [:]

  /// Registers `dm-sans.woff2` and `jetbrains-mono.woff2` from `directory`. Safe to call more than once.
  public static func register(fontsDirectory directory: URL) {
    for (file, name) in [("dm-sans.woff2", sansName), ("jetbrains-mono.woff2", monoName)] where !available.contains(name) {
      _ = CTFontManagerRegisterFontsForURL(directory.appendingPathComponent(file) as CFURL, .process, nil)
      let probe = CTFontCreateWithName(name as CFString, 12, nil)
      if CTFontCopyPostScriptName(probe) as String == name { available.insert(name) }
    }
    cache.removeAll()
  }

  public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    face(sansName, design: .default, size: size, weight: weight)
  }

  public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    face(monoName, design: .monospaced, size: size, weight: weight)
  }

  private static func face(_ name: String, design: Font.Design, size: CGFloat, weight: Font.Weight) -> Font {
    let key = "\(name)|\(size)|\(axisValue(weight))"
    if let font = cache[key] { return font }
    let font: Font
    if available.contains(name) {
      let attributes: [CFString: Any] = [kCTFontNameAttribute: name,
                                         kCTFontVariationAttribute: [weightAxis: axisValue(weight)]]
      font = Font(CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil))
    } else {
      font = .system(size: size, weight: weight, design: design)
    }
    cache[key] = font
    return font
  }

  private static func axisValue(_ weight: Font.Weight) -> Double {
    switch weight {
    case .medium: 500
    case .semibold: 600
    case .bold: 700
    default: 400
    }
  }
}
