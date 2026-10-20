import Foundation

/// Tickets' Jira calls when Glance itself is signed in to the site (spec 2026-10-12-connectors-design.md, "Jira over
/// REST"): built and read here, sent by the app's transport, so they're tested without a network. API v2 on both
/// flavours.
public enum JiraREST {
  public static let assignedJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"
  public static let upNextJQL = "assignee is EMPTY AND sprint in openSprints() AND statusCategory != Done ORDER BY rank"
  static let fields = ["summary", "status", "priority", "assignee", "duedate", "updated"]

  public static func searchRequest(_ site: AtlassianSite, jql: String, sprintField: String?,
                                   credential: AtlassianAPI.Credential) -> URLRequest? {
    guard let base = site.jiraURL else { return nil }
    let path = site.flavor == .cloud ? "/rest/api/2/search/jql" : "/rest/api/2/search"
    let list = (fields + [sprintField].compactMap { $0 }).joined(separator: ",")
    return AtlassianAPI.request(base, path, query: [("jql", jql), ("fields", list), ("expand", "transitions"),
                                                    ("maxResults", "50")], credential: credential)
  }

  public static func fieldsRequest(_ site: AtlassianSite, credential: AtlassianAPI.Credential) -> URLRequest? {
    site.jiraURL.map { AtlassianAPI.request($0, "/rest/api/2/field", credential: credential) }
  }

  /// The Sprint field's id: the field named "Sprint", else Jira Software's sprint type.
  public static func sprintField(_ data: Data) -> String? {
    guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    let isSprint: ([String: Any]) -> Bool = {
      (($0["schema"] as? [String: Any])?["custom"] as? String)?.hasSuffix(":gh-sprint") == true
    }
    let field = list.first { $0["name"] as? String == "Sprint" } ?? list.first(where: isSprint)
    return field?["id"] as? String
  }

  /// A search's issues as tickets; nil when the answer isn't a search result (an SSO page answering for the API).
  public static func tickets(_ data: Data, site: AtlassianSite, tracker: String, group: Ticket.Group,
                             sprintField: String?) -> [Ticket]? {
    guard let object = AtlassianAPI.json(data), let issues = object["issues"] as? [[String: Any]] else { return nil }
    return issues.compactMap { issue in
      guard let key = issue["key"] as? String, let fields = issue["fields"] as? [String: Any] else { return nil }
      let status = fields["status"] as? [String: Any]
      let statusName = status?["name"] as? String ?? "Unknown"
      let transitions = (issue["transitions"] as? [[String: Any]] ?? []).compactMap { item -> Ticket.Transition? in
        guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
        let to = item["to"] as? [String: Any]
        return Ticket.Transition(id: id, name: name,
                                 category: category(key: categoryKey(to), name: to?["name"] as? String ?? name))
      }
      return Ticket(
        tracker: tracker, key: key, title: fields["summary"] as? String ?? key, status: statusName,
        statusCategory: category(key: categoryKey(status), name: statusName),
        priority: (fields["priority"] as? [String: Any])?["name"] as? String,
        assignee: (fields["assignee"] as? [String: Any])?["displayName"] as? String,
        due: TicketPrompts.date(fields["duedate"]), updated: updated(fields["updated"]),
        url: site.jiraURL.map { $0.appendingPathComponent("browse").appendingPathComponent(key) },
        sprint: sprintField.flatMap { sprintName(fields[$0]) }, transitions: transitions, group: group)
    }
  }

  /// Several searches' tickets, each key once (the first search's copy wins).
  public static func merged(_ lists: [[Ticket]]) -> [Ticket] {
    var seen = Set<String>()
    return lists.flatMap { $0 }.filter { seen.insert($0.key).inserted }
  }

  static func categoryKey(_ status: [String: Any]?) -> String? {
    (status?["statusCategory"] as? [String: Any])?["key"] as? String
  }

  public static func category(key: String?, name: String) -> Ticket.StatusCategory {
    switch key {
    case "new": .todo
    case "indeterminate": name.lowercased().contains("review") ? .review : .inProgress
    case "done": .done
    default: .unknown
    }
  }

  /// Jira's `2026-10-11T09:12:33.000+0530`, else any ISO 8601 date.
  static func updated(_ value: Any?) -> Date? {
    guard let text = value as? String else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    return formatter.date(from: text) ?? TicketPrompts.date(text)
  }

  /// The last sprint's name: Cloud's objects, or Data Center's `…[id=4,…,name=Sprint 9,…]` strings.
  public static func sprintName(_ value: Any?) -> String? {
    guard let list = value as? [Any], let last = list.last else { return nil }
    if let object = last as? [String: Any] { return object["name"] as? String }
    guard let text = last as? String, let range = text.range(of: "name=") else { return nil }
    let rest = text[range.upperBound...]
    let name = rest.prefix { $0 != "," && $0 != "]" }
    return name.isEmpty ? nil : String(name)
  }

