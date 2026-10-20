import Foundation

/// The Editor start page's Clone Repository (spec 2026-10-11-strip-switching-design.md §3): `owner/repo` and GitHub
/// URLs clone with `gh repo clone` (the user's gh login and protocol); any other git URL with `git clone`. The folder
/// is the repository's name in the clone folder.
public enum CloneSource {
  public enum Tool: Equatable, Sendable { case gh, git }

  public struct Plan: Equatable, Sendable {
    public let tool: Tool
    public let arguments: [String]
    public let destination: String

    public init(tool: Tool, arguments: [String], destination: String) {
      self.tool = tool
      self.arguments = arguments
      self.destination = destination
    }
  }

  /// How to clone `text` into `parent`, or nil when it isn't a repository.
  public static func plan(_ text: String, parent: String) -> Plan? {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let slug = gitHubSlug(typed), let name = name(of: slug) {
      let destination = (parent as NSString).appendingPathComponent(name)
      return Plan(tool: .gh, arguments: ["repo", "clone", slug, destination], destination: destination)
    }
    // GitHub text that isn't owner/repo (github.com/acme) is a mistake, not something for git.
    guard !typed.lowercased().contains("github.com"), isGitURL(typed), let name = name(of: typed) else { return nil }
    let destination = (parent as NSString).appendingPathComponent(name)
    return Plan(tool: .git, arguments: ["clone", typed, destination], destination: destination)
  }

  /// The repository's name: the last path part without `.git`, or nil when `text` names no repository.
  public static func name(of text: String) -> String? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard trimmed.contains("/") || trimmed.contains(":") else { return nil }
    var last = String(trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last ?? "")
    if last.hasSuffix(".git") { last.removeLast(4) }
    return last.isEmpty || last.contains(" ") ? nil : last
  }

  /// `owner/repo` from `owner/repo`, `github.com/owner/repo`, `https://github.com/owner/repo(.git)` or
  /// `git@github.com:owner/repo.git`; nil for anything else.
  static func gitHubSlug(_ text: String) -> String? {
    var rest = text
    for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:", "ssh://git@github.com/"]
    where rest.lowercased().hasPrefix(prefix) {
      rest = String(rest.dropFirst(prefix.count))
      break
    }
    while rest.hasSuffix("/") { rest.removeLast() }
    if rest.hasSuffix(".git") { rest.removeLast(4) }
    let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) })
    else { return nil }
    return parts.joined(separator: "/")
  }

  /// A URL git clones: `scheme://host/path` or scp-style `user@host:path`.
  static func isGitURL(_ text: String) -> Bool {
    guard !text.contains(" ") else { return false }
    if let url = URL(string: text), let scheme = url.scheme, ["https", "http", "ssh", "git", "file"].contains(scheme),
       !(url.path.isEmpty || url.path == "/") { return true }
    return text.range(of: #"^[^@\s/]+@[^:\s/]+:.+$"#, options: .regularExpression) != nil
  }
}
