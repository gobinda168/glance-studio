import Darwin
import Foundation

/// The checks a call passes before the secret is added (spec "Request flow", steps 3–4), and where redirects and
/// files may go. Every refusal is a sentence Claude can act on, and none echoes a value.
///
/// Claude is treated as hostile here: every URL, header name, header value and path is crafted to send the token
/// somewhere Claude can read it, or to read and write files outside its folder. All text checks run on unicode
/// scalars, never Characters (Swift folds "\r\n" into one Character).
public enum SecretRequestPolicy {
  public static let methods: Set<String> = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"]
  static let reserved: Set<String> = ["authorization", "proxy-authorization", "host", "content-length",
                                      "transfer-encoding", "connection"]
  /// Headers that would make the response come back compressed in a way URLSession doesn't undo, in pieces, or
  /// re-encoded: an echo of the secret's header would then pass the scrubber. Glance leaves them to URLSession.
  static let encodingHeaders: Set<String> = ["accept-encoding", "range", "if-range", "te", "accept-charset"]
  /// The response encodings URLSession decodes before the scrubber sees the body (and none or "identity").
  public static let readableEncodings: Set<String> = ["", "identity", "gzip", "x-gzip", "deflate", "br"]
  /// Character sets the scrubber can read the value in: UTF-8 and UTF-16, and the single-byte sets that write an
  /// ASCII value as its ASCII bytes.
  static let readableCharsets: Set<String> = ["utf-8", "us-ascii", "utf-16", "utf-16le", "utf-16be"]

  public enum Refusal: Error, Equatable, Sendable {
    case badURL, notHTTPS, userInfo
    case refusedHost(String)
    case hostNotAllowed(host: String, allowed: [String])
    case headerNotAllowed(String)
    case encodingHeader(String)
    case acceptCharset
    case badHeader(String)
    case pathOutsideFolder(String)
    case noFolder

    public func message(secret: String) -> String {
      switch self {
      case .badURL: "That isn't a URL Glance can send to (use https:// and an ASCII or xn-- host)."
      case .notHTTPS: "\(secret) is only sent over https://."
      case .userInfo: "URLs with user@ or user:password@ aren't allowed."
      case .refusedHost(let host): "\(secret) is never sent to local or private addresses (\(SecretRequestPolicy.display(host)))."
      case .hostNotAllowed(let host, let allowed):
        "\(secret) isn't allowed for \(SecretRequestPolicy.display(host)) (allowed: \(allowed.joined(separator: ", ")))."
      case .headerNotAllowed(let name): "You can't set \(SecretRequestPolicy.display(name)): Glance adds \(secret)'s header itself."
      case .encodingHeader(let name):
        "You can't set \(SecretRequestPolicy.display(name)): Glance asks for the response whole and readable, to keep \(secret) out of it."
      case .acceptCharset:
        "Accept can't name a character set: Glance asks for the response in one it can check, to keep \(secret) out of it."
      case .badHeader(let name): "The header \(SecretRequestPolicy.display(name)) has a bad name or a line break in its value."
      case .pathOutsideFolder(let path): "\(SecretRequestPolicy.display(path)) must be a file inside this session's project folder."
      case .noFolder: "Glance couldn't verify this session's folder, so it can't read or write files for it."
      }
    }
  }

