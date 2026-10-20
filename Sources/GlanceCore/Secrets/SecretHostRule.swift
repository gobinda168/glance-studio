import Darwin
import Foundation

/// Where a secret may be sent (spec "Secret record", hosts): exact names or `*.example.com`, ASCII only (punycode for
/// international names), never a local name or any IP literal. TLS proves the server is the name.
public enum SecretHostRule {
  /// Lowercased, without a trailing dot; nil when it isn't an ASCII host name (letters, digits, -, ., and * for
  /// patterns) or has an empty label.
  public static func normalize(_ host: String) -> String? {
    // Before lowercasing: U+212A KELVIN SIGN lowercases to ASCII "k", so a non-ASCII host must be refused first.
    guard host.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
    var text = host.lowercased()
    if text.hasSuffix(".") { text.removeLast() }
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-.*[]:".contains($0)) })
    else { return nil }
    guard !text.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else { return nil }
    return text
  }

  /// Local names and anything that parses as an IP address (dotted, short, hex, decimal or IPv6).
  static func isRefused(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
    if host.contains(":") || host.hasPrefix("[") { return true }
    // inet_aton accepts every IPv4 spelling a URL loader might (127.1, 0x7f.0.0.1, 2130706433).
    var address = in_addr()
    return inet_aton(host, &address) != 0
  }

  /// Why a pattern can't be saved, as a sentence naming it; nil when it can.
  public static func problem(pattern: String) -> String? {
    if pattern.contains(where: { !$0.isASCII }) { return "\(pattern): use the punycode form (xn--…)." }
    guard let host = normalize(pattern) else { return "\(pattern): that isn't a host name." }
    if isRefused(host) { return "\(pattern): local and private addresses are never allowed." }
    if host.contains("*") {
      guard host.hasPrefix("*.") else {
        return host == "*" ? "\(pattern): a wildcard needs a domain after it, like *.example.com."
          : "\(pattern): * can only be the first label."
      }
      let rest = host.dropFirst(2)
      if rest.contains("*") { return "\(pattern): * can only be the first label." }
      if !rest.contains(".") { return "\(pattern): a wildcard needs a domain after it, like *.example.com." }
    }
    return nil
  }

  /// Pattern match only; it does not validate the pattern. Callers must use `allows`, which does.
  static func matches(host: String, pattern: String) -> Bool {
    guard let host = normalize(host), let pattern = normalize(pattern), !host.contains("*") else { return false }
    if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
    return host == pattern
  }

  /// Allowed: not refused, and matching one of the patterns.
  public static func allows(host: String, patterns: [String]) -> Bool {
    guard let normalized = normalize(host), !isRefused(normalized) else { return false }
    return patterns.contains { problem(pattern: $0) == nil && matches(host: normalized, pattern: $0) }
  }
}