  public static func transitionRequest(_ site: AtlassianSite, key: String, transitionID: String,
                                       credential: AtlassianAPI.Credential) -> URLRequest? {
    write(site, "/rest/api/2/issue/\(key)/transitions", method: "POST", ["transition": ["id": transitionID]],
          credential)
  }

  public static func assignRequest(_ site: AtlassianSite, key: String, user: AtlassianUser,
                                   credential: AtlassianAPI.Credential) -> URLRequest? {
    let body: [String: Any] = site.flavor == .cloud ? ["accountId": user.id] : ["name": user.name ?? user.id]
    return write(site, "/rest/api/2/issue/\(key)/assignee", method: "PUT", body, credential)
  }

  public static func commentRequest(_ site: AtlassianSite, key: String, body: String,
                                    credential: AtlassianAPI.Credential) -> URLRequest? {
    write(site, "/rest/api/2/issue/\(key)/comment", method: "POST", ["body": body], credential)
  }

  // MARK: Creating a ticket

  public struct Project: Equatable, Sendable, Identifiable {
    public let key: String
    public let name: String
    public var id: String { key }

    public init(key: String, name: String) {
      self.key = key
      self.name = name
    }
  }

  /// The projects the user can create issues in (the first 50, by name).
  public static func projectsRequest(_ site: AtlassianSite, credential: AtlassianAPI.Credential) -> URLRequest? {
    site.jiraURL.map { AtlassianAPI.request($0, "/rest/api/2/project", query: [("orderBy", "name")], credential: credential) }
  }

  public static func projects(_ data: Data) -> [Project]? {
    guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
    return list.compactMap { item in
      guard let key = item["key"] as? String, !key.isEmpty else { return nil }
      return Project(key: key, name: item["name"] as? String ?? key)
    }
  }

  public static func projectRequest(_ site: AtlassianSite, key: String, credential: AtlassianAPI.Credential) -> URLRequest? {
    site.jiraURL.map { AtlassianAPI.request($0, "/rest/api/2/project/\(key)", credential: credential) }
  }

  /// The issue type a new ticket gets in a project: "Task" when it has one, else its first type that isn't a sub-task.
  public static func issueType(inProject data: Data) -> String? {
    guard let types = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["issueTypes"] as? [[String: Any]]
    else { return nil }
    let usable = types.filter { $0["subtask"] as? Bool != true }.compactMap { $0["name"] as? String }
    return usable.first { $0.lowercased() == "task" } ?? usable.first
  }

  public static func createRequest(_ site: AtlassianSite, project: String, issueType: String, summary: String,
                                   description: String, credential: AtlassianAPI.Credential) -> URLRequest? {
    var fields: [String: Any] = ["project": ["key": project], "issuetype": ["name": issueType], "summary": summary]
    if !description.isEmpty { fields["description"] = description }
    return write(site, "/rest/api/2/issue", method: "POST", ["fields": fields], credential)
  }

  /// The key of the issue a create call made ("ABC-12").
  public static func createdKey(_ data: Data) -> String? {
    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["key"] as? String
  }

  /// The ticket's page in the browser.
  public static func browseURL(_ site: AtlassianSite, key: String) -> URL? {
    site.jiraURL?.appendingPathComponent("browse").appendingPathComponent(key)
  }

  static func write(_ site: AtlassianSite, _ path: String, method: String, _ body: [String: Any],
                    _ credential: AtlassianAPI.Credential) -> URLRequest? {
    guard let base = site.jiraURL,
          let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return nil }
    return AtlassianAPI.request(base, path, method: method, body: data, credential: credential)
  }

  /// What went wrong with a call, in one line for the tracker's state or a move's notice.
  public static func failure(status: Int, data: Data, site: AtlassianSite, key: String?) -> TicketFailure {
    let host = site.jiraURL?.host ?? site.name
    let message: String
    switch status {
    case 200, 201, 204: message = "\(host) didn't answer with tickets. Sign in again in its Jira tab."
    case 401: message = "Signed out of \(host)."
    case 403: message = "Jira says you can't do that."
    case 404 where key != nil: message = "\(key!) isn't there anymore."
    default:
      let object = AtlassianAPI.json(data)
      let first = (object?["errorMessages"] as? [String])?.first
        ?? (object?["errors"] as? [String: String])?.sorted { $0.key < $1.key }.first?.value
      message = first ?? "Jira answered \(status)."
    }
    return TicketFailure(message: message)
  }
}
