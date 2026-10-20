import Foundation

/// The terminal's config file as its lines (spec 2026-10-08-settings-design.md, "Terminal preferences"). Settings reads
/// a key's value and changes one line at a time, so comments, order and every other line stay as written.
public struct TerminalConfig: Equatable, Sendable {
  private var lines: [String]

  public init(text: String) {
    lines = text.components(separatedBy: "\n")
  }

  /// The file's text, with the changes.
  public var text: String { lines.joined(separator: "\n") }

  /// The key's last value, the one the terminal uses; nil when no line sets it.
  public func value(_ key: String) -> String? {
    indices(of: key).last.flatMap { Self.entry(lines[$0])?.value }
  }

  /// The key's first value: the first `font-family` line is the main font, the others its fallbacks.
  public func firstValue(_ key: String) -> String? {
    indices(of: key).first.flatMap { Self.entry(lines[$0])?.value }
  }

  /// Rewrites the key's last line (its first with `first`) as `key = value`; a key no line sets gets that line at the
  /// end, before the final newline.
  public mutating func set(_ key: String, _ value: String, first: Bool = false) {
    let line = "\(key) = \(value)"
    let matches = indices(of: key)
    if let index = first ? matches.first : matches.last {
      lines[index] = line
    } else if lines.last == "" {
      lines.insert(line, at: lines.count - 1)
    } else {
      lines.append(line)
      lines.append("")
    }
  }

  /// Drops every line that sets the key.
  public mutating func remove(_ key: String) {
    let matches = Set(indices(of: key))
    lines = lines.indices.filter { !matches.contains($0) }.map { lines[$0] }
  }

  /// A `theme` value as Settings shows it: "Light: A · Dark: B" for a light and dark pair, else the value.
  public static func themeLabel(_ value: String) -> String {
    var light: String?
    var dark: String?
    for part in value.split(separator: ",") {
      let part = part.trimmingCharacters(in: .whitespaces)
      if part.hasPrefix("light:") {
        light = part.dropFirst("light:".count).trimmingCharacters(in: .whitespaces)
      } else if part.hasPrefix("dark:") {
        dark = part.dropFirst("dark:".count).trimmingCharacters(in: .whitespaces)
      }
    }
    if let light, let dark { return "Light: \(light) · Dark: \(dark)" }
    return value
  }

  /// A line's key and value: a line that isn't blank or a `#` comment, split at its first `=`, both sides trimmed and
  /// the value's surrounding double quotes dropped.
  static func entry(_ line: String) -> (key: String, value: String)? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
    var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
      value = String(value.dropFirst().dropLast())
    }
    return key.isEmpty ? nil : (key, value)
  }

  private func indices(of key: String) -> [Int] {
    lines.indices.filter { Self.entry(lines[$0])?.key == key }
  }
}
