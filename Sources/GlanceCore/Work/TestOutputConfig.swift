import Foundation

/// The folders a project's test config says it writes screenshots and videos to, so Assets can show them without the
/// project being told to (spec §2.5: "any `outputDir` the project's test config names").
///
/// This reads text, it doesn't run the config: Playwright's `outputDir` and Cypress's `videosFolder` and
/// `screenshotsFolder` when they are string literals. A value built by code (`path.join(__dirname, 'x')`, a template with
/// `${…}`) is skipped, as a config this can't read is the same as a config that names nothing.
///
/// Values are returned as written, relative to the config's own folder; the caller decides what is safe to open.
public enum TestOutputConfig {
  /// Only this much of a config is read: a config is short, and a generated bundle is not one.
  public static let readLimit = 64 * 1024
  private static let names = "outputDir|videosFolder|screenshotsFolder"

  public static func folders(inConfig text: String) -> [String] {
    let code = withoutComments(String(text.prefix(readLimit)))
    let pattern = "(?<![A-Za-z0-9_$.])[\"']?(?:\(names))[\"']?\\s*:\\s*(?:\"([^\"\\\\\\n]*)\"|'([^'\\\\\\n]*)'|`([^`\\\\\\n]*)`)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(code.startIndex..., in: code)
    var found: [String] = []
    for match in expression.matches(in: code, range: whole) {
      for group in 1...3 {
        guard let range = Range(match.range(at: group), in: code) else { continue }
        let value = String(code[range]).trimmingCharacters(in: .whitespaces)
        if !value.isEmpty, !value.contains("${"), !found.contains(value) { found.append(value) }
      }
    }
    return found
  }

  /// `// …` and `/* … */` removed outside strings (a `//` inside a URL string stays).
  static func withoutComments(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var i = 0
    var quote: Unicode.Scalar?
    while i < scalars.count {
      let c = scalars[i]
      if let open = quote {
        out.append(c)
        if c == "\\", i + 1 < scalars.count { out.append(scalars[i + 1]); i += 2; continue }
        if c == open { quote = nil }
        i += 1
      } else if c == "\"" || c == "'" || c == "`" {
        quote = c; out.append(c); i += 1
      } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "/" {
        while i < scalars.count, scalars[i] != "\n" { i += 1 }
      } else if c == "/", i + 1 < scalars.count, scalars[i + 1] == "*" {
        i += 2
        while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
        i += 2
        out.append(" ")
      } else {
        out.append(c); i += 1
      }
    }
    return String(out)
  }
}
