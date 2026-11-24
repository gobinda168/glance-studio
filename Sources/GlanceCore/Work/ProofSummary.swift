import Foundation

/// The proof summary Glance writes into a PR description between markers (spec §3 "On the PR page"). Media stays local.
public enum ProofSummary {
  public static let start = "<!-- glance-proof -->"
  public static let end = "<!-- /glance-proof -->"

  public static func markdown(_ record: WorkRecord, setup: ProofSetup?, facts: ProofFacts, previewURL: String?) -> String {
    markdown(record, setup: setup, facts: facts, previews: previewURL.map { [(environment: "", url: $0)] } ?? [])
  }

  /// The summary with a preview line for each environment (an unnamed one reads "Preview: url").
  public static func markdown(_ record: WorkRecord, setup: ProofSetup?, facts: ProofFacts,
                              previews: [(environment: String, url: String)]) -> String {
    var lines = ["### Proof of work · \(ProofReview.pill(record, setup: setup, facts: facts).label)", ""]
    let envs = setup?.environments.map(\.name) ?? Array(Set(record.checks.compactMap(\.environment))).sorted()
    let names = setup?.checks.map(\.name) ?? Array(Set(record.checks.map(\.name))).sorted()
    if !names.isEmpty, !envs.isEmpty {
      lines.append("| Check | " + envs.map { clean($0, inTable: true) }.joined(separator: " | ") + " |")
      lines.append("|---|" + envs.map { _ in "---" }.joined(separator: "|") + "|")
      for name in names {
        let cells = envs.map { env -> String in
          guard let run = ProofReview.latest(record, name: name, environment: env) else { return "—" }
          return run.ok ? "✓" : "✗"
        }
        lines.append("| \(clean(name, inTable: true)) | " + cells.joined(separator: " | ") + " |")
      }
      lines.append("")
    }
    if !previews.isEmpty {
      lines += previews.map { $0.environment.isEmpty ? "Preview: \(clean($0.url))" : "Preview (\(clean($0.environment))): \(clean($0.url))" }
      lines.append("")
    }
    if let verdict = record.verdict {
      let word = switch verdict.verdict { case .merge: "Merge"; case .hold: "Hold"; case .notReady: "Not ready" }
      lines.append("**\(word)** (Claude's verdict)")
      lines += verdict.reasons.map { "- \(clean($0))" }
      lines.append("")
    }
    let gaps = ProofReview.gaps(record, setup: setup, facts: facts)
    if !gaps.isEmpty { lines += ["Gaps:"] + gaps.map { "- \(clean($0.text))" } + [""] }
    if !record.pending.isEmpty {
      lines.append("Pending:")
      lines += record.pending.map { "- [\($0.done ? "x" : " ")] \(clean($0.text))" }
      lines.append("")
    }
    lines.append("<sub>Checks seen by Glance; verdict and notes from Claude.</sub>")
    return lines.joined(separator: "\n")
  }

  /// Text from the session (reasons, pending items, check and environment names, the preview URL) made safe to publish
  /// in a PR description: one line, no HTML comments (so it can't carry or break a marker), no `@` mentions, no images
  /// or links, and `|` escaped inside table cells.
  static func clean(_ text: String, inTable: Bool = false) -> String {
    var out = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    out = out.replacingOccurrences(of: "<!--", with: "&lt;!--").replacingOccurrences(of: "-->", with: "--&gt;")
      .replacingOccurrences(of: "@", with: "@\u{200B}")
      .replacingOccurrences(of: "![", with: "!\u{200B}[").replacingOccurrences(of: "](", with: "]\u{200B}(")
    return inTable ? out.replacingOccurrences(of: "|", with: "\\|") : out
  }

  /// `body` with the first complete block (a start marker followed by an end marker) replaced, or the block appended when
  /// there is none. A lone marker in the user's text is left alone, so nothing between markers is ever lost to a stray
  /// one, and publishing again gives the same body as publishing once.
  public static func replacing(in body: String, with summary: String) -> String {
    let summary = summary.replacingOccurrences(of: start, with: "").replacingOccurrences(of: end, with: "")
    let block = start + "\n" + summary + "\n" + end
    var from = body.startIndex
    while let e = body.range(of: end, range: from..<body.endIndex) {
      if let s = body.range(of: start, options: .backwards, range: body.startIndex..<e.lowerBound) {
        return body.replacingCharacters(in: s.lowerBound..<e.upperBound, with: block)
      }
      from = e.upperBound
    }
    let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? block : trimmed + "\n\n" + block
  }
}
