import Foundation

/// Masks what a log must not keep: credentials in headers, in addresses, in request and response bodies, and tokens
/// that a page printed. Studio masks before anything is written, so the files, `glance browser` and Claude Code never
/// see the originals.
public enum WebLogRedactor {
  public static let mask = "[masked]"

  private static let sensitiveHeaders: Set<String> = [
    "authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token",
    "x-xsrf-token", "x-access-token", "x-amz-security-token", "x-goog-api-key", "x-session-id",
  ]
  private static let sensitiveWords = [
    "password", "passwd", "secret", "token", "apikey", "authorization", "credential", "sessionid", "cookie", "jwt",
    "signature", "privatekey", "accesskey", "otp",
  ]

  /// A header, query parameter or JSON field whose value is a credential.
  public static func isSensitive(_ name: String) -> Bool {
    let lowered = name.lowercased()
    if sensitiveHeaders.contains(lowered) { return true }
    let plain = lowered.filter { $0 != "-" && $0 != "_" }
    return plain == "auth" || plain == "sid" || sensitiveWords.contains { plain.contains($0) }
  }

  public static func headers(_ headers: [String: String]) -> [String: String] {
    headers.reduce(into: [:]) { result, pair in
      result[pair.key] = isSensitive(pair.key) ? mask : text(pair.value)
    }
  }

  /// `url` with credentials in the query (`?token=…`) and in the user info masked.
  public static func url(_ string: String) -> String {
    guard var components = URLComponents(string: string) else { return text(string) }
    let placeholder = "%5Bmasked%5D"
    var changed = false
    if components.password != nil {
      components.percentEncodedPassword = placeholder
      changed = true
    }
    if let items = components.percentEncodedQueryItems {
      components.percentEncodedQueryItems = items.map { item in
        guard isSensitive(item.name.removingPercentEncoding ?? item.name), item.value != nil else { return item }
        changed = true
        return URLQueryItem(name: item.name, value: placeholder)
      }
    }
    guard changed, let masked = components.string else { return text(string) }
    return text(masked.replacingOccurrences(of: placeholder, with: mask))
  }

  /// A request or response body: JSON string values and form fields with a sensitive name are masked.
  public static func body(_ body: String) -> String {
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return text(jsonStrings(body)) }
    if !trimmed.contains(" "), trimmed.contains("="), !trimmed.contains("\n") { return text(form(trimmed)) }
    return text(body)
  }

  /// Bearer tokens and JSON Web Tokens anywhere in `string`.
  public static func text(_ string: String) -> String {
    var result = string
    let patterns = [
      "(?i)(bearer|basic)\\s+[A-Za-z0-9._~+/=-]{8,}",
      "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*",
    ]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(result.startIndex..., in: result)
      result = expression.stringByReplacingMatches(in: result, range: range,
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: mask))
    }
    return result
  }

  /// `entry` with every credential masked.
  public static func entry(_ entry: WebLogEntry) -> WebLogEntry {
    var copy = entry
    copy.text = entry.text.map(text)
    copy.url = entry.url.map(url)
    copy.error = entry.error.map(text)
    copy.requestHeaders = entry.requestHeaders.map(headers)
    copy.responseHeaders = entry.responseHeaders.map(headers)
    copy.requestBody = entry.requestBody.map(body)
    copy.responseBody = entry.responseBody.map(body)
    return copy
  }

  private static func jsonStrings(_ json: String) -> String {
    guard let expression = try? NSRegularExpression(pattern: "\"((?:[^\"\\\\]|\\\\.)+)\"\\s*:\\s*\"(?:[^\"\\\\]|\\\\.)*\"")
    else { return json }
    var result = json
    let matches = expression.matches(in: json, range: NSRange(json.startIndex..., in: json))
    for match in matches.reversed() {
      guard let whole = Range(match.range, in: result), let name = Range(match.range(at: 1), in: json),
            isSensitive(String(json[name])) else { continue }
      let original = String(result[whole])
      guard let colon = original.firstIndex(of: ":") else { continue }
      let prefix = original[original.startIndex...colon]
      result.replaceSubrange(whole, with: "\(prefix) \"\(mask)\"")
    }
    return result
  }

  private static func form(_ body: String) -> String {
    body.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
      guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
      let name = String(pair[pair.startIndex..<equals])
      return isSensitive(name.removingPercentEncoding ?? name) ? "\(name)=\(mask)" : String(pair)
    }.joined(separator: "&")
  }
}
