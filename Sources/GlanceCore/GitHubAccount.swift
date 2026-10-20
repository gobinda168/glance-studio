import Foundation

/// The GitHub account the Pull requests side bar reads with (spec 2026-10-08-pr-repositories-design.md): gh's own
/// browser sign-in, run by Glance; signing out; and every repository the account reaches, for the picker. Nothing here
/// runs gh: Glance Studio's `GitHubAccountModel` does.
public enum GitHubAccount {
  /// A repository on the account.
  public struct Repository: Codable, Equatable, Sendable {
    /// "owner/name".
    public let name: String
    public let isPrivate: Bool
    /// The last push; nil when GitHub has none.
    public let pushedAt: Date?

    public init(name: String, isPrivate: Bool = false, pushedAt: Date? = nil) {
      self.name = name
      self.isPrivate = isPrivate
      self.pushedAt = pushedAt
    }
  }

  /// gh's sign-in in the browser, without a terminal. No `--git-protocol`, so the user's SSH or HTTPS setting stays.
  public static let signInArguments = ["auth", "login", "--web", "--hostname", "github.com"]

  /// The signed-in account's login.
  public static let loginArguments = ["api", "user", "--jq", ".login"]

  /// gh's own sign-out of `login` on github.com: the GitHub CLI in the terminals signs out too.
  public static func signOutArguments(login: String) -> [String] {
    ["auth", "logout", "--hostname", "github.com", "--user", login]
  }

  /// Every repository the account owns, collaborates on, or reaches through an organization, newest push first: one
  /// tab-separated line each (name, private, archived, last push).
  public static let repositoriesArguments = [
    "api", "--paginate",
    "user/repos?affiliation=owner,collaborator,organization_member&sort=pushed&per_page=100",
    "--jq", ".[] | [.full_name, .private, .archived, .pushed_at] | @tsv",
  ]

  /// `repositoriesArguments`' lines as repositories: archived ones left out, each once whatever its case, in
  /// `newerFirst` order.
  public static func repositories(_ output: String) -> [Repository] {
    var seen: Set<String> = []
    var found: [Repository] = []
    for line in output.split(whereSeparator: \.isNewline) {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard columns.count >= 3, GitHubCLI.split(columns[0]) != nil, columns[2] != "true",
        seen.insert(columns[0].lowercased()).inserted else { continue }
      let pushed: Date? = columns.count > 3 ? try? Date(columns[3], strategy: .iso8601) : nil
      found.append(Repository(name: columns[0], isPrivate: columns[1] == "true", pushedAt: pushed))
    }
    return found.sorted(by: newerFirst)
  }

  /// The account list's order: newest push first, never pushed last, then by name.
  public static func newerFirst(_ a: Repository, _ b: Repository) -> Bool {
    switch (a.pushedAt, b.pushedAt) {
    case let (x?, y?) where x != y: x > y
    case (.some, nil): true
    case (nil, .some): false
    default: a.name.lowercased() < b.name.lowercased()
    }
  }

  /// The one-time code to enter, and the page to enter it on.
  public struct SignInPrompt: Equatable, Sendable {
    public let code: String
    public let url: URL

    public init(code: String, url: URL) {
      self.code = code
      self.url = url
    }
  }

  /// Reads gh's sign-in output as it arrives: the code from a line about the code ("! One-time code (ABCD-1234) copied
  /// to clipboard", or "! First copy your one-time code: ABCD-1234") and the first https URL ("Open this URL to continue
  /// in your web browser: https://github.com/login/device"). Nil until both have come.
  public static func signInPrompt(_ output: String) -> SignInPrompt? {
    var code: String?
    var url: URL?
    for line in output.split(whereSeparator: \.isNewline) {
      if code == nil, line.lowercased().contains("code"), let match = line.firstMatch(of: #/\b[A-Z0-9]{4}-[A-Z0-9]{4}\b/#) {
        code = String(match.output)
      }
      if url == nil, let match = line.firstMatch(of: #/https://\S+/#) {
        url = URL(string: String(match.output))
      }
    }
    guard let code, let url else { return nil }
    return SignInPrompt(code: code, url: url)
  }

  /// The last line gh printed, which says why a sign-in failed.
  public static func lastLine(_ output: String) -> String? {
    output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
  }

  /// The repository list as saved (`github-repositories.json`): whose it is, and when it was read.
  public struct Saved: Codable, Equatable, Sendable {
    public let login: String
    public let readAt: Date
    public let repositories: [Repository]

    /// A list this old reads again when the picker opens.
    public static let freshFor: TimeInterval = 10 * 60

    public init(login: String, readAt: Date, repositories: [Repository]) {
      self.login = login
      self.readAt = readAt
      self.repositories = repositories
    }

    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(readAt) >= Self.freshFor }

    /// Another account's list is thrown away.
    public func belongs(to login: String) -> Bool { self.login.lowercased() == login.lowercased() }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> Saved? { try? JSONDecoder().decode(Saved.self, from: data) }
  }
}
