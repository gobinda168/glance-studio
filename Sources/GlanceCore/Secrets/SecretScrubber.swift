import Foundation

/// Takes a secret's value out of anything that goes back to Claude (spec "Request flow", step 7): the value raw, hex,
/// JSON-escaped (Foundation, Python `ensure_ascii`, Go's HTML-safe `\u0026`), percent-encoded in any mix of escaped and
/// literal bytes, and base64 (standard and URL-safe) at any byte offset, so it is caught inside a longer blob too
/// (Basic auth's `user:value` among them); the value and its base64 also in UTF-16 (LE and BE). Each is replaced by
/// `[secret NAME]`.
///
/// Everything here works on UTF-8 bytes, never on `Character`s: Swift folds "\r\n" and combining marks into one
/// grapheme, which would let a value next to one slip past a text scan. Scrubbing is one forward pass, so a body
/// with a hundred thousand occurrences costs no more per occurrence than one with a single one.
public struct SecretScrubber: Sendable {
  public let marker: String
  /// Fixed forms (raw, hex, JSON, base64 fragments). Longest first.
  let patterns: [[UInt8]]
  /// The value's own bytes, matched leniently: each may appear literally or as `%hh` (either case), a space also as `+`.
  let valueBytes: [UInt8]
  /// Which bytes can begin a match, to skip most of a body without further work.
  let starts: [Bool]
  /// For a NUL start byte: which bytes may follow it in a match.
  let afterNul: [Bool]

