import Foundation

/// One event in a run's log (spec "Runs"): a line of `.runs/<id>/<timestamp>.jsonl`.
public enum RunLogEvent: Equatable, Sendable {
  /// `trigger` is the trigger's summary ("manual", "schedule 0 9 * * 1-5"); `payload` what it carried.
  case runStart(trigger: String, payload: AutomationValue?, inputs: [String: AutomationValue], version: Int)
  case stepStart(step: String)
  case stepOutput(step: String, chunk: String)
  /// A Claude step called a tool.
  case stepTool(step: String, name: String)
  case stepEnd(step: String, status: RunRecord.StepStatus, text: String, json: AutomationValue?, durationMs: Int,
               costUSD: Double?)
  /// Waiting at an outward step for the user.
  case runPark(step: String)
  case runResume(step: String, decision: RunRecord.Decision)
  /// An ask step put its question to the user (the run is parked until the answer).
  case runAsk(AutomationQuestion)
  case runAnswer(step: String, answer: AutomationAnswer)
  case runEnd(status: RunRecord.Status)

  /// The name written as "event": "run.start", "step.end", ….
  public var name: String {
    switch self {
    case .runStart: "run.start"
    case .stepStart: "step.start"
    case .stepOutput: "step.output"
    case .stepTool: "step.tool"
    case .stepEnd: "step.end"
    case .runPark: "run.park"
    case .runResume: "run.resume"
    case .runAsk: "run.ask"
    case .runAnswer: "run.answer"
    case .runEnd: "run.end"
    }
  }
}

/// A line: when, and what. Encoded flat: {"at": "2026-10-09T09:00:00.120Z", "event": "step.end", "step": "fix", …}.
public struct RunLogLine: Codable, Equatable, Sendable {
  public var at: Date
  public var event: RunLogEvent

  public init(at: Date, event: RunLogEvent) {
    self.at = at
    self.event = event
  }

  enum Keys: String, CodingKey {
    case at, event, trigger, payload, inputs, version, step, chunk, name, status, text, json, durationMs, costUSD
    case decision, question, body, choices, allowsText, answer, choice, via
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: Keys.self)
    let stamp = try container.decode(String.self, forKey: .at)
    guard let at = try? RunLog.timestamp.parse(stamp) else {
      throw DecodingError.dataCorruptedError(forKey: .at, in: container, debugDescription: "not a timestamp: \(stamp)")
    }
    self.at = at
    func step() throws -> String { try container.decode(String.self, forKey: .step) }
    switch try container.decode(String.self, forKey: .event) {
    case "run.start":
      event = .runStart(trigger: try container.decode(String.self, forKey: .trigger),
                        payload: try container.decodeIfPresent(AutomationValue.self, forKey: .payload),
                        inputs: try container.decode([String: AutomationValue].self, forKey: .inputs),
                        version: try container.decode(Int.self, forKey: .version))
    case "step.start":
      event = .stepStart(step: try step())
    case "step.output":
      event = .stepOutput(step: try step(), chunk: try container.decode(String.self, forKey: .chunk))
    case "step.tool":
      event = .stepTool(step: try step(), name: try container.decode(String.self, forKey: .name))
    case "step.end":
      event = .stepEnd(step: try step(), status: try container.decode(RunRecord.StepStatus.self, forKey: .status),
                       text: try container.decode(String.self, forKey: .text),
                       json: try container.decodeIfPresent(AutomationValue.self, forKey: .json),
                       durationMs: try container.decode(Int.self, forKey: .durationMs),
                       costUSD: try container.decodeIfPresent(Double.self, forKey: .costUSD))
    case "run.park":
      event = .runPark(step: try step())
    case "run.resume":
      event = .runResume(step: try step(), decision: try container.decode(RunRecord.Decision.self, forKey: .decision))
    case "run.ask":
      event = .runAsk(AutomationQuestion(
        step: try step(), question: try container.decode(String.self, forKey: .question),
        body: try container.decodeIfPresent(String.self, forKey: .body),
        choices: try container.decodeIfPresent([String].self, forKey: .choices) ?? [],
        allowsText: try container.decodeIfPresent(Bool.self, forKey: .allowsText) ?? false))
    case "run.answer":
      event = .runAnswer(step: try step(), answer: AutomationAnswer(
        answer: try container.decode(String.self, forKey: .answer),
        choice: try container.decodeIfPresent(Int.self, forKey: .choice),
        via: try container.decodeIfPresent(AutomationAnswer.Via.self, forKey: .via) ?? .click))
    case "run.end":
      event = .runEnd(status: try container.decode(RunRecord.Status.self, forKey: .status))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .event, in: container, debugDescription: "unknown event \(other)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: Keys.self)
    try container.encode(RunLog.timestamp.format(at), forKey: .at)
    try container.encode(event.name, forKey: .event)
    switch event {
    case .runStart(let trigger, let payload, let inputs, let version):
      try container.encode(trigger, forKey: .trigger)
      try container.encodeIfPresent(payload, forKey: .payload)
      try container.encode(inputs, forKey: .inputs)
      try container.encode(version, forKey: .version)
    case .stepStart(let step), .runPark(let step):
      try container.encode(step, forKey: .step)
    case .stepOutput(let step, let chunk):
      try container.encode(step, forKey: .step)
      try container.encode(chunk, forKey: .chunk)
    case .stepTool(let step, let name):
      try container.encode(step, forKey: .step)
      try container.encode(name, forKey: .name)
    case .stepEnd(let step, let status, let text, let json, let durationMs, let costUSD):
      try container.encode(step, forKey: .step)
      try container.encode(status, forKey: .status)
      try container.encode(text, forKey: .text)
      try container.encodeIfPresent(json, forKey: .json)
      try container.encode(durationMs, forKey: .durationMs)
      try container.encodeIfPresent(costUSD, forKey: .costUSD)
    case .runResume(let step, let decision):
      try container.encode(step, forKey: .step)
      try container.encode(decision, forKey: .decision)
    case .runAsk(let question):
      try container.encode(question.step, forKey: .step)
      try container.encode(question.question, forKey: .question)
      try container.encodeIfPresent(question.body, forKey: .body)
      try container.encode(question.choices, forKey: .choices)
      try container.encode(question.allowsText, forKey: .allowsText)
    case .runAnswer(let step, let answer):
      try container.encode(step, forKey: .step)
      try container.encode(answer.answer, forKey: .answer)
      try container.encodeIfPresent(answer.choice, forKey: .choice)
      try container.encode(answer.via, forKey: .via)
    case .runEnd(let status):
      try container.encode(status, forKey: .status)
    }
  }
}

