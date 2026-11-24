import Foundation

/// Where a proof entry came from: Glance saw it happen, or Claude reported it through the proof tools (spec §3).
public enum ProofSource: String, Codable, Equatable, Sendable { case glance, claude }

/// What a check run came to: decided from a reliable exit code, else from the runner's own summary (`ProofMatcher.result`).
public enum ProofResult: String, Codable, Equatable, Sendable { case passed, failed }

/// One run of a check the project's setup names (spec §3 "Seen by Glance").
public struct ProofCheckRun: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var environment: String?
  public var command: String
  /// Nil when the hook could not tell (a piped command, an interrupted call): `result` then came from the counts.
  public var exitCode: Int?
  /// Nil in records written before it existed; `ok` then falls back on the exit code.
  public var result: ProofResult?
  public var passed: Int?
  public var failed: Int?
  /// Seconds, when the hook said.
  public var duration: Double?
  public var outputTail: String
  public var at: Date
  public var source: ProofSource
  public var ok: Bool { result.map { $0 == .passed } ?? (exitCode == 0) }

  /// `result` defaults to what the exit code says.
  public init(id: String, name: String, environment: String?, command: String, exitCode: Int?, result: ProofResult? = nil,
              passed: Int? = nil, failed: Int? = nil, duration: Double? = nil, outputTail: String, at: Date,
              source: ProofSource = .glance) {
    self.id = id; self.name = name; self.environment = environment; self.command = command; self.exitCode = exitCode
    self.result = result ?? exitCode.map { $0 == 0 ? .passed : .failed }
    self.passed = passed; self.failed = failed; self.duration = duration; self.outputTail = outputTail; self.at = at
    self.source = source
  }
}

public struct ProofCapture: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case screenshot, clip, explainer, file }
  public enum Purpose: String, Codable, Sendable { case test, outcome }
  public var id: String
  public var kind: Kind
  /// The file's name inside the record's media folder.
  public var file: String
  public var url: String?
  public var environment: String?
  public var caption: String
  public var purpose: Purpose
  public var at: Date
  public var source: ProofSource
  /// Lowercase hex SHA-256 of the file's bytes, so the same image taken as a browser screenshot and then marked as the
  /// outcome is recognised as one (Assets, the timeline tag). Nil in records written before it existed.
  public var sha256: String?

  public init(id: String, kind: Kind, file: String, url: String? = nil, environment: String? = nil, caption: String,
              purpose: Purpose = .test, at: Date, source: ProofSource, sha256: String? = nil) {
    self.id = id; self.kind = kind; self.file = file; self.url = url; self.environment = environment
    self.caption = caption; self.purpose = purpose; self.at = at; self.source = source; self.sha256 = sha256
  }
}

public struct ProofNote: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable { case tried, found, problem, resolved }
  public var id: String
  public var kind: Kind
  public var section: String?
  public var text: String
  public var at: Date

  public init(id: String = UUID().uuidString, kind: Kind, section: String? = nil, text: String, at: Date) {
    self.id = id; self.kind = kind; self.section = section; self.text = text; self.at = at
  }
}

public struct ProofPending: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var text: String
  public var done: Bool
  public var at: Date

  public init(id: String = UUID().uuidString, text: String, done: Bool = false, at: Date) {
    self.id = id; self.text = text; self.done = done; self.at = at
  }
}

public struct ProofVerdict: Codable, Equatable, Sendable {
  public enum Verdict: String, Codable, Sendable, CaseIterable {
    case merge, hold
    case notReady = "not-ready"
  }
  public var verdict: Verdict
  public var reasons: [String]
  public var at: Date

  public init(verdict: Verdict, reasons: [String], at: Date) {
    self.verdict = verdict; self.reasons = reasons; self.at = at
  }
}

/// Make explainer's run for a session (spec §4.3), kept on the record so a restart can say what happened. A finished
/// explainer is not kept here: its video is a capture, shown under Outcome in Assets.
public struct ExplainerState: Codable, Sendable, Equatable {
  public enum Phase: String, Codable, Sendable { case running, failed, done }

  /// A new one for every run, so Retry is never swallowed as "the same capture again".
  public var id: String
  public var phase: Phase
  /// Where the run is, or where it stopped.
  public var step: ExplainerStep
  /// 0...1 within the step, when known.
  public var progress: Double?
  /// What went wrong, or the tail of the command's output.
  public var log: String?
  public var startedAt: Date

