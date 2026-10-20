import Foundation

/// The JSON object in a Claude answer: Claude is asked for "only JSON" but may still wrap it in a ``` fence or a
/// sentence. Used by the quick-reply panel's resolve and send runs.
public enum ClaudeJSON {
  /// The first balanced top-level JSON object in `text` (inside a ``` fence or prose), parsed.
  public static func object(in text: String) -> [String: Any]? {
    let bytes = Array(text.utf8)
    var start = 0
    while let open = bytes[start...].firstIndex(of: UInt8(ascii: "{")) {
      if let close = balancedEnd(bytes, from: open),
         let object = try? JSONSerialization.jsonObject(with: Data(bytes[open...close])) as? [String: Any] {
        return object
      }
      start = open + 1
    }
    return nil
  }

  /// The index of the `}` that closes the `{` at `open`, skipping braces inside strings; nil when it never closes.
  private static func balancedEnd(_ bytes: [UInt8], from open: Int) -> Int? {
    var depth = 0
    var inString = false
    var escaped = false
    for index in open..<bytes.count {
      let byte = bytes[index]
      if inString {
        if escaped { escaped = false }
        else if byte == UInt8(ascii: "\\") { escaped = true }
        else if byte == UInt8(ascii: "\"") { inString = false }
        continue
      }
      switch byte {
      case UInt8(ascii: "\""): inString = true
      case UInt8(ascii: "{"): depth += 1
      case UInt8(ascii: "}"):
        depth -= 1
        if depth == 0 { return index }
      default: break
      }
    }
    return nil
  }
}
