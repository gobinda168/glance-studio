import Foundation

/// What the merge button needs from the repository (one GraphQL query; `gh repo view` has no auto-merge field): who the
/// viewer is, the default branch, the merge methods it allows, the one the viewer used last, and whether auto-merge is
/// on for it.
public enum RepositorySettings {
  public struct Settings: Equatable, Sendable {
    public let viewer: String
    public let defaultBranch: String
    /// Allowed methods, in GitHub's order: merge, squash, rebase.
    public let methods: [PullRequestPage.MergeMethod]
    /// What the button offers first: the viewer's last method when it's allowed, else the first allowed.
    public let preferred: PullRequestPage.MergeMethod
    public let autoMergeAllowed: Bool
  }

  public static let query = """
    query($owner: String!, $name: String!) { viewer { login } repository(owner: $owner, name: $name) { \
    autoMergeAllowed viewerDefaultMergeMethod mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed \
    defaultBranchRef { name } } }
    """

  public static func arguments(repository: String) -> [String]? {
    guard let parts = GitHubCLI.split(repository) else { return nil }
    return GitHubCLI.graphQLArguments(query, variables: ["owner": .string(parts.owner), "name": .string(parts.name)])
  }

  public static func parse(_ data: Data) -> Settings? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data),
          let repository = payload["repository"] as? [String: Any] else { return nil }
    var methods: [PullRequestPage.MergeMethod] = []
    if repository["mergeCommitAllowed"] as? Bool == true { methods.append(.merge) }
    if repository["squashMergeAllowed"] as? Bool == true { methods.append(.squash) }
    if repository["rebaseMergeAllowed"] as? Bool == true { methods.append(.rebase) }
    let last = PullRequestPage.MergeMethod(rawValue: repository["viewerDefaultMergeMethod"] as? String ?? "")
    return Settings(
      viewer: (payload["viewer"] as? [String: Any])?["login"] as? String ?? "",
      defaultBranch: (repository["defaultBranchRef"] as? [String: Any])?["name"] as? String ?? "main",
      methods: methods,
      preferred: last.flatMap { methods.contains($0) ? $0 : nil } ?? methods.first ?? .merge,
      autoMergeAllowed: repository["autoMergeAllowed"] as? Bool ?? false)
  }
}
