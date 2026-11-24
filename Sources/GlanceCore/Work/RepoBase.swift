import Foundation

/// The branch a session's work is compared with (Make explainer's diff, spec §4.3).
public enum RepoBase {
  /// The PR's base branch as a ref that exists here: `origin/<base>`, else `<base>`; with no PR base (or neither
  /// there), the remote's default branch (`origin/HEAD`). Nil when there is none, which includes a repository with only
  /// the current branch: a diff against the current branch would be empty and say nothing.
  public static func find(cwd: String, prBase: String?) -> String? {
    let base = prBase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if usable(base) {
      for ref in ["origin/\(base)", base] where exists(ref, in: cwd) { return ref }
    }
    if let head = GitRun.text(cwd, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?
      .trimmingCharacters(in: .whitespacesAndNewlines), usable(head), exists(head, in: cwd) {
      return head
    }
    return nil
  }

  /// The work since `base`: `git diff --no-ext-diff --no-textconv <base>...HEAD` (what the branch added, not what the
  /// base gained meanwhile; no configured diff tool or text filter may rewrite it). Nil when git fails or `base` isn't a
  /// ref that exists. At most 5 MB is kept; the prompt cuts it far shorter.
  public static func diff(cwd: String, base: String) -> String? {
    guard usable(base), exists(base, in: cwd),
          let data = GitRun.data(cwd, ["diff", "--no-ext-diff", "--no-textconv", "\(base)...HEAD"], timeout: 30) else { return nil }
    return String(decoding: data.prefix(5_000_000), as: UTF8.self)
  }

  /// A name git could take for an option, or a path into something else, is not a branch.
  private static func usable(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix("-") && !name.contains(where: { $0.isWhitespace || $0.isNewline })
  }

  private static func exists(_ ref: String, in cwd: String) -> Bool {
    GitRun.data(cwd, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], timeout: 10) != nil
  }
}
