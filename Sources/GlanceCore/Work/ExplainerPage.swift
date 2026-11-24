import Foundation

/// An explainer page a side Claude wrote, checked (spec 2026-11-03-explainer-mode-design.md §6.4). Claude's output is
/// untrusted, so the check refuses rather than repairs. It is the second layer: the web view's sandbox is what enforces
/// safety, and a page that fails here is never shown.
public struct ExplainerPage: Equatable, Sendable {
  public struct Beat: Equatable, Sendable {
    public let id: String
    public let title: String
    public let say: String
  }

  public enum Problem: Error, Equatable, Sendable {
    case noAnswer
    case beatCount(Int)
    case badBeatID(String)
    case repeatedBeatID(String)
    case missingHeading(String)
    case missingSay(String)
    case sayTooLong(String)
    case refused(String)
    case tooLarge
  }

  public let answer: String
  public let beats: [Beat]
  public let fragment: String

  /// The written limit is 230; one test page ran a little over.
  public static let maxSayCharacters = 260
  public static let beatRange = 1...6
  public static let maxFragmentBytes = 200_000

  public static func check(_ text: String) -> Result<ExplainerPage, Problem> {
    let fragment = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard fragment.utf8.count <= maxFragmentBytes else { return .failure(.tooLarge) }
    if let refused = refusedContent(in: fragment) { return .failure(.refused(refused)) }
    guard let answer = answerText(in: fragment), !answer.isEmpty else { return .failure(.noAnswer) }

    let starts = fragment.matches(of: #/(?i)<section\b([^>]*)>/#)
    guard beatRange.contains(starts.count) else { return .failure(.beatCount(starts.count)) }
    var beats: [Beat] = [], seen = Set<String>()
    for (index, start) in starts.enumerated() {
      guard let id = start.1.firstMatch(of: #/(?i)\bdata-beat\s*=\s*"([^"]*)"/#)?.1, isBeatID(String(id)) else {
        return .failure(.badBeatID(String(start.1.firstMatch(of: #/(?i)\bdata-beat\s*=\s*"([^"]*)"/#)?.1 ?? "")))
      }
      let beatID = String(id)
      guard seen.insert(beatID).inserted else { return .failure(.repeatedBeatID(beatID)) }
      let end = index + 1 < starts.count ? starts[index + 1].range.lowerBound : fragment.endIndex
      let body = fragment[start.range.upperBound..<end]
      guard let heading = body.firstMatch(of: #/(?is)<h2\b[^>]*>(.*?)</h2>/#).map({ plainText(String($0.1)) }), !heading.isEmpty else {
        return .failure(.missingHeading(beatID))
      }
      guard let say = body.firstMatch(of: #/(?is)<p\b[^>]*\bclass\s*=\s*"[^"]*\bsay\b[^"]*"[^>]*>(.*?)</p>/#).map({ plainText(String($0.1)) }), !say.isEmpty else {
        return .failure(.missingSay(beatID))
      }
      guard say.count <= maxSayCharacters else { return .failure(.sayTooLong(beatID)) }
      beats.append(Beat(id: beatID, title: heading, say: say))
    }
    return .success(ExplainerPage(answer: answer, beats: beats, fragment: fragment))
  }

  /// The answer sentence, as soon as it has closed in the text streaming in: a useful line long before the page.
  public static func answerSentence(inPartial text: String) -> String? {
    answerText(in: text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  public static func isBeatID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
  }

  /// What the wrapper's CSP allows: inline styles and data: fonts and images. No script from the page runs at all.
  public static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; font-src data:; img-src data:"

  /// The checked fragment in its document: the CSP comes first, ahead of anything the page says.
  public func document(css: String, dark: Bool) -> String {
    Self.wrap(fragment: fragment, css: css, dark: dark)
  }

  /// Public for the test that loads a hostile page in the real sandbox; the app only wraps checked pages.
  public static func wrap(fragment: String, css: String, dark: Bool) -> String {
    """
    <!doctype html>
    <html data-theme="\(dark ? "dark" : "light")">
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(Self.contentSecurityPolicy)">
    <style>\(css)</style>
    </head>
    <body>
    \(fragment)
    </body>
    </html>
    """
  }

  private static func answerText(in fragment: String) -> String? {
    guard let match = fragment.prefixMatch(of: #/(?is)<p\s+class="answer"\s*>(.*?)</p>/#) else { return nil }
    return plainText(String(match.1))
  }

  /// The first thing the page may not hold, or nil. Fails closed: words like these in a label refuse the page too.
  private static func refusedContent(in fragment: String) -> String? {
    // The one URL inline SVG commonly carries. It loads nothing.
    let text = fragment.replacing(#/(?i)\sxmlns(:\w+)?\s*=\s*"http:\/\/www\.w3\.org\/[^"]*"/#, with: "").lowercased()
    if let tag = text.firstMatch(of: #/<\s*\/?\s*(script|img|link|iframe|object|embed|form|input|meta|base|video|audio|source|track|frame|frameset|applet|portal|html|head|body|title|noscript|template)\b/#) {
      return "<\(tag.1)>"
    }
    if text.contains(#/<[^>]*[\s\/"']on[a-z]+\s*=/#) { return "an event handler" }
    if let attribute = text.firstMatch(of: #/<[^>]*[\s\/"'](src|srcset|srcdoc|href|xlink:href|action|formaction|background|poster|ping|manifest)\s*=/#) {
      return attribute.1 + "="
    }
    for word in ["@import", "url(", "http:", "https:", "javascript:", "file:", "ws:", "wss:", "ftp:", "image-set(", "expression("] where text.contains(word) {
      return word
    }
    return nil
  }

  /// Text from a little HTML, for the voice and the bar: tags out, the common entities decoded, spaces collapsed.
  static func plainText(_ html: String) -> String {
    var text = html.replacing(#/<[^>]*>/#, with: "")
    for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&rarr;", "→"), ("&amp;", "&")] {
      text = text.replacingOccurrences(of: entity, with: value)
    }
    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
