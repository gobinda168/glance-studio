import Foundation
import Testing
@testable import GlanceCore

@Suite struct SecretScrubberTests {
  let value = "ghp_Abc/def+ghi=jkl0123"
  var scrubber: SecretScrubber { SecretScrubber(name: "GITHUB_TOKEN", value: value) }

  @Test func theRawValueIsReplacedEverywhere() {
    #expect(scrubber.scrub("a \(value) b \(value)") == "a [secret GITHUB_TOKEN] b [secret GITHUB_TOKEN]")
    #expect(scrubber.scrub("token=\(value)xyz") == "token=[secret GITHUB_TOKEN]xyz")
    #expect(scrubber.scrub("nothing here") == "nothing here")
  }

  @Test func everyListedEncodingIsCaught() throws {
    let bytes = Data(value.utf8)
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self).dropFirst().dropLast()
    let forms = [
      value,
      bytes.base64EncodedString(),
      bytes.base64EncodedString().replacingOccurrences(of: "=", with: ""),
      bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"),
      hex, hex.uppercased(),
      value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!,
      String(json),
      Data("me:\(value)".utf8).base64EncodedString(),
    ]
    for form in forms {
      #expect(!scrubber.scrub("x\(form)y").contains(form), "\(form)")
      #expect(scrubber.contains(Data("x\(form)y".utf8)), "\(form)")
    }
  }

  @Test func theValueIsCaughtAtEveryBase64Offset() {
    for prefix in ["", "a", "ab", "abc", "user:"] {
      let blob = Data((prefix + value + "tail").utf8).base64EncodedString()
      #expect(scrubber.contains(Data(blob.utf8)), "prefix \(prefix)")
      #expect(scrubber.scrub(blob).contains("[secret GITHUB_TOKEN]"), "prefix \(prefix)")
    }
  }

  // A server may answer in UTF-16 on its own (or because Claude asked for it in Accept).
  @Test func utf16FormsAreCaught() {
    let basic = "Basic " + Data("me:\(value)".utf8).base64EncodedString()
    for text in [value, "Bearer \(value)", basic] {
      for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
        let body = Data([0x7B, 0x00]) + text.data(using: encoding)! + Data([0x7D, 0x00])
        #expect(scrubber.contains(body), "\(text) \(encoding)")
        let out = scrubber.scrub(body)
        #expect(out.range(of: value.data(using: encoding)!) == nil, "\(text) \(encoding)")
        #expect(out.range(of: Data("[secret GITHUB_TOKEN]".utf8)) != nil)
      }
    }
  }

  @Test func jsonEscapedFormsAreCaughtInUTF16Too() {
    // `/` written `\/`, as some JSON encoders do.
    let escaped = value.replacingOccurrences(of: "/", with: "\\/")
    for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
      #expect(scrubber.contains(escaped.data(using: encoding)!), "\(encoding)")
    }
  }

  // UTF-16BE forms begin with 0x00, which must not make every NUL of a binary body walk the patterns.
  @Test(.timeLimit(.minutes(1))) func zeroHeavyBinaryScrubsQuickly() {
    let zeros = Data(repeating: 0, count: 20_971_520)
    let clock = ContinuousClock()
    var out = Data()
    let elapsed = clock.measure { out = scrubber.scrub(zeros) }
    #expect(elapsed < .seconds(5), "\(elapsed)")
    #expect(out == zeros)
    var mixed = Data(repeating: 0, count: 1_000)
    mixed.append(value.data(using: .utf16BigEndian)!)
    #expect(scrubber.scrub(mixed).range(of: Data("[secret GITHUB_TOKEN]".utf8)) != nil)
  }

  @Test func bytesAreScrubbedInBinaryBodiesToo() {
    var body = Data([0, 1, 2, 255])
    body.append(Data(value.utf8))
    body.append(Data([9, 9]))
    let out = scrubber.scrub(body)
    #expect(out.range(of: Data(value.utf8)) == nil)
    #expect(out.range(of: Data("[secret GITHUB_TOKEN]".utf8)) != nil)
    #expect(out.prefix(4) == Data([0, 1, 2, 255]))
  }

  @Test func ordinaryTextIsLeftAlone() {
    let text = #"{"login":"octocat","id":1,"note":"Bearer tokens look like ghp_…"}"#
    #expect(scrubber.scrub(text) == text)
  }

  // Matching is by bytes, so what sits next to the value (a combining mark, CRLF) cannot hide it.
  @Test func theValueIsCaughtNextToCombiningMarksAndLineEndings() {
    for around in ["\u{0301}", "\r\n", "\n", "\u{200D}", "\u{0301}\u{0301}"] {
      let text = "a\(around)\(value)\(around)b"
      let out = scrubber.scrub(text)
      // Checked on bytes: String.contains compares grapheme clusters, which is the very trap under test.
      #expect(Data(out.utf8).range(of: Data(value.utf8)) == nil, "around \(around.unicodeScalars.map(\.value))")
      #expect(Data(out.utf8).range(of: Data("[secret GITHUB_TOKEN]".utf8)) != nil)
      #expect(scrubber.contains(Data(text.utf8)))
    }
    #expect(scrubber.scrub("\(value)\r\n\(value)\r\n") == "[secret GITHUB_TOKEN]\r\n[secret GITHUB_TOKEN]\r\n")
  }

  @Test func lowercasePercentEscapesAreCaughtToo() {
    let upper = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let lower = upper.replacingOccurrences(of: "%2F", with: "%2f").replacingOccurrences(of: "%2B", with: "%2b")
      .replacingOccurrences(of: "%3D", with: "%3d").replacingOccurrences(of: "%5F", with: "%5f")
    #expect(lower != upper)
    #expect(scrubber.contains(Data("q=\(lower)&".utf8)))
    #expect(!scrubber.scrub("q=\(lower)&").contains(lower))
  }

  @Test func aShortValueIsStillScrubbedRaw() {
    let short = SecretScrubber(name: "PIN", value: "k9x2")
    #expect(short.scrub("pin k9x2 ok") == "pin [secret PIN] ok")
    #expect(short.contains(Data("k9x2".utf8)))
    #expect(!short.contains(Data("nothing".utf8)))
  }

  @Test func aNonAsciiValueIsCaughtRawAndAsJSONEscapes() {
    let s = SecretScrubber(name: "PW", value: "pässwörd-😀-1234")
    for form in ["pässwörd-😀-1234", #"p\u00e4ssw\u00f6rd-\ud83d\ude00-1234"#, #"p\u00E4ssw\u00F6rd-\uD83D\uDE00-1234"#,
                 "p%C3%A4ssw%C3%B6rd-%F0%9F%98%80-1234"] {
      #expect(s.contains(Data("x\(form)y".utf8)), "\(form)")
      #expect(s.scrub("x\(form)y") == "x[secret PW]y", "\(form)")
    }
  }

  // RFC 3986 / encodeURIComponent / Python quote(safe="") / Go QueryEscape leave "-._~" literal and escape "/+=".
  @Test func percentEncodingAsServersEmitItIsCaught() {
    let forms = [
      "ghp_Abc%2Fdef%2Bghi%3Djkl0123",       // RFC 3986 / encodeURIComponent
      "ghp_Abc%2fdef%2bghi%3djkl0123",       // lowercase hex
      "ghp_Abc%2Fdef%2bghi%3Djkl0123",       // mixed case within one value
      "ghp%5FAbc%2Fdef%2Bghi%3Djkl0123",     // underscore escaped too
      "ghp_Abc/def%2Bghi=jkl0123",           // only some bytes escaped
      "%67%68%70%5F%41%62%63%2F%64%65%66%2B%67%68%69%3D%6A%6B%6C%30%31%32%33", // every byte escaped
    ]
    for form in forms {
      let body = "q=\(form)&x=1"
      #expect(scrubber.contains(Data(body.utf8)), "\(form)")
      let out = Data(scrubber.scrub(body).utf8)
      #expect(out.range(of: Data("[secret GITHUB_TOKEN]".utf8)) != nil, "\(form)")
      #expect(scrubber.scrub(body) == "q=[secret GITHUB_TOKEN]&x=1", "\(form)")
    }
    let spaced = SecretScrubber(name: "PW", value: "correct horse battery")
    #expect(spaced.scrub("p=correct+horse+battery!") == "p=[secret PW]!")
    #expect(spaced.scrub("p=correct%20horse%20battery!") == "p=[secret PW]!")
    #expect(!scrubber.contains(Data("ghp_Abc%2Fdef%2Bghi%3Djkl0124".utf8)))
    #expect(!scrubber.contains(Data("ghp_Abc%2".utf8)))
  }

  // Go's json.Marshal writes & < > as \u0026 \u003c \u003e and U+2028/2029 as \u2028/\u2029.
  @Test func goHTMLSafeJSONEscapesAreCaught() {
    let s = SecretScrubber(name: "TOK", value: "tok&en<12>3456\u{2028}x")
    for form in [#"tok\u0026en\u003c12\u003e3456\u2028x"#, #"tok\u0026en\u003C12\u003E3456\u2028x"#, "tok&en<12>3456\u{2028}x"] {
      #expect(s.contains(Data("{\"a\":\"\(form)\"}".utf8)), "\(form)")
      #expect(s.scrub("{\"a\":\"\(form)\"}") == "{\"a\":\"[secret TOK]\"}", "\(form)")
    }
    let plain = SecretScrubber(name: "TOK", value: "tok&en<12>3456")
    #expect(plain.scrub(#"{"a":"tok\u0026en\u003c12\u003e3456"}"#) == #"{"a":"[secret TOK]"}"#)
  }

  @Test func manyOccurrencesScrubInOnePass() {
    let unit = "id=\(value)&"
    let body = Data(String(repeating: unit, count: 200_000).utf8)
    #expect(body.count > 5_000_000)
    let clock = ContinuousClock()
    var out = Data()
    let elapsed = clock.measure { out = scrubber.scrub(body) }
    #expect(elapsed < .seconds(5), "\(elapsed)")
    #expect(out.range(of: Data(value.utf8)) == nil)
    #expect(out == Data(String(repeating: "id=[secret GITHUB_TOKEN]&", count: 200_000).utf8))
    let found = clock.measure { _ = scrubber.contains(Data(String(repeating: "abcdefgh", count: 600_000).utf8)) }
    #expect(found < .seconds(5), "\(found)")
  }

  @Test func theMarkerNamesTheSecret() {
    #expect(scrubber.marker == "[secret GITHUB_TOKEN]")
  }

  @Test func anEmptyValueScrubsNothing() {
    let empty = SecretScrubber(name: "X", value: "")
    #expect(empty.scrub("abc") == "abc")
    #expect(!empty.contains(Data("abc".utf8)))
  }
}
