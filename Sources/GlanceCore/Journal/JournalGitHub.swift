import Foundation

/// The user's pull requests and reviews on GitHub, for Journal (spec 2026-10-09-journal-design.md, "Capture"): one
/// GraphQL search through `gh`. GitHub's dates are UTC, so the search reaches a day either side and `parse` keeps what
/// falls in the local range.
public enum JournalGitHub {
  static let query = """
    query($opened: String!, $merged: String!, $reviewed: String!) {
      viewer { login }
      opened: search(type: ISSUE, query: $opened, first: 100) { nodes { ...pr } }
      merged: search(type: ISSUE, query: $merged, first: 100) { nodes { ...pr } }
      reviewed: search(type: ISSUE, query: $reviewed, first: 100) {
        nodes {
          ...pr
          ... on PullRequest {
            reviews(last: 100) { nodes { id state submittedAt author { login } comments { totalCount } } }
          }
        }
      }
    }
    fragment pr on PullRequest {
      id number title url createdAt mergedAt additions deletions repository { nameWithOwner }
    }
    """

  public static func searchArguments(days: [JournalDay], calendar: Calendar) -> [String] {
    guard let first = days.min(), let last = days.max() else { return [] }
    let from = first.adding(days: -1, calendar: calendar).key
    let to = last.adding(days: 1, calendar: calendar).key
    return GitHubCLI.graphQLArguments(query, variables: [
      "opened": .string("is:pr author:@me created:\(from)..\(to)"),
      "merged": .string("is:pr author:@me merged:\(from)..\(to)"),
      "reviewed": .string("is:pr reviewed-by:@me updated:>=\(from)"),
    ])
  }

  public static func parse(_ data: [String: Any], range: DateInterval, calendar: Calendar,
                           folders: RepositoryFolders) -> [JournalEvent] {
    let login = (data["viewer"] as? [String: Any])?["login"] as? String
    func nodes(_ alias: String) -> [[String: Any]] {
      (data[alias] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
    }
    func inRange(_ date: Date) -> Bool { date >= range.start && date < range.end }
    var events: [JournalEvent] = []
    for (alias, field) in [("opened", "createdAt"), ("merged", "mergedAt")] {
      for node in nodes(alias) {
        guard let id = node["id"] as? String, let at = (node[field] as? String).flatMap(JournalTime.parse),
              inRange(at) else { continue }
        let repository = Self.repository(node)
        events.append(JournalEvent(
          source: .pr, externalID: "\(id):\(alias)", day: JournalDay(at, calendar: calendar), start: at,
          project: project(repository, folders), title: JournalText.clean(node["title"] as? String ?? "", limit: 200),
          detail: JournalDetail(insertions: node["additions"] as? Int, deletions: node["deletions"] as? Int,
                                repository: repository, number: node["number"] as? Int, url: node["url"] as? String,
                                action: alias)))
      }
    }
    for node in nodes("reviewed") {
      let reviews = (node["reviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
      for review in reviews {
        guard let login, let reviewID = review["id"] as? String,
              (review["author"] as? [String: Any])?["login"] as? String == login,
              let state = review["state"] as? String, state != "PENDING",
              let at = (review["submittedAt"] as? String).flatMap(JournalTime.parse), inRange(at) else { continue }
        let repository = Self.repository(node)
        events.append(JournalEvent(
          source: .review, externalID: reviewID, day: JournalDay(at, calendar: calendar), start: at,
          project: project(repository, folders), title: JournalText.clean(node["title"] as? String ?? "", limit: 200),
          detail: JournalDetail(repository: repository, number: node["number"] as? Int, url: node["url"] as? String,
                                reviewState: state.lowercased(),
                                comments: (review["comments"] as? [String: Any])?["totalCount"] as? Int)))
      }
    }
    return events
  }

  private static func repository(_ node: [String: Any]) -> String? {
    (node["repository"] as? [String: Any])?["nameWithOwner"] as? String
  }

  /// The repository's folder on this Mac when Glance knows one, else "owner/name".
  private static func project(_ repository: String?, _ folders: RepositoryFolders) -> String? {
    repository.map { folders.folder(for: $0) ?? $0 }
  }
}
