import CryptoKit
import Foundation

/// The summarizer's `claude -p` (spec 2026-10-11-humanize-summaries-design.md, "Summary engine"): no tools, no hooks,
/// no MCP, nothing saved, Haiku. It always writes in Glance Humanize, whatever the Response style (the summary's own
/// voice, not a restyling of replies).
public enum TranscriptSummaryPrompt {
  /// Bump when the outline or prompts change: every saved summary is then rebuilt on its next request.
  public static let version = 1
  public static let model = "claude-haiku-4-5"
  /// About 40k tokens of digest per call.
  public static let chunkCharacters = 160_000

  public static let outline = """
    You summarize a Claude Code session for the person who ran it. Write markdown with these headings, in this order, \
    leaving one out only when there is nothing for it: ## Goal, ## What got done, ## Key decisions, ## Outcome, \
    ## Open issues. Synthesize the work; never replay the conversation turn by turn. Keep file names, commands, errors \
    and numbers exact. Add a small Mermaid diagram only when the work has a real flow. Reply with the summary only.
    """

  public static func arguments(style: String) -> [String] {
    ["-p", "--output-format", "json", "--no-session-persistence", "--tools", "",
     "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--model", model,
     "--append-system-prompt", style.isEmpty ? outline : style + "\n\n" + outline]
  }

  public static func firstPrompt(digest: String) -> String {
    "Summarize this Claude Code session.\n\n<session>\n\(digest)\n</session>"
  }

  public static func revisePrompt(previous: String, digest: String) -> String {
    "Here is the summary so far, then what happened next in the session. Revise the summary so it covers both, and "
      + "reply with the whole revised summary.\n\n<summary>\n\(previous)\n</summary>\n\n<next>\n\(digest)\n</next>"
  }
}

/// One session's saved summary (Application Support/Glance/Summaries/<session>.json).
public struct SummaryRecord: Codable, Equatable, Sendable {
  public var sessionID: String
  public var transcriptPath: String
  public var cwd: String?
  public var title: String?
  public var coveredBytes: Int
  public var coveredTurns: Int
  public var headHash: String
  public var promptVersion: Int
  public var summary: String
  public var updatedAt: Date

  public init(sessionID: String, transcriptPath: String, cwd: String?, title: String?, coveredBytes: Int,
              coveredTurns: Int, headHash: String, promptVersion: Int, summary: String, updatedAt: Date) {
    self.sessionID = sessionID
    self.transcriptPath = transcriptPath
    self.cwd = cwd
    self.title = title
    self.coveredBytes = coveredBytes
    self.coveredTurns = coveredTurns
    self.headHash = headHash
    self.promptVersion = promptVersion
    self.summary = summary
    self.updatedAt = updatedAt
  }
}

public enum SummaryFreshness: Equatable, Sendable {
  /// The transcript is as it was: show it, no call.
  case fresh
  /// It grew: the summary is behind by some turns.
  case stale
  /// It shrank or was rewritten, or the prompt changed: start over.
  case rebuild
}

public enum SummaryCache {
  public static let headLength = 4096

  /// SHA-256 of the transcript's first `headLength` bytes: a rewritten file has another head.
  public static func headHash(_ head: Data) -> String {
    SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
  }

  public static func freshness(_ record: SummaryRecord, fileSize: Int, headHash: String,
                               promptVersion: Int) -> SummaryFreshness {
    if record.promptVersion != promptVersion || record.headHash != headHash || fileSize < record.coveredBytes {
      return .rebuild
    }
    return fileSize == record.coveredBytes ? .fresh : .stale
  }
}

public enum SummaryTrigger: Equatable, Sendable {
  /// Summarize or Refresh clicked.
  case userAsked
  /// The summary view opened.
  case opened
  /// A turn ended and a quiet minute passed (Always only asks then).
  case turnFinished
}

public enum SummaryStep: Equatable, Sendable {
  case none
  /// Show what's saved, with its freshness.
  case show
  case generate(incremental: Bool)
}

/// When a call happens (spec 2026-10-11-humanize-summaries-design.md, "Modes"). `freshness` is nil when nothing is
/// saved for the session.
public enum SummaryPolicy {
  public static func step(mode: SummaryMode, trigger: SummaryTrigger, freshness: SummaryFreshness?) -> SummaryStep {
    switch (trigger, freshness) {
    case (.userAsked, nil), (.userAsked, .rebuild?): return .generate(incremental: false)
    case (.userAsked, .stale?): return .generate(incremental: true)
    case (.userAsked, .fresh?): return .show
    case (.opened, nil): return mode == .manual ? .none : .generate(incremental: false)
    case (.opened, _?): return .show
    case (.turnFinished, let freshness):
      guard mode == .always else { return .none }
      switch freshness {
      case nil, .rebuild?: return .generate(incremental: false)
      case .stale?: return .generate(incremental: true)
      case .fresh?: return .none
      }
    }
  }
}

/// One summary run per session at a time; asks during a run make one rerun after it.
public struct SummaryJobs: Sendable {
  private var running: Set<String> = []
  private var rerun: Set<String> = []

  public init() {}

  /// True: start now. False: one is running; it reruns when it finishes.
  public mutating func start(_ sessionID: String) -> Bool {
    if running.contains(sessionID) {
      rerun.insert(sessionID)
      return false
    }
    running.insert(sessionID)
    return true
  }

  /// True: a rerun was asked for, and it's running now.
  public mutating func finish(_ sessionID: String) -> Bool {
    if rerun.remove(sessionID) != nil { return true }
    running.remove(sessionID)
    return false
  }

  public func isRunning(_ sessionID: String) -> Bool { running.contains(sessionID) }
}
