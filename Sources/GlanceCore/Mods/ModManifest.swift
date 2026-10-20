import Foundation

/// A value a mod's setting holds (Claude Code's `userConfig` types).
public enum ModValue: Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)

  /// What goes into settings.json.
  public var json: Any {
    switch self {
    case .string(let value): value
    case .number(let value): value
    case .bool(let value): value
    }
  }

  /// The value read back from parsed JSON; nil for anything a setting can't hold (arrays, objects, null).
  init?(json: Any) {
    if let number = json as? NSNumber {
      self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
    } else if let string = json as? String {
      self = .string(string)
    } else {
      return nil
    }
  }

  /// How the value reads in a text field.
  public var text: String {
    switch self {
    case .string(let value): value
    case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
    case .bool(let value): value ? "true" : "false"
    }
  }
}

/// A mod's `.claude-plugin/plugin.json`: what the Mods page shows, and the settings it draws a form for (`userConfig`).
public struct ModManifest: Equatable, Sendable {
  /// One `userConfig` field: a row in the mod's form.
  public struct Field: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case string, number, boolean, directory, file }

    public var id: String { key }
    public let key: String
    public let kind: Kind
    public let title: String
    public let detail: String
    public let defaultValue: ModValue?
    /// A string field's allowed values, drawn as a menu.
    public let options: [String]
    public let required: Bool
    /// Kept by Claude Code in the keychain: the page leaves it to `/plugin`.
    public let sensitive: Bool
    public let minimum: Double?
    public let maximum: Double?
  }

  public let name: String
  public let version: String?
  public let detail: String
  public let fields: [Field]

  /// "glance-status" reads "Glance status".
  public var displayName: String {
    let words = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// Letters, digits, `-` and `_`, starting with a letter or digit: safe as a folder name and a settings key.
  public static func isValid(name: String) -> Bool {
    guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
    let alnum = CharacterSet.alphanumerics
    guard alnum.contains(first), first.isASCII else { return false }
    return name.unicodeScalars.allSatisfy { $0.isASCII && (alnum.contains($0) || $0 == "-" || $0 == "_") }
  }

  /// Nil when `data` isn't a plugin manifest with a usable name.
  public init?(data: Data) {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = root["name"] as? String, Self.isValid(name: name) else { return nil }
    self.name = name
    version = root["version"] as? String
    detail = (root["description"] as? String) ?? ""
    let config = (root["userConfig"] as? [String: Any]) ?? [:]
    fields = config.keys.sorted().compactMap { key in
      (config[key] as? [String: Any]).flatMap { Field(key: key, spec: $0) }
    }
  }
}

extension ModManifest.Field {
  /// Nil for a field the page can't draw (a list, or a type it doesn't know).
  init?(key: String, spec: [String: Any]) {
    guard let kind = Kind(rawValue: (spec["type"] as? String) ?? "string"), (spec["multiple"] as? Bool) != true else {
      return nil
    }
    self.key = key
    self.kind = kind
    title = (spec["title"] as? String) ?? key
    detail = (spec["description"] as? String) ?? ""
    options = ((spec["options"] as? [Any]) ?? []).compactMap { $0 as? String }
    required = (spec["required"] as? Bool) ?? false
    sensitive = (spec["sensitive"] as? Bool) ?? false
    minimum = (spec["min"] as? NSNumber)?.doubleValue
    maximum = (spec["max"] as? NSNumber)?.doubleValue
    defaultValue = spec["default"].flatMap(ModValue.init(json:))
  }

  /// Whether `text` is a value this field accepts, and the value; nil for text it refuses.
  public func value(from text: String) -> ModValue? {
    switch kind {
    case .string, .directory, .file:
      return options.isEmpty || options.contains(text) ? .string(text) : nil
    case .number:
      guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
      if let minimum, number < minimum { return nil }
      if let maximum, number > maximum { return nil }
      return .number(number)
    case .boolean:
      return text == "true" ? .bool(true) : text == "false" ? .bool(false) : nil
    }
  }
}
