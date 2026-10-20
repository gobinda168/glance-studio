import Foundation

/// Tokens by kind (spec 2026-10-09-token-usage-design.md): cache writes of both lifetimes count as one kind.
public struct UsageTokens: Equatable, Sendable {
  public var input = 0
  public var output = 0
  public var cacheWrite = 0
  public var cacheRead = 0

  public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
    self.input = input
    self.output = output
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
  }

  public var total: Int { input + output + cacheWrite + cacheRead }

  public static func + (lhs: UsageTokens, rhs: UsageTokens) -> UsageTokens {
    UsageTokens(input: lhs.input + rhs.input, output: lhs.output + rhs.output,
                cacheWrite: lhs.cacheWrite + rhs.cacheWrite, cacheRead: lhs.cacheRead + rhs.cacheRead)
  }
}

/// One Claude Code API request, as `usage.sqlite` keeps it. `project` is the session folder's git root, or "" for a
/// session in a temp folder (Glance's own background runs).
public struct UsageRecord: Equatable, Sendable {
  public var messageID: String
  public var time: Date
  public var model: String
  public var sessionID: String
  public var project: String
  public var subagent: Bool
  public var fast: Bool
  public var input: Int
  public var output: Int
  public var cacheWrite5m: Int
  public var cacheWrite1h: Int
  public var cacheRead: Int

  public init(messageID: String, time: Date, model: String, sessionID: String, project: String, subagent: Bool,
              fast: Bool, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int) {
    self.messageID = messageID
    self.time = time
    self.model = model
    self.sessionID = sessionID
    self.project = project
    self.subagent = subagent
    self.fast = fast
    self.input = input
    self.output = output
    self.cacheWrite5m = cacheWrite5m
    self.cacheWrite1h = cacheWrite1h
    self.cacheRead = cacheRead
  }

  public var tokens: UsageTokens {
    UsageTokens(input: input, output: output, cacheWrite: cacheWrite5m + cacheWrite1h, cacheRead: cacheRead)
  }
}
