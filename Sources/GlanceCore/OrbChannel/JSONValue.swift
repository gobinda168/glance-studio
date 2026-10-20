import CoreFoundation
import Foundation

/// Any JSON value as a Sendable value type (spec 2026-10-09-orb-channel-design.md): MCP messages and the orb
/// channel's wire carry free-form JSON (tool arguments, results). Written with sorted keys, so text is stable.
public enum JSONValue: Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// From what JSONSerialization returns; anything it can't return is null.
  public init(any value: Any?) {
    switch value {
    case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
    case let number as NSNumber: self = .number(number.doubleValue)
    case let string as String: self = .string(string)
    case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
    case let object as [String: Any]: self = .object(object.mapValues { JSONValue(any: $0) })
    default: self = .null
    }
  }

  /// For JSONSerialization: whole numbers as Int, so `1` doesn't become `1.0`.
  public var any: Any {
    switch self {
    case .null: return NSNull()
    case .bool(let value): return value
    case .number(let value):
      if value == value.rounded(), abs(value) < 9e15 { return Int(value) }
      return value
    case .string(let value): return value
    case .array(let values): return values.map(\.any)
    case .object(let values): return values.mapValues(\.any)
    }
  }

  public static func parse(_ text: String) -> JSONValue? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    else { return nil }
    return JSONValue(any: object)
  }

  /// One line, keys sorted.
  public var text: String {
    let data = (try? JSONSerialization.data(withJSONObject: any,
                                            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  public subscript(key: String) -> JSONValue? {
    if case .object(let values) = self { values[key] } else { nil }
  }

  public var string: String? { if case .string(let value) = self { value } else { nil } }
  public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
  public var array: [JSONValue]? { if case .array(let values) = self { values } else { nil } }
  public var object: [String: JSONValue]? { if case .object(let values) = self { values } else { nil } }
  /// A whole number, else nil.
  public var int: Int? {
    guard case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 else { return nil }
    return Int(value)
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(floatLiteral value: Double) { self = .number(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
  public init(nilLiteral: ()) { self = .null }
}
