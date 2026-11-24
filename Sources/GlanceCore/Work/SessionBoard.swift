import Foundation

/// The board's columns (spec 2026-11-01-command-center-design.md §5), in order.
public enum BoardLane: String, CaseIterable, Sendable {
  case needsYou, working, ready, done
  public var title: String {
    switch self {
    case .needsYou: "Needs you"
    case .working: "Working"
    case .ready: "Ready for review"
    case .done: "Idle / Done"
    }
  }
}

/// What a session is doing now.
public enum BoardState: Equatable, Sendable {
  case waiting(title: String)
  case thinking
  case tool(RunningTool)
  case idle(since: Date?)
  case ended(at: Date?)
}

/// A session's PR as the card shows it: a label, never a link out.
public struct BoardPR: Equatable, Sendable {
  public var number: Int
  public var merged: Bool
  public var checks: PullRequests.Checks.State
  public init(number: Int, merged: Bool, checks: PullRequests.Checks.State) {
    self.number = number; self.merged = merged; self.checks = checks
  }
}

public struct BoardCheckDot: Equatable, Sendable {
  public enum Result: Equatable, Sendable { case passed, failed, notRun }
  public var name: String
  public var result: Result
  public init(name: String, result: Result) { self.name = name; self.result = result }
}

public struct BoardEnvironmentDots: Equatable, Sendable {
  public var environment: String
  public var checks: [BoardCheckDot]
  public init(environment: String, checks: [BoardCheckDot]) { self.environment = environment; self.checks = checks }
}

public struct BoardCounts: Equatable, Sendable {
  public var needsYou = 0, working = 0, ready = 0, failing = 0
  public init(needsYou: Int = 0, working: Int = 0, ready: Int = 0, failing: Int = 0) {
    self.needsYou = needsYou; self.working = working; self.ready = ready; self.failing = failing
  }
}

/// One session on the board. Built from the ledger, links, prompts and its record; holds no live objects.
public struct BoardCard: Equatable, Identifiable, Sendable {
  public enum Place: Equatable, Sendable {
    /// In a Studio split: it can be opened, replied to and answered.
    case studio(surface: UUID)
    /// Elsewhere ("Warp"): read-only, as there is no surface to type into.
    case external(String)
    case nowhere
  }

  /// The session id.
  public var id: String
  public var title: String
  public var project: String
  public var repo: String?
  public var branch: String?
  public var worktree: String?
  public var cwd: String?
  public var transcript: String?
  public var place: Place
  public var state: BoardState
  public var pill: ProofPill
  public var gaps: [ProofGap]
  public var dots: [BoardEnvironmentDots]
  public var pending: Int
  public var capture: ProofCapture?
  public var pr: BoardPR?
  /// A check's latest run failed.
  public var failing: Bool
  /// More than one session or author in this worktree (the existing worktree warning).
  public var mixed: Bool
  public var activity: Date

  public init(id: String, title: String, project: String, repo: String? = nil, branch: String? = nil, worktree: String? = nil,
              cwd: String? = nil, transcript: String? = nil, place: Place, state: BoardState, pill: ProofPill,
              gaps: [ProofGap] = [], dots: [BoardEnvironmentDots] = [], pending: Int = 0, capture: ProofCapture? = nil,
              pr: BoardPR? = nil, failing: Bool = false, mixed: Bool = false, activity: Date) {
    self.id = id; self.title = title; self.project = project; self.repo = repo; self.branch = branch
    self.worktree = worktree; self.cwd = cwd; self.transcript = transcript; self.place = place; self.state = state
    self.pill = pill; self.gaps = gaps; self.dots = dots; self.pending = pending; self.capture = capture; self.pr = pr
    self.failing = failing; self.mixed = mixed; self.activity = activity
  }