/// A run as the Runs list and `automation_runs` show it, summarized from its log.
public struct RunRecord: Equatable, Sendable {
  public enum Status: String, Codable, Sendable {
    case running, parked, ok, failed, cancelled, expired
    /// The log stopped without run.end and nothing is running it (Studio quit mid-run).
    case interrupted
  }

  public enum StepStatus: String, Codable, Sendable { case running, ok, failed, skipped, cancelled }

  /// The user's answer at a parked outward step.
  public enum Decision: String, Codable, Sendable { case approve, skip, trust }

  public struct Step: Equatable, Sendable {
    public var id: String
    public var status: StepStatus
    /// The step's result (step.end's text), or the output so far while it runs.
    public var text: String
    public var json: AutomationValue?
    /// Everything it printed, in order.
    public var output: String
    public var tools: [String]
    public var durationMs: Int?
    public var costUSD: Double?
    /// An ask step's question, and the user's answer once given.
    public var question: AutomationQuestion? = nil
    public var answer: AutomationAnswer? = nil
  }

  /// The log's file name without ".jsonl".
  public var id: String
  public var status: Status
  public var trigger: String
  public var inputs: [String: AutomationValue]
  public var version: Int
  public var startedAt: Date
  public var endedAt: Date?
  public var steps: [Step]
  /// The outward step it's waiting at.
  public var parkedAt: String?
  /// The question it's waiting on (an ask step).
  public var question: AutomationQuestion? = nil

  public var durationMs: Int? { endedAt.map { Int(($0.timeIntervalSince(startedAt) * 1000).rounded()) } }
  /// Claude's cost across the steps.
  public var costUSD: Double { steps.compactMap(\.costUSD).reduce(0, +) }
}

/// Run log files: encode and decode lines, summarize a run, name and prune files (spec "Runs").
public enum RunLog {
  public static let keepCount = 200
  public static let keepAge: TimeInterval = 30 * 86_400

