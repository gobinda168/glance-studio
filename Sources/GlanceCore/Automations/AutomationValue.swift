import Foundation

/// Any JSON value an automation passes around: an input, a step's json output, a trigger's payload (spec
/// 2026-10-09-automations-design.md, "The package format"). Numbers are Doubles; whole ones print without ".0".
public enum AutomationValue: Codable, Equatable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([AutomationValue])
  case object([String: AutomationValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([AutomationValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: AutomationValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// Strict JSON (no comments, no trailing commas); nil when it isn't JSON.
  public static func decode(_ data: Data) -> AutomationValue? {
    try? JSONDecoder().decode(AutomationValue.self, from: data)
  }

  /// Compact JSON with sorted keys, so the same value always prints the same.
  public var json: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
  }

  /// How the value reads inside a template: strings as they are, whole numbers without ".0", null as nothing,
  /// lists and objects as compact JSON.
  public var text: String {
    switch self {
    case .null: ""
    case .bool(let value): value ? "true" : "false"
    case .number(let value):
      value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    case .string(let value): value
    case .array, .object: json
    }
  }

  /// The value at a dot path ("items.0.title"): object keys, or list indexes for lists. An empty path is the value.
  public func value(at path: [String]) -> AutomationValue? {
    var current = self
    for key in path {
      switch current {
      case .object(let members):
        guard let next = members[key] else { return nil }
        current = next
      case .array(let items):
        guard let index = Int(key), items.indices.contains(index) else { return nil }
        current = items[index]
      default:
        return nil
      }
    }
    return current
  }

  /// The members when this is an object.
  public var object: [String: AutomationValue]? {
    if case .object(let members) = self { return members }
    return nil
  }
}
