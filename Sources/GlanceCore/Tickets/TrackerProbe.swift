import Foundation

/// One MCP server Claude Code reported in a run's init event, and how it stands.
public struct ConnectorServer: Equatable, Sendable, Identifiable {
  public enum Status: Equatable, Sendable {
    case connected, needsAuth, failed, pending, other

    init(_ raw: String?) {
      switch raw {
      case "connected": self = .connected
      case "needs-auth": self = .needsAuth
      case "failed": self = .failed
      case "pending": self = .pending
      default: self = .other
      }
    }
  }

  public let name: String
  public let status: Status
  public var id: String { name }

  public init(name: String, status: Status) {
    self.name = name
    self.status = status
  }

  /// "claude.ai Atlassian" → "Atlassian".
  public var title: String { isClaudeAI ? String(name.dropFirst("claude.ai ".count)) : name }

  /// A connector added on claude.ai: its sign-in lives there, not in this Mac's Claude Code.
  public var isClaudeAI: Bool { name.hasPrefix("claude.ai ") }

  public func mentions(_ words: [String]) -> Bool {
    let lower = name.lowercased()
    return words.contains(where: lower.contains)
  }
}

/// Which of Claude Code's connected MCP servers are issue trackers, from the first stream-json event of a `claude`
/// run (`{"type":"system","subtype":"init","tools":[…],"mcp_servers":[…]}`), and which of their tools read, move and
/// comment. A tool's verb is its first word: getJiraIssue → get, update_issue → update.
public enum TrackerProbe {
  static let trackerWords = ["jira", "atlassian", "linear", "github", "issue", "ticket"]
  static let readVerbs: Set<String> = ["get", "list", "search", "lookup", "fetch", "read", "query", "find", "view"]
  static let moveVerbs: Set<String> = ["transition", "update", "edit", "move", "assign", "set"]
  static let commentVerbs: Set<String> = ["add", "create", "post"]
  /// The trackers Tickets names when one is added but not signed in, and what it calls them.
  static let trackerNames: [(words: [String], name: String)] = [(["jira", "atlassian"], "Jira"),
                                                                 (["linear"], "Linear"), (["github"], "GitHub")]

  /// Lets a `claude` run's connectors connect before its first turn, for up to 20 s (Claude Code's own wait is 5 s).
  /// Claude Code otherwise connects claude.ai connectors in the background: the init event lists them "pending" and
  /// the run may start without their tools.
  public static let waitForConnectors = ["MCP_CONNECTION_NONBLOCKING": "false", "MCP_CONNECT_TIMEOUT_MS": "20000"]

