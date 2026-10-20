import Foundation

/// The wire format between a shell's Glance plugin and Studio (spec 2026-10-08-terminal-suggestions-design.md, "The
/// bridge"): one message per line, fields split by tabs, and inside a field a backslash is `\\`, a tab `\t` and a
/// newline `\n`. Positions in messages count characters the way zsh does (Unicode scalars).
public enum ShellWire {
  public static func escape(_ field: String) -> String {
    guard field.contains(where: { $0 == "\\" || $0 == "\t" || $0 == "\n" }) else { return field }
    var out = ""
    out.reserveCapacity(field.count + 8)
    for scalar in field.unicodeScalars {
      switch scalar {
      case "\\": out += "\\\\"
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out
  }

  /// The field as it was before `escape`. An escape the encoder never writes is kept as it is.
  public static func unescape<S: StringProtocol>(_ field: S) -> String {
    guard field.contains("\\") else { return String(field) }
    var out = ""
    var escaping = false
    for scalar in field.unicodeScalars {
      if escaping {
        switch scalar {
        case "\\": out += "\\"
        case "t": out += "\t"
        case "n": out += "\n"
        default: out += "\\"; out.unicodeScalars.append(scalar)
        }
        escaping = false
      } else if scalar == "\\" {
        escaping = true
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
    if escaping { out += "\\" }
    return out
  }

  /// One message: the fields escaped, joined by tabs, ended by a newline.
  public static func line(_ fields: [String]) -> String {
    fields.map(escape).joined(separator: "\t") + "\n"
  }

  /// A message's fields (the line without its newline), each unescaped. Empty fields are kept.
  public static func fields(_ line: String) -> [String] {
    line.split(separator: "\t", omittingEmptySubsequences: false).map(unescape)
  }
}

/// A byte stream cut into the wire format's lines. Nothing is trimmed (a field may end in spaces); empty lines are
/// dropped, and a line over 4 MB is thrown away whole.
public struct ShellLines {
  private var pending = Data()
  private var discarding = false
  private static let limit = 4 << 20

  public init() {}

  public mutating func append(_ data: Data) -> [String] {
    var lines: [String] = []
    var start = data.startIndex
    while let newline = data[start...].firstIndex(of: UInt8(ascii: "\n")) {
      if !discarding {
        pending.append(data[start..<newline])
        if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
      }
      pending.removeAll(keepingCapacity: true)
      discarding = false
      start = data.index(after: newline)
    }
    if !discarding {
      pending.append(data[start...])
      if pending.count > Self.limit {
        pending.removeAll()
        discarding = true
      }
    }
    return lines
  }
}