  public init(id: String, phase: Phase, step: ExplainerStep, progress: Double? = nil, log: String? = nil, startedAt: Date) {
    self.id = id; self.phase = phase; self.step = step; self.progress = progress; self.log = log; self.startedAt = startedAt
  }

  /// What to show. A `running` state that no run in this Studio owns (`active` false: Studio was quit or crashed
  /// meanwhile) is shown as failed, "Interrupted".
  public func shown(active: Bool) -> Phase { phase == .running && !active ? .failed : phase }
}

/// One Claude session's proof of work (spec §1). The timeline is never stored; gaps are computed (`ProofReview`).
public struct WorkRecord: Codable, Equatable, Sendable {
  public var session: String
  public var cwd: String?
  /// The worktree's root (the folder holding `.git`).
  public var worktree: String?
  public var branch: String?
  /// The git common directory of the repository `branch` was read in (shared by its worktrees), so a removed worktree
  /// still says which repository the proof belongs to. Nil in records written before it existed.
  public var commonDir: String?
  /// The page the Glance browser showed last, from the `Page URL:` its tools report: a screenshot has none of its own.
  public var lastBrowserURL: String?
  public var checks: [ProofCheckRun] = []
  public var captures: [ProofCapture] = []
  public var notes: [ProofNote] = []
  public var pending: [ProofPending] = []
  public var verdict: ProofVerdict?
  /// The last Make explainer run still worth showing: running, or failed. Nil in records written before it existed.
  public var explainer: ExplainerState?
  public var updated: Date

  public init(session: String, updated: Date) {
    self.session = session
    self.updated = updated
  }

  // Tolerant: a record written by an older or newer Glance still opens.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    session = try c.decode(String.self, forKey: .session)
    cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    worktree = try c.decodeIfPresent(String.self, forKey: .worktree)
    branch = try c.decodeIfPresent(String.self, forKey: .branch)
    commonDir = try? c.decodeIfPresent(String.self, forKey: .commonDir)
    lastBrowserURL = try? c.decodeIfPresent(String.self, forKey: .lastBrowserURL)
    checks = (try? c.decodeIfPresent([ProofCheckRun].self, forKey: .checks)) ?? []
    captures = (try? c.decodeIfPresent([ProofCapture].self, forKey: .captures)) ?? []
    notes = (try? c.decodeIfPresent([ProofNote].self, forKey: .notes)) ?? []
    pending = (try? c.decodeIfPresent([ProofPending].self, forKey: .pending)) ?? []
    verdict = try? c.decodeIfPresent(ProofVerdict.self, forKey: .verdict)
    explainer = try? c.decodeIfPresent(ExplainerState.self, forKey: .explainer)
    updated = try c.decode(Date.self, forKey: .updated)
  }

  /// Fills where the session runs: the first cwd and worktree seen stay; the branch follows the latest, and the
  /// repository (`commonDir`) is the one that branch was read in.
  public mutating func place(cwd: String?, worktree: String?, branch: String?, commonDir: String?) {
    if self.cwd == nil { self.cwd = cwd }
    if self.worktree == nil { self.worktree = worktree }
    if let branch {
      self.branch = branch
      self.commonDir = commonDir
    }
  }

  /// Runs kept per check and environment; older ones are dropped as new ones arrive (a hook rewrites the whole file).
  public static let runsKept = 20

  /// Drops all but the latest `runsKept` runs of each check x environment. `checks` is append-ordered, so the later
  /// entries are the newer ones; the rest keep their order.
  public mutating func trimChecks() {
    struct Key: Hashable { var name: String; var environment: String? }
    var seen: [Key: Int] = [:]
    var keep = [Bool](repeating: false, count: checks.count)
    for index in checks.indices.reversed() {
      let key = Key(name: checks[index].name, environment: checks[index].environment)
      let count = seen[key, default: 0]
      if count < Self.runsKept { keep[index] = true }
      seen[key] = count + 1
    }
    if keep.contains(false) { checks = zip(checks, keep).filter(\.1).map(\.0) }
  }

  // Dates are written with fractions of a second so two runs in the same second keep their order. Both spellings
  // (with and without fractions) decode.
  private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
  private static let wholeStyle = Date.ISO8601FormatStyle()

  public static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(fractionalStyle.format(date))
    }
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return e
  }()
  public static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
      let text = try decoder.singleValueContainer().decode(String.self)
      if let date = try? fractionalStyle.parse(text) { return date }
      if let date = try? wholeStyle.parse(text) { return date }
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
    }
    return d
  }()
}
