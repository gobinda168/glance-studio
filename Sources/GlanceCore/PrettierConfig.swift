import Foundation

/// The Prettier options a project sets for one file, found the way the Prettier CLI finds them: `.editorconfig` first,
/// then the nearest Prettier config file (or `package.json`'s `prettier` key) above the file, then its `overrides`.
public enum PrettierConfig {
  /// Loads a JavaScript config file, or a shared config named by a package (`"@acme/prettier-config"`), from a folder.
  /// Nil when it can't (no node).
  public typealias Evaluate = (_ module: String, _ folder: String) -> [String: Any]?

  /// Checked in this order in each folder, as Prettier does. The first folder with any of them wins.
  static let configNames = [
    "package.json", ".prettierrc", ".prettierrc.json", ".prettierrc.yaml", ".prettierrc.yml", ".prettierrc.json5",
    ".prettierrc.js", "prettier.config.js", ".prettierrc.ts", "prettier.config.ts", ".prettierrc.mjs",
    "prettier.config.mjs", ".prettierrc.mts", "prettier.config.mts", ".prettierrc.cjs", "prettier.config.cjs",
    ".prettierrc.cts", "prettier.config.cts",
  ]

  /// The options for the file at `file` (absolute). Only JSON values come back, so the result can go to the page as is.
  public static func options(for file: String, evaluate: Evaluate) -> [String: Any] {
    var options = editorConfig(for: file)
    if let (config, folder) = nearestConfig(above: file, evaluate: evaluate) {
      for (key, value) in config where !["overrides", "plugins", "$schema"].contains(key) { options[key] = value }
      let relative = relativePath(file, in: folder)
      for override in config["overrides"] as? [[String: Any]] ?? [] {
        guard matches(override["files"], relative), !matches(override["excludeFiles"], relative),
              let extra = override["options"] as? [String: Any] else { continue }
        for (key, value) in extra where key != "plugins" { options[key] = value }
      }
    }
    return options
  }

  private static func matches(_ patterns: Any?, _ path: String) -> Bool {
    let list = (patterns as? [String]) ?? (patterns as? String).map { [$0] } ?? []
    return list.contains { Glob.matches($0, path) }
  }

  /// The nearest config above the file and the folder it is in.
  static func nearestConfig(above file: String, evaluate: Evaluate) -> ([String: Any], String)? {
    var folder = (file as NSString).deletingLastPathComponent
    while true {
      for name in configNames {
        let path = (folder as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path) else { continue }
        if let config = load(path, name: name, folder: folder, evaluate: evaluate) { return (config, folder) }
      }
      let parent = (folder as NSString).deletingLastPathComponent
      if parent == folder || folder.isEmpty { return nil }
      folder = parent
    }
  }