  /// Text Claude supplied, made safe to show: control and line-break scalars become \u{…}, and long text is cut.
  static func display(_ text: String) -> String {
    var out = ""
    for scalar in text.unicodeScalars.prefix(200) {
      let v = scalar.value
      if v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2028 || v == 0x2029 {
        out += "\\u{" + String(v, radix: 16, uppercase: true) + "}"
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
    return text.unicodeScalars.count > 200 ? out + "…" : out
  }

  public static func checkURL(_ text: String, record: SecretRecord) -> Result<URL, Refusal> {
    // Printable ASCII only, no space and no backslash: parsers disagree about what those mean, and a URL that two
    // parsers read differently is how a token reaches the wrong host.
    guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F && $0 != "\\" }),
          let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          let host = url.host(percentEncoded: true), !host.isEmpty else { return .failure(.badURL) }
    guard scheme == "https" else { return .failure(.notHTTPS) }
    // `user@` in the authority, read from the text itself as well as from the parsed URL.
    guard url.user == nil, url.password == nil, !authority(of: text).contains("@") else { return .failure(.userInfo) }
    // The host must be the same to every reader of this URL.
    guard let components = URLComponents(string: text), let other = components.host,
          other.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) == host.lowercased(),
          components.port.map({ (1...65535).contains($0) }) ?? true else { return .failure(.badURL) }
    let shown = host.contains(":") ? "[\(host)]" : host
    guard let normalized = SecretHostRule.normalize(host) else { return .failure(.badURL) }
    guard !SecretHostRule.isRefused(normalized) else { return .failure(.refusedHost(shown)) }
    guard SecretHostRule.allows(host: normalized, patterns: record.hosts) else {
      return .failure(.hostNotAllowed(host: normalized, allowed: record.hosts))
    }
    return .success(url)
  }

  /// The text between `//` and the first `/`, `?` or `#`.
  private static func authority(of text: String) -> Substring {
    guard let marker = text.range(of: "//") else { return "" }
    return text[marker.upperBound...].prefix { $0 != "/" && $0 != "?" && $0 != "#" }
  }

  public static func checkHeaders(_ headers: [String: String], record: SecretRecord) -> Refusal? {
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      guard SecretRecord.isToken(name), !SecretRecord.hasLineBreak(value) else { return .badHeader(name) }
      let lower = name.lowercased()
      if reserved.contains(lower) || lower == record.slot.headerName.lowercased() { return .headerNotAllowed(name) }
      if encodingHeaders.contains(lower) { return .encodingHeader(name) }
      if lower == "accept", value.lowercased().contains("charset") { return .acceptCharset }
    }
    return nil
  }

  /// The `Content-Encoding` a response came back in, when the scrubber couldn't read its body (nil when it can).
  /// Only one token is readable: CFNetwork decodes by the first token of a list alone, so `gzip, gzip` or
  /// `identity, gzip` would come back still compressed. Only space and tab are trimmed (HTTP's whitespace); any
  /// non-ASCII scalar (U+00A0 before `gzip`, say, which CFNetwork doesn't decode) is refused.
  public static func unreadableEncoding(_ header: String?) -> String? {
    guard let header else { return nil }
    guard header.unicodeScalars.allSatisfy(\.isASCII) else { return header }
    let token = header.trimmingCharacters(in: httpSpace).lowercased()
    return token.contains(",") || !readableEncodings.contains(token) ? header : nil
  }

  /// The `charset` a response's `Content-Type` declares, when the scrubber couldn't read the value in it (nil when it
  /// can, or none is declared). Every `charset=` parameter is checked, without case or quotes, the first segment too
  /// (a bare `charset=utf-7`). A comma (two values) or any non-ASCII scalar refuses the whole header.
  public static func unreadableCharset(_ contentType: String?) -> String? {
    guard let contentType else { return nil }
    guard contentType.unicodeScalars.allSatisfy(\.isASCII), !contentType.contains(",") else { return contentType }
    for (index, parameter) in contentType.split(separator: ";", omittingEmptySubsequences: false).enumerated() {
      guard index > 0 || parameter.contains("=") else { continue }
      let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair[0].trimmingCharacters(in: httpSpace).lowercased() == "charset" else { continue }
      let charset = pair.count > 1
        ? pair[1].trimmingCharacters(in: httpSpace).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) : ""
      if !readableCharset(charset.lowercased()) { return charset }
    }
    return nil
  }

  /// HTTP's optional whitespace: space and tab only (CharacterSet.whitespaces would also strip Unicode spaces).
  private static let httpSpace = CharacterSet(charactersIn: " \t")

  private static func readableCharset(_ charset: String) -> Bool {
    if readableCharsets.contains(charset) { return true }
    let iso = (1...16).map { "iso-8859-\($0)" }
    let windows = (0...8).map { "windows-125\($0)" }
    return iso.contains(charset) || windows.contains(charset)
  }

  public static func mayFollow(redirectTo url: URL, record: SecretRecord) -> Bool {
    guard url.user == nil, url.password == nil else { return false }
    return (try? checkURL(url.absoluteString, record: record).get()) != nil
  }

  /// A file the call reads (`body_file`) or writes (`save_to`): relative paths resolve against the folder. The file's
  /// parent directory must already exist; it is resolved with realpath(3) (every symlink on the way, refusing when
  /// one is missing, dangling or looping) and must lie inside the resolved folder, compared by whole path components
  /// (so `/folder-evil/x` is not inside `/folder`). `..` is refused outright (it means something different before and
  /// after a symlink), as are control characters, a trailing `/`, and an existing symlink at the path itself.
  /// Nothing is created: Claude makes a sub-folder first if it needs one.
  public static func path(_ path: String, inside folder: String?) -> Result<URL, Refusal> {
    guard let folder, folder.hasPrefix("/"), let root = realPath(folder) else { return .failure(.noFolder) }
    let outside = Result<URL, Refusal>.failure(.pathOutsideFolder(path))
    guard !path.isEmpty, !path.hasSuffix("/"),
          !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return outside }
    let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    guard let last = parts.last, !parts.contains("..") else { return outside }

    let base = path.hasPrefix("/") ? "/" : root
    let parentPath = parts.dropLast().reduce(base) { ($0 == "/" ? "" : $0) + "/" + $1 }
    guard let parent = realPath(parentPath) else { return outside }
    let rootParts = URL(fileURLWithPath: root).pathComponents
    let parentParts = URL(fileURLWithPath: parent).pathComponents
    guard parentParts.starts(with: rootParts) else { return outside }
    let target = URL(fileURLWithPath: parent).appendingPathComponent(String(last))
    let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
    guard !isLink else { return outside }
    return .success(target)
  }

  /// realpath(3): nil when any component is missing, dangling or in a loop.
  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
