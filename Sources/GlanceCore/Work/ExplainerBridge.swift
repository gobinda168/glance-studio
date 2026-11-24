import Foundation

/// What an explainer page may tell the app. Every value is checked here: even Glance's own script runs on a page Claude
/// wrote, so the app takes nothing from it on trust.
public enum ExplainerBridge {
  public enum Message: Equatable, Sendable {
    case ready
    case height(Double)
    case beat(index: Int, top: Double)
    case play(index: Int)
    case ask(title: String)
    case open(path: String)
  }

  public static let maxHeight = 20_000.0
  private static let maxTitle = 200
  private static let maxPath = 1024

  public static func parse(_ body: Any) -> Message? {
    guard let body = body as? [String: Any], let type = body["type"] as? String else { return nil }
    func number(_ key: String) -> Double? {
      guard let value = (body[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
      return value
    }
    func index(_ key: String) -> Int? {
      guard let value = number(key), value < 64, value == value.rounded() else { return nil }
      return Int(value)
    }
    switch type {
    case "ready": return .ready
    case "height":
      guard let height = number("h"), height <= maxHeight else { return nil }
      return .height(height)
    case "beat":
      guard let i = index("i"), let top = number("top"), top <= maxHeight else { return nil }
      return .beat(index: i, top: top)
    case "play":
      return index("i").map { .play(index: $0) }
    case "ask":
      guard let title = body["title"] as? String, !title.isEmpty else { return nil }
      return .ask(title: String(title.prefix(maxTitle)))
    case "open":
      guard let path = body["path"] as? String, !path.isEmpty, path.count <= maxPath else { return nil }
      return .open(path: path)
    default: return nil
    }
  }

  /// What Ask about this leaves in the composer. One line, whatever the heading held.
  public static func askText(title: String) -> String {
    "About \"\(title.split(whereSeparator: \.isWhitespace).joined(separator: " "))\": "
  }

  /// `data-file` opens only a relative path that stays inside the session's folder once links are followed.
  public static func safeFile(_ path: String, root: String?) -> String? {
    guard let root, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"), !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
    let base = URL(fileURLWithPath: root).resolvingSymlinksInPath()
    let target = base.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
    guard target.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: target.path) else { return nil }
    return target.path
  }
}
