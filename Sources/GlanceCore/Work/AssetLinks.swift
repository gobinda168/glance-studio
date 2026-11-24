import Foundation

/// The images and videos a PR description or comment shows, found in its text. The body is written by anyone who can
/// comment, so this is the gate in front of the download: it hands back only https links to public hosts, in the places
/// GitHub itself renders media from, and never anything a reader would not see as a picture or video.
public enum AssetLinks {
  /// Media links in order of first mention, each once.
  ///
  /// Found: a markdown image, `<img src>`, `<video src>` and `<source src>`, and a user-attachments URL alone on its line
  /// (how GitHub embeds an uploaded video). Skipped: fenced blocks, inline code, HTML comments, plain links, and any
  /// link that is not `https`, carries credentials or a port, points at a private or local host, or names a file that
  /// is not media (an image tag around a `.pdf` does not make it one).
  public static func find(in body: String) -> [URL] {
    let text = withoutCodeAndComments(body)
    let whole = NSRange(text.startIndex..., in: text)
    var hits: [(at: Int, raw: String, bare: Bool)] = []
    for match in markdownImage.matches(in: text, range: whole) {
      if let raw = group(match, 1, in: text) { hits.append((match.range.location, raw, false)) }
    }
    for match in htmlSource.matches(in: text, range: whole) {
      for index in 1...3 {
        if let raw = group(match, index, in: text) {
          hits.append((match.range.location, raw.replacingOccurrences(of: "&amp;", with: "&"), false))
          break
        }
      }
    }
    for match in bareLine.matches(in: text, range: whole) {
      if let raw = group(match, 1, in: text) { hits.append((match.range.location, raw, true)) }
    }
    var seen = Set<String>()
    var out: [URL] = []
    for hit in hits.sorted(by: { $0.at < $1.at }) {
      guard let url = mediaURL(hit.raw), !hit.bare || isGitHubAttachment(url), seen.insert(url.absoluteString).inserted else { continue }
      out.append(url)
    }
    return out
  }

  /// A GitHub upload that is media: `https://github.com/user-attachments/assets/<id>`, the host and the whole path
  /// compared exactly. A `..` (also percent-encoded), a lookalike host, another port, credentials or an extra path
  /// segment is refused, and so is `/user-attachments/files/` (any file type, not media).
  public static func isGitHubAttachment(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, !url.path.contains("\\") else { return false }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts[0].isEmpty, parts[1] == "user-attachments", parts[2] == "assets" else { return false }
    let id = parts[3]
    return !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
  }

  /// Whether `url` passes the rules `find` applies to a link: https, a public name, no credentials or port, GitHub's own
  /// upload paths exact, and a media extension or none. A redirect target faces the same test.
  public static func allows(_ url: URL) -> Bool { mediaURL(url.absoluteString) != nil }

  // MARK: Patterns

  private static let markdownImage = try! NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#)
  private static let htmlSource = try! NSRegularExpression(
    pattern: #"<(?:img|video|source)\b[^>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#, options: [.caseInsensitive])
  private static let bareLine = try! NSRegularExpression(
    pattern: #"^[ \t]*(https://[^\s<>"']+)[ \t]*$"#, options: [.anchorsMatchLines])
  private static let htmlComment = try! NSRegularExpression(pattern: #"<!--[\s\S]*?-->"#)

  private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    let range = match.range(at: index)
    guard range.location != NSNotFound, let r = Range(range, in: text) else { return nil }
    return String(text[r])
  }

  // MARK: Validation

  private static let privateSuffixes: Set<String> = ["local", "localhost", "internal", "lan", "home", "corp", "intranet", "private",
                                                     "localdomain"]

  /// The URL when `raw` is an https link a PR may legitimately show as media.
  private static func mediaURL(_ raw: String) -> URL? {
    guard raw.count <= 2_048, !raw.contains(where: { $0.isWhitespace || $0.isNewline || $0.unicodeScalars.contains { $0.value < 0x20 } }),
          let url = URL(string: raw), url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
          url.port == nil || url.port == 443, let host = url.host?.lowercased(), isPublicHost(host) else { return nil }
    // GitHub's own upload paths are all-or-nothing: an asset, or not media.
    if host == "github.com" || host == "www.github.com", url.path.lowercased().hasPrefix("/user-attachments") {
      return isGitHubAttachment(url) ? url : nil
    }
    let ext = url.pathExtension.lowercased()
    guard ext.isEmpty || AssetGroups.mediaExtensions.contains(ext) else { return nil }
    return url
  }

  /// A name on the public internet: dotted, ending in letters, not an IP address, not a local or internal name.
  static func isPublicHost(_ host: String) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }),
          let tld = labels.last, tld.count >= 2, tld.first?.isLetter == true, !privateSuffixes.contains(tld) else { return false }
    return true
  }

  // MARK: Code and comments

  /// The body with fenced blocks, inline code and HTML comments blanked out (newlines kept, so lines stay lines).
  private static func withoutCodeAndComments(_ body: String) -> String {
    // PR bodies are often CRLF, and Swift reads CR-LF as one Character that is not "\n": make every line end "\n" first.
    let body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    var lines: [String] = []
    var fence: (char: Character, length: Int)?
    for line in body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
      let indent = line.prefix(while: { $0 == " " }).count
      let rest = line.dropFirst(indent)
      let run = rest.prefix(while: { $0 == rest.first && ($0 == "`" || $0 == "~") }).count
      if let open = fence {
        // A closing fence: the same character, at least as long, and nothing after it.
        if indent < 4, rest.first == open.char, run >= open.length, rest.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) {
          fence = nil
        }
        lines.append("")
      } else if indent < 4, run >= 3, !(rest.first == "`" && rest.dropFirst(run).contains("`")) {
        fence = (rest.first!, run)
        lines.append("")
      } else {
        lines.append(line)
      }
    }
    // Inline code never crosses a blank line.
    var paragraphs: [String] = []
    var current: [String] = []
    func flush() {
      if !current.isEmpty { paragraphs.append(blankingInlineCode(current.joined(separator: "\n"))); current = [] }
    }
    for line in lines {
      if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" }) { flush(); paragraphs.append(line) } else { current.append(line) }
    }
    flush()
    let joined = paragraphs.joined(separator: "\n")
    // A paragraph and its blank neighbours were joined with one newline each, which is what split them.
    return htmlComment.stringByReplacingMatches(in: joined, range: NSRange(joined.startIndex..., in: joined), withTemplate: " ")
  }

  /// Backtick runs pair with the next run of the same length; the code between them (and the ticks) is blanked.
  private static func blankingInlineCode(_ text: String) -> String {
    let chars = Array(text)
    var out = chars
    var i = 0
    while i < chars.count {
      guard chars[i] == "`" else { i += 1; continue }
      var end = i
      while end < chars.count, chars[end] == "`" { end += 1 }
      let length = end - i
      var j = end
      var close: Int?
      while j < chars.count {
        guard chars[j] == "`" else { j += 1; continue }
        var k = j
        while k < chars.count, chars[k] == "`" { k += 1 }
        if k - j == length { close = k; break }
        j = k
      }
      if let close {
        for n in i..<close where out[n] != "\n" { out[n] = " " }
        i = close
      } else {
        i = end
      }
    }
    return String(out)
  }
}