  /// A config file's options. Nil only for a `package.json` without a `prettier` key, which doesn't count as a config.
  private static func load(_ path: String, name: String, folder: String, evaluate: Evaluate) -> [String: Any]? {
    let data = FileManager.default.contents(atPath: path) ?? Data()
    func shared(_ value: Any?) -> [String: Any]? {
      if let object = value as? [String: Any] { return object }
      if let module = value as? String { return evaluate(module, folder) ?? [:] }
      return nil
    }
    switch name {
    case "package.json":
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      return shared(json?["prettier"])
    case ".prettierrc", ".prettierrc.json", ".prettierrc.json5":
      if let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed, .fragmentsAllowed]) {
        return shared(json) ?? [:]
      }
      return name == ".prettierrc" ? flatYAML(String(decoding: data, as: UTF8.self)) : [:]
    case ".prettierrc.yaml", ".prettierrc.yml":
      return flatYAML(String(decoding: data, as: UTF8.self))
    default:
      return evaluate(path, folder) ?? [:]
    }
  }

  /// The top-level `key: value` lines of a YAML config (nested values, like `overrides`, are skipped).
  static func flatYAML(_ text: String) -> [String: Any] {
    var out: [String: Any] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
      guard let first = line.first, !first.isWhitespace, first != "#", first != "-",
            let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      var raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if let hash = raw.range(of: " #") { raw = raw[..<hash.lowerBound].trimmingCharacters(in: .whitespaces) }
      guard !key.isEmpty, !raw.isEmpty else { continue }
      out[key] = scalar(raw)
    }
    return out
  }

  private static func scalar(_ raw: String) -> Any {
    if raw.count >= 2, let first = raw.first, first == raw.last, first == "\"" || first == "'" {
      return String(raw.dropFirst().dropLast())
    }
    switch raw.lowercased() {
    case "true": return true
    case "false": return false
    default: return Int(raw).map { $0 as Any } ?? Double(raw).map { $0 as Any } ?? raw
    }
  }

  // MARK: EditorConfig

  /// What `.editorconfig` files above the file say, as Prettier options (indent style and size, line length, line ends).
  static func editorConfig(for file: String) -> [String: Any] {
    var properties: [String: String] = [:]
    var folder = (file as NSString).deletingLastPathComponent
    var chain: [(folder: String, text: String)] = []
    while true {
      let path = (folder as NSString).appendingPathComponent(".editorconfig")
      if let data = FileManager.default.contents(atPath: path) {
        let text = String(decoding: data, as: UTF8.self)
        chain.append((folder, text))
        if isRoot(text) { break }
      }
      let parent = (folder as NSString).deletingLastPathComponent
      if parent == folder || folder.isEmpty { break }
      folder = parent
    }
    // The outermost file first, so nearer files (and later sections) win.
    for (folder, text) in chain.reversed() {
      properties.merge(editorConfigProperties(text, relativePath: relativePath(file, in: folder))) { $1 }
    }
    return prettierOptions(fromEditorConfig: properties)
  }

  private static func isRoot(_ text: String) -> Bool {
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { return false }
      let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      if parts.count == 2, parts[0] == "root", parts[1] == "true" { return true }
    }
    return false
  }

  /// The properties of every section that matches the file, later sections winning.
  static func editorConfigProperties(_ text: String, relativePath: String) -> [String: String] {
    var out: [String: String] = [:]
    var inMatch = false
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }
      if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
        var pattern = String(trimmed.dropFirst().dropLast())
        if pattern.hasPrefix("/") { pattern.removeFirst() } else if !pattern.contains("/") { pattern = "**/" + pattern }
        inMatch = Glob.matches(pattern, relativePath)
        continue
      }
      guard inMatch else { continue }
      let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
      if parts.count == 2 { out[parts[0].lowercased()] = parts[1].lowercased() }
    }
    return out
  }

  static func prettierOptions(fromEditorConfig properties: [String: String]) -> [String: Any] {
    var out: [String: Any] = [:]
    if let style = properties["indent_style"] { out["useTabs"] = style == "tab" }
    if let size = properties["indent_size"].flatMap({ Int($0) }) ?? properties["tab_width"].flatMap({ Int($0) }) {
      out["tabWidth"] = size
    } else if properties["indent_size"] == "tab", let width = properties["tab_width"].flatMap({ Int($0) }) {
      out["tabWidth"] = width
    }
    if let length = properties["max_line_length"].flatMap({ Int($0) }) { out["printWidth"] = length }
    if let end = properties["end_of_line"], ["lf", "crlf", "cr"].contains(end) { out["endOfLine"] = end }
    return out
  }

  private static func relativePath(_ file: String, in folder: String) -> String {
    let prefix = folder.hasSuffix("/") ? folder : folder + "/"
    return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : (file as NSString).lastPathComponent
  }
}

/// Glob patterns as Prettier's `overrides` and `.editorconfig` sections use them: `*`, `**`, `?`, `{a,b}` and `[…]`.
/// A pattern without a slash matches the file's name in any folder.
public enum Glob {
  public static func matches(_ pattern: String, _ path: String) -> Bool {
    let subject = pattern.contains("/") ? path : (path as NSString).lastPathComponent
    guard let regex = try? NSRegularExpression(pattern: "^" + regexSource(pattern) + "$") else { return false }
    return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
  }

  static func regexSource(_ pattern: String) -> String {
    var out = ""
    var chars = Array(pattern)[...]
    var braces = 0
    while let c = chars.popFirst() {
      switch c {
      case "*":
        if chars.first == "*" {
          chars.removeFirst()
          if chars.first == "/" { chars.removeFirst(); out += "(?:.*/)?" } else { out += ".*" }
        } else {
          out += "[^/]*"
        }
      case "?": out += "[^/]"
      case "{": braces += 1; out += "(?:"
      case "}" where braces > 0: braces -= 1; out += ")"
      case "," where braces > 0: out += "|"
      case "[":
        if let close = chars.firstIndex(of: "]") {
          var set = String(chars[..<close])
          if set.hasPrefix("!") { set = "^" + set.dropFirst() }
          out += "[" + set.replacingOccurrences(of: "\\", with: "\\\\") + "]"
          chars = chars[chars.index(after: close)...]
        } else {
          out += "\\["
        }
      case "\\":
        if let next = chars.popFirst() { out += NSRegularExpression.escapedPattern(for: String(next)) }
      default: out += NSRegularExpression.escapedPattern(for: String(c))
      }
    }
    return out
  }
}