  /// The trackers among the servers the init event lists as connected, or as still connecting ("pending") with their
  /// tools known. `listed` (`claude mcp list`, which waits for each server) has the last word on a server it names:
  /// only a connected one counts.
  public static func trackers(initLine: String, listed: [ConnectorServer]? = nil) -> [Tracker]? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(initLine.utf8)) as? [String: Any],
          object["type"] as? String == "system", object["subtype"] as? String == "init" else { return nil }
    let tools = object["tools"] as? [String] ?? []
    let settled = Dictionary((listed ?? []).map { ($0.name, $0.status) }, uniquingKeysWith: { first, _ in first })
    let servers = (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server -> String? in
      guard let name = server["name"] as? String else { return nil }
      if let status = settled[name] { return status == .connected ? name : nil }
      let status = server["status"] as? String
      return status == "connected" || status == "pending" ? name : nil
    }
    return servers.compactMap { server in
      let prefix = "mcp__" + toolSegment(server) + "__"
      let own = tools.filter { $0.hasPrefix(prefix) }
      let names = own.map { String($0.dropFirst(prefix.count)) }
      guard isTracker(server: server, tools: names) else { return nil }
      var read: [String] = [], move: [String] = [], comment: [String] = []
      for (tool, name) in zip(own, names) {
        let words = self.words(name)
        guard let verb = words.first else { continue }
        if commentVerbs.contains(verb), words.contains("comment") {
          comment.append(tool)
        } else if moveVerbs.contains(verb) {
          move.append(tool)
        } else if readVerbs.contains(verb) || words.contains("info") {
          read.append(tool)
        }
      }
      guard !read.isEmpty else { return nil }
      return Tracker(server: server, readTools: read, moveTools: move, commentTools: comment)
    }
  }

  /// A tracker is named like one ("Atlassian", "Linear", "GitHub"), or, when its name says nothing, has both read and
  /// move tools for issues or tickets. One tool with "issue" or "ticket" in its name isn't enough: a voice or search
  /// connector can have one (ElevenLabs listed as a tracker, and every run then failed).
  static func isTracker(server: String, tools: [String]) -> Bool {
    let name = server.lowercased()
    if trackerWords.contains(where: name.contains) { return true }
    let issueTools = tools.filter { tool in
      let words = self.words(tool)
      return words.contains(where: { $0.hasPrefix("issue") || $0.hasPrefix("ticket") })
    }
    let verbs = issueTools.compactMap { words($0).first }
    return verbs.contains(where: readVerbs.contains) && verbs.contains(where: moveVerbs.contains)
  }

  /// Every server in the init event, connected or not, in its order.
  public static func servers(initLine: String) -> [ConnectorServer]? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(initLine.utf8)) as? [String: Any],
          object["type"] as? String == "system", object["subtype"] as? String == "init" else { return nil }
    return (object["mcp_servers"] as? [[String: Any]] ?? []).compactMap { server in
      (server["name"] as? String).map { ConnectorServer(name: $0, status: .init(server["status"] as? String)) }
    }
  }

  /// Every server in `claude mcp list`'s output ("name: target - ✔ Connected"), which waits for each server's
  /// health check, so claude.ai connectors still connecting in the init event come back with their real status.
  /// Nil when no line looks like a server.
  public static func servers(mcpList: String) -> [ConnectorServer]? {
    let servers = mcpList.split(separator: "\n").compactMap { line -> ConnectorServer? in
      guard let dash = line.range(of: " - ", options: .backwards),
            let colon = line[..<dash.lowerBound].range(of: ": ") else { return nil }
      let name = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
      let status = line[dash.upperBound...].lowercased()
      guard !name.isEmpty else { return nil }
      let parsed: ConnectorServer.Status =
        if status.contains("needs authentication") { .needsAuth }
        else if status.contains("connected") { .connected }
        else if status.contains("failed") || status.contains("error") { .failed }
        else { .other }
      return ConnectorServer(name: name, status: parsed)
    }
    return servers.isEmpty ? nil : servers
  }

  /// Jira, Linear and GitHub connectors Claude Code has but can't use until the user signs in, by the name Tickets
  /// gives them ("Jira"), each once.
  public static func signInNeeded(_ servers: [ConnectorServer]) -> [(name: String, server: ConnectorServer)] {
    var found: [(name: String, server: ConnectorServer)] = []
    for server in servers where server.status == .needsAuth {
      guard let name = trackerNames.first(where: { server.mentions($0.words) })?.name,
            !found.contains(where: { $0.name == name }) else { continue }
      found.append((name, server))
    }
    return found
  }

  /// What Tickets says instead of "No tracker connected" when trackers are added but not signed in, ending on the
  /// button that looks again (`then`); nil when none are.
  public static func signInWords(_ servers: [ConnectorServer], then: String = "Refresh")
    -> (title: String, line: String)? {
    let needed = signInNeeded(servers)
    guard !needed.isEmpty else { return nil }
    let names = needed.map { $0.name }
    let listed = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
    let one = names.count == 1
    let how = needed.contains(where: { $0.server.isClaudeAI })
      ? "reconnect \(one ? "it" : "them") in claude.ai's Connectors, or run /mcp in Claude Code and pick "
        + (one ? "it" : "each")
      : "run /mcp in Claude Code, pick \(one ? "it" : "each") and Authenticate"
    return ("\(listed) \(one ? "isn't" : "aren't") signed in",
            "Claude Code has the \(one ? "connector" : "connectors") but can't read \(one ? "it" : "them") until "
              + "you sign in: \(how). Then \(then).")
  }

  /// How Claude Code writes a server's name inside its tools' names: anything but letters, digits, _ and - becomes _.
  public static func toolSegment(_ server: String) -> String {
    String(server.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
  }

  /// "getJiraIssue" → get, jira, issue; "list_issues" → list, issues. A run of capitals stays one word.
  static func words(_ name: String) -> [String] {
    var words: [String] = []
    var current = ""
    for character in name {
      if character == "_" || character == "-" {
        if !current.isEmpty { words.append(current.lowercased()) }
        current = ""
        continue
      }
      if character.isUppercase, let last = current.last, !last.isUppercase {
        words.append(current.lowercased())
        current = ""
      }
      current.append(character)
    }
    if !current.isEmpty { words.append(current.lowercased()) }
    return words
  }
}
