import Foundation

/// Secrets in a command line (spec "S2: history", "Not recorded"; and what Claude never sees in S5): cloud and API
/// keys, tokens, private key blocks, `*TOKEN=`-style assignments, password options and auth headers.
public enum SecretFilter {
  private struct Rule {
    let regex: NSRegularExpression
    /// Only the `value` group is a secret (the name before it stays readable); otherwise the whole match is.
    let partial: Bool
  }

  private static let rules: [Rule] = {
    let full = [
      #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
      #"\bgh[pousr]_[A-Za-z0-9]{36,}"#,
      #"\bgithub_pat_[A-Za-z0-9_]{60,}"#,
      #"\bsk-ant-[A-Za-z0-9_-]{20,}"#,
      #"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}"#,
      #"\bxox[abpr]-[A-Za-z0-9-]{10,}"#,
      #"\b(?:sk|rk)_live_[A-Za-z0-9]{16,}"#,
      #"\bAIza[0-9A-Za-z_-]{35}"#,
      #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
    ]
    let partial = [
      #"\b[A-Za-z_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|ACCESS_KEY)[A-Za-z_]*=(?<value>'[^']*'|"[^"]*"|[^\s'"]+)"#,
      #"--password[= ](?<value>\S+)"#,
      #"\bmysql\b.*\s-p(?<value>\S+)"#,
      #"\b(?:Authorization|X-Api-Key)\s*:\s*(?<value>[^'"\n]+)"#,
    ]
    func rule(_ pattern: String, partial: Bool) -> Rule {
      // The patterns are fixed above, so a bad one is a programming error caught by the tests.
      Rule(regex: try! NSRegularExpression(pattern: pattern, options: partial ? [.caseInsensitive] : []), partial: partial)
    }
    return full.map { rule($0, partial: false) } + partial.map { rule($0, partial: true) }
  }()

  public static func containsSecret(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    return rules.contains { $0.regex.firstMatch(in: text, range: range) != nil }
  }

  /// The text with each secret replaced by `‹redacted›`.
  public static func redact(_ text: String) -> String {
    var result = text
    for rule in rules {
      let range = NSRange(result.startIndex..., in: result)
      // From the end, so earlier ranges stay valid.
      for match in rule.regex.matches(in: result, range: range).reversed() {
        let target = rule.partial ? match.range(withName: "value") : match.range
        guard target.location != NSNotFound, let swiftRange = Range(target, in: result) else { continue }
        result.replaceSubrange(swiftRange, with: "‹redacted›")
      }
    }
    return result
  }
}