  /// ISO 8601 in UTC with milliseconds.
  static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  /// One line of JSON (no newline), keys sorted.
  public static func line(_ entry: RunLogLine) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    // A cost or number that isn't finite is written as "nan", "inf" or "-inf", never dropped with its event.
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return (try? encoder.encode(entry)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  /// Every line that decodes; a blank or broken line (a crash mid-write) is skipped. Only "\n" (or "\r\n") ends a
  /// line: U+2028, U+2029 and U+0085 can sit raw inside a JSON string.
  public static func decode(_ text: String) -> [RunLogLine] {
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    return text.utf8.split(separator: 10).compactMap { bytes in
      let trimmed = bytes.last == 13 ? bytes.dropLast() : bytes
      return try? decoder.decode(RunLogLine.self, from: Data(trimmed))
    }
  }

  /// The run a log describes; nil without a run.start. `live` says whether the engine is still running it: a log
  /// with no run.end that isn't live was interrupted.
  public static func summarize(_ lines: [RunLogLine], id: String, live: Bool) -> RunRecord? {
    guard let first = lines.first, case .runStart(let trigger, _, let inputs, let version) = first.event else {
      return nil
    }
    var record = RunRecord(id: id, status: live ? .running : .interrupted, trigger: trigger, inputs: inputs,
                           version: version, startedAt: first.at, endedAt: nil, steps: [], parkedAt: nil)
    func update(_ step: String, _ change: (inout RunRecord.Step) -> Void) {
      if let index = record.steps.lastIndex(where: { $0.id == step }) { change(&record.steps[index]) }
    }
    for line in lines.dropFirst() {
      switch line.event {
      case .runStart:
        break
      case .stepStart(let step):
        record.steps.append(RunRecord.Step(id: step, status: .running, text: "", json: nil, output: "", tools: [],
                                           durationMs: nil, costUSD: nil))
      case .stepOutput(let step, let chunk):
        update(step) { $0.output += chunk }
      case .stepTool(let step, let name):
        update(step) { $0.tools.append(name) }
      case .stepEnd(let step, let status, let text, let json, let durationMs, let costUSD):
        if !record.steps.contains(where: { $0.id == step }) {
          record.steps.append(RunRecord.Step(id: step, status: status, text: "", json: nil, output: "", tools: [],
                                             durationMs: nil, costUSD: nil))
        }
        update(step) {
          $0.status = status
          $0.text = text
          $0.json = json
          $0.durationMs = durationMs
          $0.costUSD = costUSD
        }
      case .runPark(let step):
        record.parkedAt = step
        if live { record.status = .parked }
      case .runResume:
        record.parkedAt = nil
        if live { record.status = .running }
      case .runAsk(let question):
        update(question.step) { $0.question = question }
        record.parkedAt = question.step
        record.question = question
        if live { record.status = .parked }
      case .runAnswer(let step, let answer):
        update(step) { $0.answer = answer }
        record.parkedAt = nil
        record.question = nil
        if live { record.status = .running }
      case .runEnd(let status):
        record.status = status
        record.endedAt = line.at
        record.parkedAt = nil
        record.question = nil
      }
    }
    for index in record.steps.indices where record.steps[index].status == .running {
      if record.steps[index].text.isEmpty { record.steps[index].text = record.steps[index].output }
      if record.endedAt != nil || !live { record.steps[index].status = .cancelled }
    }
    return record
  }

  /// "2026-10-09T09-00-00.120Z.jsonl": UTC, sorts by time, no colons (Finder shows them as "/").
  public static func fileName(for start: Date) -> String {
    timestamp.format(start).replacingOccurrences(of: ":", with: "-") + ".jsonl"
  }

  /// When a run started, from its file name.
  public static func start(ofFile name: String) -> Date? {
    guard name.hasSuffix(".jsonl") else { return nil }
    var stamp = String(name.dropLast(".jsonl".count))
    guard let time = stamp.firstIndex(of: "T") else { return nil }
    stamp = String(stamp[...time]) + stamp[stamp.index(after: time)...].replacingOccurrences(of: "-", with: ":")
    return try? timestamp.parse(stamp)
  }

  /// The log files to delete at launch: older than 30 days, or beyond the newest 200. Names that aren't run logs
  /// are left alone.
  public static func prune(_ names: [String], now: Date) -> [String] {
    let dated = names.compactMap { name in start(ofFile: name).map { (name, $0) } }.sorted { $0.1 > $1.1 }
    return dated.enumerated().filter { index, file in
      index >= keepCount || now.timeIntervalSince(file.1) > keepAge
    }.map(\.element.0)
  }
}
