import Foundation

/// A Slack workspace signed in to under Chats (spec 2026-10-09-chats-slack-design.md): its team id, the name and icon
/// read from its page.
public struct ChatWorkspace: Codable, Equatable, Sendable, Identifiable {
  public let teamID: String
  public var name: String
  public var iconURL: String?

  public init(teamID: String, name: String, iconURL: String?) {
    self.teamID = teamID
    self.name = name
    self.iconURL = iconURL
  }

  public var id: String { teamID }

  /// Where the workspace's web client opens.
  public var clientURL: URL { URL(string: "https://app.slack.com/client/\(teamID)")! }

  /// The letter on the row's tile when there's no icon: the name's first letter, else the team id's.
  public var initial: String {
    let source = name.trimmingCharacters(in: .whitespaces).isEmpty ? teamID : name.trimmingCharacters(in: .whitespaces)
    return source.first.map { String($0).uppercased() } ?? "?"
  }
}

/// The workspaces under Chats, in the order they were added. The app keeps it in its preferences (`encoded()`,
/// `init(data:)`, under `chatWorkspaces`).
public struct ChatWorkspaceStore: Equatable, Sendable {
  public private(set) var workspaces: [ChatWorkspace]

  public init(workspaces: [ChatWorkspace] = []) {
    self.workspaces = workspaces
  }

  /// The stored list; missing or unreadable data, or entries without a team id, leave it empty of them.
  public init(data: Data?) {
    let decoded = data.flatMap { try? JSONDecoder().decode([ChatWorkspace].self, from: $0) } ?? []
    self.init(workspaces: decoded.filter { !$0.teamID.isEmpty })
  }

  public func encoded() -> Data {
    (try? JSONEncoder().encode(workspaces)) ?? Data("[]".utf8)
  }

  public func workspace(teamID: String) -> ChatWorkspace? {
    workspaces.first { $0.teamID == teamID }
  }

  /// Adds `workspace` at the end. A team already saved keeps its place and takes the new name and icon: false.
  @discardableResult
  public mutating func add(_ workspace: ChatWorkspace) -> Bool {
    if let index = workspaces.firstIndex(where: { $0.teamID == workspace.teamID }) {
      workspaces[index].name = workspace.name
      if let icon = workspace.iconURL { workspaces[index].iconURL = icon }
      return false
    }
    workspaces.append(workspace)
    return true
  }

  /// A saved team's name, and its icon when one is given. An unknown team is ignored.
  public mutating func update(teamID: String, name: String?, iconURL: String?) {
    guard let index = workspaces.firstIndex(where: { $0.teamID == teamID }) else { return }
    if let name, !name.isEmpty { workspaces[index].name = name }
    if let iconURL { workspaces[index].iconURL = iconURL }
  }

  public mutating func remove(teamID: String) {
    workspaces.removeAll { $0.teamID == teamID }
  }
}