  public var isEnded: Bool { if case .ended = state { true } else { false } }
  public var isWaiting: Bool { if case .waiting = state { true } else { false } }
  public var isWorking: Bool {
    switch state {
    case .thinking, .tool: true
    default: false
    }
  }
  public var criticalGap: ProofGap? { gaps.first { $0.level == .crit } }
  /// A reply needs a surface to type into and a session to hear it.
  public var canReply: Bool {
    if case .studio = place, !isEnded { return true }
    return false
  }
}

public enum SessionBoard {
  /// Ended is always Done, and a prompt is always Needs you, even on a merged PR (it must never hide in Done). Failed work
  /// beats Working: a session fixing its own failing test still sits in Needs you.
  public static func lane(_ card: BoardCard) -> BoardLane {
    if card.isEnded { return .done }
    if card.isWaiting { return .needsYou }
    if card.pr?.merged == true { return card.isWorking ? .working : .done }
    if card.pill == .needsWork || card.criticalGap != nil { return .needsYou }
    if card.isWorking { return .working }
    return card.pill == .ready ? .ready : .done
  }

  /// A lane's cards: what most needs the user first, then the most recent, then by id so equal cards never swap.
  public static func ordered(_ cards: [BoardCard], in lane: BoardLane) -> [BoardCard] {
    cards.filter { self.lane($0) == lane }.sorted {
      (urgency($0), $1.activity, $0.id) < (urgency($1), $0.activity, $1.id)
    }
  }

  /// Every card in board order: the lanes left to right, top to bottom (`j`/`k`).
  public static func ordered(_ cards: [BoardCard]) -> [BoardCard] {
    BoardLane.allCases.flatMap { ordered(cards, in: $0) }
  }

  private static func urgency(_ card: BoardCard) -> Int {
    if card.isWaiting { return 0 }
    if card.pill == .needsWork { return 1 }
    return card.criticalGap != nil ? 2 : 3
  }

  public static func counts(_ cards: [BoardCard]) -> BoardCounts {
    var counts = BoardCounts()
    for card in cards {
      switch lane(card) {
      case .needsYou: counts.needsYou += 1
      case .working: counts.working += 1
      case .ready: counts.ready += 1
      case .done: break
      }
      if card.failing { counts.failing += 1 }
    }
    return counts
  }

  /// The project filter, or nil once no card belongs to that project any more.
  public static func keeping(filter: String?, in cards: [BoardCard]) -> String? {
    filter.flatMap { name in cards.contains { $0.project == name } ? name : nil }
  }

  public static func failing(_ record: WorkRecord?) -> Bool {
    record.map { ProofReview.latestRuns($0).contains { !$0.ok } } ?? false
  }

  /// One row per environment. The setup's environments and checks when there is one, else what the record ran.
  public static func dots(record: WorkRecord?, setup: ProofSetup?) -> [BoardEnvironmentDots] {
    let checks = record?.checks ?? []
    let environments = setup?.environments.map(\.name) ?? Array(Set(checks.compactMap(\.environment))).sorted()
    let names = setup?.checks.map(\.name) ?? Array(Set(checks.map(\.name))).sorted()
    guard !environments.isEmpty, !names.isEmpty else { return [] }
    return environments.map { environment in
      BoardEnvironmentDots(environment: environment, checks: names.map { name in
        guard let record, let run = ProofReview.latest(record, name: name, environment: environment) else {
          return BoardCheckDot(name: name, result: .notRun)
        }
        return BoardCheckDot(name: name, result: run.ok ? .passed : .failed)
      })
    }
  }

  /// `ended` wins (a dead session has no prompt), then the prompt, then the transcript.
  public static func state(live: SessionLive?, waitingTitle: String?, ended: Date?) -> BoardState {
    if let ended { return .ended(at: ended) }
    if let waitingTitle { return .waiting(title: waitingTitle) }
    if let tool = live?.tool { return .tool(tool) }
    if live?.working == true { return .thinking }
    return .idle(since: live?.lastActivity)
  }
}
