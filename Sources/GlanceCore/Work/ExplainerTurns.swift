import Foundation

extension TimelineRow {
  /// Claude's own words in the session, not a subagent's.
  var isReply: Bool {
    if case .prose = kind { return parent == nil }
    return false
  }
}

/// One finished turn, for an explainer: what was asked, everything done, and the reply it ended with.
public struct ReplyTurn: Equatable, Sendable {
  public let replyID: String
  public let ask: String?
  /// Every row after the ask, subagents' included.
  public let rows: [TimelineRow]

  public init(replyID: String, ask: String?, rows: [TimelineRow]) {
    self.replyID = replyID
    self.ask = ask
    self.rows = rows
  }

  /// Claude's own prose in the turn, oldest first.
  public var prose: [String] {
    rows.compactMap { row in
      if row.isReply, case .prose(let markdown) = row.kind { return markdown }
      return nil
    }
  }

  /// The block the reply's actions sit under.
  public var reply: String { prose.last ?? "" }
}

/// What Explainer mode does with a reply that just finished (spec 2026-11-03-explainer-mode-design.md §5).
public enum ExplainerAutomatic: Equatable, Sendable {
  case page
  case readAloud
  case nothing
}

/// The steps of turns whose explainer shows, folded to one line each.
public struct ExplainerStepsFold: Equatable, Sendable {
  public struct Line: Equatable, Sendable {
    public let reply: String
    public let count: Int
    public let open: Bool
  }

  /// Blocks not to draw.
  public var hidden: Set<String> = []
  /// The line to draw before a block (the block's id).
  public var lines: [String: Line] = [:]
  public init() {}
}

/// Which replies are finished and what belongs to each. A turn runs from one prompt, command or compaction to the next.
public enum ExplainerTurns {
  /// Under this many words a reply is read aloud instead of getting a page.
  public static let shortReplyWords = 60

  public static func isBoundary(_ row: TimelineRow) -> Bool {
    guard row.parent == nil else { return false }
    switch row.kind {
    case .user, .command, .compact: return true
    case .prose, .tool: return false
    }
  }

  /// The last prose row of each finished turn: every turn but the one Claude is still working on.
  public static func finishedReplies(_ rows: [TimelineRow], working: Bool) -> Set<String> {
    var finished = Set<String>(), current: String?
    for row in rows {
      if isBoundary(row) {
        if let current { finished.insert(current) }
        current = nil
      } else if row.isReply {
        current = row.id
      }
    }
    if !working, let current { finished.insert(current) }
    return finished
  }

  /// The newest finished reply, or nil when there is none.
  public static func newestFinished(_ rows: [TimelineRow], working: Bool) -> String? {
    let finished = finishedReplies(rows, working: working)
    return rows.last { finished.contains($0.id) }?.id
  }

  /// The turn a reply belongs to, when `reply` is its last prose row.
  public static func turn(endingAt reply: String, rows: [TimelineRow]) -> ReplyTurn? {
    guard let index = rows.firstIndex(where: { $0.id == reply && $0.isReply }) else { return nil }
    let start = rows[..<index].lastIndex(where: isBoundary)
    let end = rows[(index + 1)...].firstIndex(where: isBoundary) ?? rows.endIndex
    let body = Array(rows[((start ?? -1) + 1)..<end])
    guard body.last(where: \.isReply)?.id == reply else { return nil }
    var ask: String?
    if let start, case .user(let text, _) = rows[start].kind { ask = text }
    return ReplyTurn(replyID: reply, ask: ask, rows: body)
  }

  /// What the mode does with a finished reply. `ended` is the timeline's `endedTurns`: without it the turn was cut short.
  public static func automatic(reply: String, markdown: String, ended: Set<String>) -> ExplainerAutomatic {
    guard ended.contains(reply) else { return .nothing }
    return wordCount(markdown) < shortReplyWords ? .readAloud : .page
  }

  /// Whether the mode may act on a reply on its own: only one that finished after this session's view opened. A reply
  /// already in the transcript (a reopened session, a relaunch, a large file read in pieces) never spends tokens unasked.
  public static func finishedSince(_ date: Date, reply: TimelineRow) -> Bool {
    guard let time = reply.time else { return false }
    return time > date
  }

  public static func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: \.isWhitespace).count
  }

  /// For each reply in `replies`, its turn's blocks before it fold into one line. Turns in `open` keep theirs in view.
  public static func fold(blocks: [TimelineBlock], replies: Set<String>, open: Set<String>) -> ExplainerStepsFold {
    var fold = ExplainerStepsFold(), steps: [TimelineBlock] = []
    for block in blocks {
      switch block {
      case .row(let row) where isBoundary(row):
        steps = []
      case .row(let row) where replies.contains(row.id):
        if let first = steps.first {
          let opened = open.contains(row.id)
          fold.lines[first.id] = .init(reply: row.id, count: steps.map(stepCount).reduce(0, +), open: opened)
          if !opened { fold.hidden.formUnion(steps.map(\.id)) }
        }
        steps = []
      default:
        steps.append(block)
      }
    }
    return fold
  }

  private static func stepCount(_ block: TimelineBlock) -> Int {
    switch block {
    case .row(let row): if case .prose = row.kind { return 0 } else { return 1 }
    case .group(_, _, let rows): return rows.count
    case .task: return 1
    }
  }
}
