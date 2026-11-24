import Foundation

/// Old and new text → the changed lines with a little context around them (Edit/MultiEdit rows in the Glance view).
public enum TextDiff {
  public static func lines(old: String, new: String, context: Int = 2) -> [DiffLine] {
    let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
    var prefix = 0
    while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
    var out: [DiffLine] = []
    out += a[max(0, prefix - context)..<prefix].map { DiffLine(mark: .context, text: $0) }
    out += a[prefix..<(a.count - suffix)].map { DiffLine(mark: .removed, text: $0) }
    out += b[prefix..<(b.count - suffix)].map { DiffLine(mark: .added, text: $0) }
    out += a[(a.count - suffix)..<min(a.count, a.count - suffix + context)].map { DiffLine(mark: .context, text: $0) }
    return out
  }
}

public struct DiffLine: Equatable, Sendable {
  public enum Mark: Sendable { case context, added, removed }
  public let mark: Mark
  public let text: String
  public init(mark: Mark, text: String) { self.mark = mark; self.text = text }
}

public struct TimelineImage: Equatable, Sendable {
  public let mediaType: String
  public let data: Data
  public init(mediaType: String, data: Data) { self.mediaType = mediaType; self.data = data }
}

public enum ToolKind: Equatable, Sendable {
  case read(path: String)
  case search(pattern: String, path: String?)
  case edit(path: String, diff: [DiffLine])
  case write(path: String, lines: Int)
  case bash(command: String, summary: String?)
  case task(summary: String)
  case web(String)
  case other(detail: String)
}

public struct ToolResult: Equatable, Sendable {
  public var output: String
  public var isError: Bool
  public var exitCode: Int?
  public var images: [TimelineImage]
  public init(output: String, isError: Bool, exitCode: Int? = nil, images: [TimelineImage] = []) {
    self.output = output
    self.isError = isError
    self.exitCode = exitCode
    self.images = images
  }
}

public struct TimelineRow: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable {
    case user(text: String, images: [TimelineImage])
    case prose(markdown: String)
    case tool(name: String, kind: ToolKind, result: ToolResult?, denied: Bool)
    case command(name: String, output: String?)
    case compact
  }
  public let id: String
  public var kind: Kind
  public let time: Date?
  public let parent: String?
  public init(id: String, kind: Kind, time: Date?, parent: String?) {
    self.id = id
    self.kind = kind
    self.time = time
    self.parent = parent
  }
}

public struct RunningTool: Equatable, Sendable {
  public let id: String
  public let name: String
  public let detail: String
  public let since: Date?
  public init(id: String, name: String, detail: String, since: Date?) {
    self.id = id
    self.name = name
    self.detail = detail
    self.since = since
  }
}

public struct SessionLive: Equatable, Sendable {
  public var working: Bool
  public var tool: RunningTool?
  public var lastActivity: Date?
  public init(working: Bool = false, tool: RunningTool? = nil, lastActivity: Date? = nil) {
    self.working = working
    self.tool = tool
    self.lastActivity = lastActivity
  }
}

public struct SessionUsage: Equatable, Sendable {
  public var model: String?
  public var contextTokens: Int
  public var cost: Double
  public var contextWindow: Int { contextTokens > 200_000 ? 1_000_000 : 200_000 }
  public var contextPercent: Int { min(100, contextTokens * 100 / contextWindow) }
  public init(model: String? = nil, contextTokens: Int = 0, cost: Double = 0) {
    self.model = model
    self.contextTokens = contextTokens
    self.cost = cost
  }
}
