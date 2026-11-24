import Foundation

/// Command Center (spec 2026-11-01-command-center-design.md §4.1): which Claude session owns which window of the Glance
/// browser. Each session's Playwright wrapper (`agent-browser/session-mcp.mjs`) keeps one connection to Studio and says
/// who it is, which pages it owns and when a tool call starts or ends; this is the table those lines build. Pure: the
/// socket and the browser are Studio's (`AgentBrowserSessions`).
public struct BrowserSessionTable: Sendable, Equatable {
  public struct Client: Sendable, Equatable {
    /// The connection (the listener's id for it).
    public let id: Int
    public var wrapperPID: Int32
    /// The `claude` process, which outlives `/clear`: the way to find a session's windows once its id changed.
    public var claudePID: Int32
    public var session: String?
    public var cwd: String?
    /// Every page this client owns, in the order it reported them.
    public var targets: [String]
    /// The owned pages the user opened in this client's window (not Claude's).
    public var adopted: Set<String>
    /// Tool calls started and not yet ended.
    public var inFlight: Int
    public var lastTool: Date?

    public init(id: Int, wrapperPID: Int32, claudePID: Int32, session: String? = nil, cwd: String? = nil,
                targets: [String] = [], adopted: Set<String> = [], inFlight: Int = 0, lastTool: Date? = nil) {
      self.id = id
      self.wrapperPID = wrapperPID
      self.claudePID = claudePID
      self.session = session
      self.cwd = cwd
      self.targets = targets
      self.adopted = adopted
      self.inFlight = inFlight
      self.lastTool = lastTool
    }
  }

  public enum Phase: String, Sendable { case start, end }

  public enum Event: Sendable, Equatable {
    case hello(wrapperPID: Int32, claudePID: Int32, session: String?, cwd: String?)
    case page(targetId: String, adopted: Bool)
    case pageGone(targetId: String)
    case tool(name: String, phase: Phase)
  }

  public private(set) var clients: [Int: Client] = [:]

  public init() {}

  // MARK: Wire format

  /// One line from a wrapper; nil for anything malformed, of the wrong type or unknown (including a future message).
  public static func decode(_ line: String) -> Event? {
    guard let json = JSONValue.parse(line), json.object != nil, let type = json["type"]?.string else { return nil }
    switch type {
    case "hello":
      guard let wrapper = pid(json["wrapperPid"]), let claude = pid(json["claudePid"]),
            isStringOrAbsent(json["session"]), isStringOrAbsent(json["cwd"]) else { return nil }
      return .hello(wrapperPID: wrapper, claudePID: claude, session: json["session"]?.string, cwd: json["cwd"]?.string)
    case "page":
      guard let target = json["targetId"]?.string, !target.isEmpty else { return nil }
      var adopted = false
      if let value = json["adopted"], value != .null {
        guard let flag = value.bool else { return nil }
        adopted = flag
      }
      return .page(targetId: target, adopted: adopted)
    case "pageGone":
      guard let target = json["targetId"]?.string, !target.isEmpty else { return nil }
      return .pageGone(targetId: target)
    case "tool":
      guard let name = json["name"]?.string, let phase = json["phase"]?.string.flatMap(Phase.init(rawValue:)) else { return nil }
      return .tool(name: name, phase: phase)
    default:
      return nil
    }
  }

  private static func pid(_ value: JSONValue?) -> Int32? {
    value?.int.flatMap { Int32(exactly: $0) }
  }

  /// A key that is missing or null reads as nothing; one of the wrong type is malformed.
  private static func isStringOrAbsent(_ value: JSONValue?) -> Bool {
    guard let value, value != .null else { return true }
    return value.string != nil
  }

  // MARK: Updates

  /// What `client` (a connection) said. Anything before its `hello` has nobody to belong to and is dropped.
  public mutating func apply(_ event: Event, client id: Int, at date: Date) {
    switch event {
    case .hello(let wrapper, let claude, let session, let cwd):
      // A repeated hello on one connection starts the client over: the wrapper announces its pages again after it.
      clients[id] = Client(id: id, wrapperPID: wrapper, claudePID: claude, session: session, cwd: cwd)
    case .page(let target, let adopted):
      guard clients[id] != nil else { return }
      for other in clients.keys where other != id { forget(target, in: other) }
      if clients[id]?.targets.contains(target) == false { clients[id]?.targets.append(target) }
      if adopted { clients[id]?.adopted.insert(target) } else { clients[id]?.adopted.remove(target) }
    case .pageGone(let target):
      forget(target, in: id)
    case .tool(_, let phase):
      guard var client = clients[id] else { return }
      client.inFlight = phase == .start ? client.inFlight + 1 : max(0, client.inFlight - 1)
      client.lastTool = date
      clients[id] = client
    }
  }

  private mutating func forget(_ target: String, in id: Int) {
    clients[id]?.targets.removeAll { $0 == target }
    clients[id]?.adopted.remove(target)
  }

  /// The connection ended: the client goes, and its pages are what the caller closes.
  public mutating func disconnect(client id: Int) -> [String] {
    clients.removeValue(forKey: id)?.targets ?? []
  }

  // MARK: Lookups

  /// The pages of a session's windows. The `claude` process is the stable key (it survives `/clear`, which changes the
  /// session id); the session finds them when the pid isn't known or owns nothing.
  public func pages(claudePID: Int32?, session: String?) -> [String] {
    func targets(where match: (Client) -> Bool) -> [String] {
      clients.values.filter(match).sorted { $0.id < $1.id }.flatMap(\.targets)
    }
    if let claudePID {
      let found = targets { $0.claudePID == claudePID }
      if !found.isEmpty { return found }
    }
    guard let session else { return [] }
    return targets { $0.session == session }
  }

  public func client(owning targetId: String) -> Client? {
    clients.values.first { $0.targets.contains(targetId) }
  }
}

/// Where Studio listens for the session wrappers: `<agent-browser>/sessions/s-<pid>.sock`, or under the temporary folder
/// when that is too long for a unix socket (`sun_path` holds 104 bytes with its terminator; 100 keeps clear of it).
public enum BrowserSessionSocket {
  public static let longestPath = 100

  public static func path(home: String, pid: Int32, temporary: String) -> String {
    let name = "s-\(pid).sock"
    let preferred = ((AgentBrowserPackages.folder(home: home) as NSString).appendingPathComponent("sessions") as NSString)
      .appendingPathComponent(name)
    if preferred.utf8.count <= longestPath { return preferred }
    return ((temporary as NSString).appendingPathComponent("glance-sessions") as NSString).appendingPathComponent(name)
  }
}