  public init(name: String, value: String) {
    marker = "[secret \(name)]"
    let bytes = Data(value.utf8)
    // The value itself and its direct encodings are always kept, however short. Only the derived base64 fragments
    // need a minimum length, or a tiny value would match everywhere.
    var forms: Set<String> = [value]
    forms.insert(bytes.map { String(format: "%02x", $0) }.joined())
    forms.insert(bytes.map { String(format: "%02X", $0) }.joined())
    var json: Set<String> = []
    for options in [JSONEncoder.OutputFormatting(), .withoutEscapingSlashes] {
      let encoder = JSONEncoder()
      encoder.outputFormatting = options
      if let data = try? encoder.encode(value) { json.insert(String(decoding: data.dropFirst().dropLast(), as: UTF8.self)) }
    }
    for asciiOnly in [false, true] {
      for htmlSafe in [false, true] {
        for escapeSlash in [false, true] {
          for upperHex in [false, true] {
            json.insert(Self.jsonEscaped(value, asciiOnly: asciiOnly, htmlSafe: htmlSafe, escapeSlash: escapeSlash, upperHex: upperHex))
          }
        }
      }
    }
    forms.formUnion(json)
    // The value, its JSON escapes and its base64 fragments (which cover Basic's `user:value`) also in UTF-16, either
    // byte order: a server may answer in UTF-16 on its own.
    var wide: [String] = [value] + json
    for fragment in Self.base64Fragments(bytes) where fragment.utf8.count >= 6 {
      let urlSafe = fragment.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      forms.insert(fragment)
      forms.insert(urlSafe)
      wide += [fragment, urlSafe]
    }
    var bytePatterns = Set(forms.filter { !$0.isEmpty }.map { Array($0.utf8) })
    for text in wide where !text.isEmpty {
      bytePatterns.insert(text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
      bytePatterns.insert(text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
    }
    patterns = bytePatterns.sorted { $0.count > $1.count }
    valueBytes = Array(bytes)
    var starts = [Bool](repeating: false, count: 256)
    // UTF-16BE forms begin with 0x00: a NUL is only worth a look when the byte after it can follow one.
    var afterNul = [Bool](repeating: false, count: 256)
    for pattern in patterns {
      starts[Int(pattern[0])] = true
      guard pattern[0] == 0 else { continue }
      if pattern.count > 1 { afterNul[Int(pattern[1])] = true } else { afterNul = Array(repeating: true, count: 256) }
    }
    if let first = valueBytes.first {
      starts[Int(first)] = true
      starts[Int(UInt8(ascii: "%"))] = true
      if first == UInt8(ascii: " ") { starts[Int(UInt8(ascii: "+"))] = true }
      // A value that itself begins with NUL can start at any NUL.
      if first == 0 { afterNul = Array(repeating: true, count: 256) }
    }
    self.starts = starts
    self.afterNul = afterNul
  }

  /// Whether a match could begin at `i`: the cheap test run on every byte.
  @inline(__always) private func mayStart(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> Bool {
    let byte = buf[i]
    guard starts[Int(byte)] else { return false }
    return byte != 0 || (i + 1 < buf.count && afterNul[Int(buf[i + 1])])
  }

  /// For each of the three byte offsets, the base64 characters that depend only on the value's bits: present
  /// whenever the value is base64-encoded inside anything.
  static func base64Fragments(_ bytes: Data) -> [String] {
    (0..<3).compactMap { offset in
      let encoded = Array((Data(repeating: 0, count: offset) + bytes).base64EncodedString())
      let start = (8 * offset + 5) / 6
      let end = (8 * (offset + bytes.count)) / 6
      return end > start ? String(encoded[start..<end]) : nil
    }
  }

  /// The value as the inside of a JSON string, the way the common encoders write it: `asciiOnly` writes every
  /// non-ASCII scalar `\uXXXX` (surrogate pairs above the BMP, as Python's json.dumps does); `htmlSafe` writes
  /// `& < >` and U+2028/2029 as `\u00XX` (as Go's json.Marshal does); `escapeSlash` writes `\/`.
  static func jsonEscaped(_ value: String, asciiOnly: Bool, htmlSafe: Bool, escapeSlash: Bool, upperHex: Bool) -> String {
    func unicode(_ unit: UInt16) -> String { String(format: upperHex ? "\\u%04X" : "\\u%04x", unit) }
    var out = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "/" where escapeSlash: out += "\\/"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "&", "<", ">": if htmlSafe { out += unicode(UInt16(scalar.value)) } else { out.unicodeScalars.append(scalar) }
      case "\u{2028}", "\u{2029}": if htmlSafe || asciiOnly { out += unicode(UInt16(scalar.value)) } else { out.unicodeScalars.append(scalar) }
      default:
        if scalar.value < 0x20 {
          out += unicode(UInt16(scalar.value))
        } else if asciiOnly && !scalar.isASCII {
          for unit in String(scalar).utf16 { out += unicode(unit) }
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }

  /// How many bytes of `buf` from `i` are the value, in any mix of literal and `%hh` bytes; 0 when they are not.
  private func percentMatchLength(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
    guard !valueBytes.isEmpty else { return 0 }
    let n = buf.count
    var j = i
    for b in valueBytes {
      guard j < n else { return 0 }
      let c = buf[j]
      if c == UInt8(ascii: "%"), j + 2 < n, let h = Self.hexValue(buf[j + 1]), let l = Self.hexValue(buf[j + 2]), h << 4 | l == b {
        j += 3
      } else if c == b || (b == UInt8(ascii: " ") && c == UInt8(ascii: "+")) {
        j += 1
      } else {
        return 0
      }
    }
    return j - i
  }

  /// The length of the longest form of the value that starts at `i`, or 0.
  private func matchLength(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
    var best = percentMatchLength(buf, at: i)
    let n = buf.count
    for pattern in patterns {
      let count = pattern.count
      if count <= best { break }
      guard i + count <= n else { continue }
      var k = 0
      while k < count, buf[i + k] == pattern[k] { k += 1 }
      if k == count { best = count }
    }
    return best
  }

  public func contains(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    return bytes.withUnsafeBufferPointer { buf in
      for i in 0..<buf.count where mayStart(buf, at: i) && matchLength(buf, at: i) > 0 { return true }
      return false
    }
  }

  public func scrub(_ data: Data) -> Data {
    let bytes = [UInt8](data)
    let replacement = Array(marker.utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var replaced = false
    bytes.withUnsafeBufferPointer { buf in
      var gapStart = 0
      var i = 0
      while i < buf.count {
        if mayStart(buf, at: i) {
          let length = matchLength(buf, at: i)
          if length > 0 {
            out.append(contentsOf: buf[gapStart..<i])
            out.append(contentsOf: replacement)
            replaced = true
            i += length
            gapStart = i
            continue
          }
        }
        i += 1
      }
      if replaced { out.append(contentsOf: buf[gapStart..<buf.count]) }
    }
    return replaced ? Data(out) : data
  }

  public func scrub(_ text: String) -> String { String(decoding: scrub(Data(text.utf8)), as: UTF8.self) }
}
