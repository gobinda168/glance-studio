import Foundation

/// What `glance automation mcp` asks Studio's engine over `automations.sock` (spec "Claude: skill + Glance MCP": run,
/// runs, status). One request per connection: a JSON line out, a JSON line back.
public enum AutomationSocketRequest: Equatable, Sendable {
  case run(id: String, inputs: [String: AutomationValue], wait: Bool)
  case runs(id: String, run: String?, limit: Int)
  case status

  /// The request's line, without its line break.
  public var line: String {
    switch self {
    case .run(let id, let inputs, let wait):
      return AutomationValue.object(["op": .string("run"), "id": .string(id), "inputs": .object(inputs),
                                     "wait": .bool(wait)]).json
    case .runs(let id, let run, let limit):
      var fields: [String: AutomationValue] = ["op": .string("runs"), "id": .string(id),
                                               "limit": .number(Double(limit))]
      if let run { fields["run"] = .string(run) }
      return AutomationValue.object(fields).json
    case .status:
      return AutomationValue.object(["op": .string("status")]).json
    }
  }

  /// A request line, or why Studio won't act on it.
  public static func parse(_ line: String) -> Result<AutomationSocketRequest, AutomationMCPArgumentError> {
    guard let object = AutomationValue.decode(Data(line.utf8))?.object, case .string(let op)? = object["op"] else {
      return .failure(AutomationMCPArgumentError("Studio got something that isn't a request."))
    }
    if op == "status" { return .success(.status) }
    guard case .string(let id)? = object["id"], AutomationManifest.isID(id) else {
      return .failure(AutomationMCPArgumentError("The request needs an automation's id."))
    }
    switch op {
    case "run":
      let inputs = object["inputs"]?.object ?? [:]
      let wait: Bool
      if case .bool(let given)? = object["wait"] { wait = given } else { wait = true }
      return .success(.run(id: id, inputs: inputs, wait: wait))
    case "runs":
      var run: String?
      if case .string(let given)? = object["run"] {
        guard AutomationMCP.isRunID(given) else { return .failure(AutomationMCPArgumentError("That isn't a run id.")) }
        run = given
      }
      var limit = 10
      if case .number(let given)? = object["limit"] { limit = min(max(Int(given), 1), 50) }
      return .success(.runs(id: id, run: run, limit: limit))
    default:
      return .failure(AutomationMCPArgumentError("Studio doesn't know the request \(op)."))
    }
  }
}

/// Studio's answer: a result, or why not in plain words.
public enum AutomationSocketResponse: Equatable, Sendable {
  case ok(AutomationValue)
  case failed(String)

  public var line: String {
    switch self {
    case .ok(let result): return AutomationValue.object(["ok": .bool(true), "result": result]).json
    case .failed(let reason): return AutomationValue.object(["ok": .bool(false), "error": .string(reason)]).json
    }
  }

  public static func parse(_ line: String) -> AutomationSocketResponse {
    guard let object = AutomationValue.decode(Data(line.utf8))?.object, case .bool(let ok)? = object["ok"] else {
      return .failed("Glance Studio sent something unreadable.")
    }
    if ok { return .ok(object["result"] ?? .null) }
    if case .string(let reason)? = object["error"] { return .failed(reason) }
    return .failed("Glance Studio said no without a reason.")
  }
}

/// The socket's place and the results it carries.
public enum AutomationSocketWire {
  public static let fileName = "automations.sock"
  /// Overrides the path (the CLI checks; never set in Studio).
  public static let environmentKey = "GLANCE_AUTOMATIONS_SOCKET"
  /// sockaddr_un's sun_path holds 104 bytes with the closing zero.
  public static let maxPathBytes = 103
  /// A run Claude starts through the MCP: its run log's trigger.
  public static let trigger = "claude"
  /// A step's text in a result is cut to this many characters (the run log keeps all of it).
  public static let textLimit = 4000
  public static let notRunning = "Glance Studio isn't running."

  /// ~/Library/Application Support/Glance/automations.sock, or the environment's override.
  public static func path(environment: [String: String], home: String) -> String {
    if let given = environment[environmentKey], !given.isEmpty { return given }
    return home + "/Library/Application Support/Glance/" + fileName
  }

  public static func fits(_ path: String) -> Bool { !path.isEmpty && path.utf8.count <= maxPathBytes }

  /// A run that ended or parked: `{status, run, steps: [{id, status, text}]}`; parked adds `step` and `message`.
  public static func runResult(_ record: RunRecord) -> AutomationValue {
    var fields: [String: AutomationValue] = [
      "status": .string(record.status.rawValue), "run": .string(record.id),
      "steps": .array(record.steps.map { step in
        var fields: [String: AutomationValue] = ["id": .string(step.id), "status": .string(step.status.rawValue),
                                                 "text": .string(cut(step.text))]
        if let json = step.json { fields["json"] = json }
        return .object(fields)
      }),
    ]
    if record.status == .parked, let step = record.parkedAt {
      fields["step"] = .string(step)
      if let question = record.question {
        fields["question"] = .string(question.question)
        fields["message"] = .string("Waiting for the user's answer to `\(step)` in Glance Studio.")
      } else {
        fields["message"] = .string("Waiting for the user's approval of `\(step)` in Glance Studio.")
      }
    }
    if record.costUSD > 0 { fields["costUSD"] = .number(record.costUSD) }
    return .object(fields)
  }

  /// A run that started but didn't end within the wait (or wasn't waited for).
  public static func running(_ ref: AutomationRunRef) -> AutomationValue {
    .object(["status": .string("running"), "run": .string(ref.run),
             "message": .string("Still running. Check it with automation_runs.")])
  }

  /// Another run of it is going: this one waits its turn (1 is next).
  public static func queued(_ place: Int) -> AutomationValue {
    .object(["status": .string("queued"), "place": .number(Double(place)),
             "message": .string("Another run is going; this one starts after it.")])
  }

  /// automation_runs without a run: newest first.
  public static func runsResult(_ records: [RunRecord]) -> AutomationValue {
    .array(records.map { record in
      .object(["run": .string(record.id), "status": .string(record.status.rawValue),
               "trigger": .string(record.trigger), "startedAt": .string(RunLog.timestamp.format(record.startedAt)),
               "durationMs": record.durationMs.map { .number(Double($0)) } ?? .null,
               "version": .number(Double(record.version))])
    })
  }

  /// automation_runs with a run: the run, its inputs, and each step's result, tools and the end of its output.
  public static func runDetail(_ record: RunRecord) -> AutomationValue {
    guard case .object(var fields) = runResult(record) else { return .null }
    fields["trigger"] = .string(record.trigger)
    fields["inputs"] = .object(record.inputs)
    fields["startedAt"] = .string(RunLog.timestamp.format(record.startedAt))
    fields["steps"] = .array(record.steps.map { step in
      var fields: [String: AutomationValue] = [
        "id": .string(step.id), "status": .string(step.status.rawValue), "text": .string(cut(step.text)),
        "output": .string(String(step.output.suffix(textLimit))),
        "tools": .array(step.tools.map(AutomationValue.string)),
      ]
      if let json = step.json { fields["json"] = json }
      if let duration = step.durationMs { fields["durationMs"] = .number(Double(duration)) }
      return .object(fields)
    })
    return .object(fields)
  }

  static func cut(_ text: String) -> String {
    text.count <= textLimit ? text : String(text.prefix(textLimit)) + "\n[cut: the run log has all of it]"
  }
}
