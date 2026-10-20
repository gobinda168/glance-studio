import Foundation

/// A glance.js call (spec 2026-10-09-automations-design.md, "Web UI contract"), decoded from the JSON text the page
/// posts to Studio's `glance` message handler.
public enum AutomationBridgeRequest: Equatable, Sendable {
  case run(inputs: [String: AutomationValue])
  case cancel(run: String)
  case runs(limit: Int)
  case stateGet(key: String)
  /// `.null` removes the key.
  case stateSet(key: String, value: AutomationValue)
  case openURL(String)
  case reveal(String)
}

/// Why a call was refused: the page's promise rejects with this message.
public struct AutomationBridgeError: Error, Equatable, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

/// The page side of the automation tab: what glance.js may ask, and what Studio tells it about the runs it started.
public enum AutomationBridge {
  /// `window.webkit.messageHandlers.glance`.
  public static let handlerName = "glance"
  public static let keyLimit = 200
  public static let runsLimit = 200
  public static let defaultRuns = 20

  /// A call, or why it's refused. Every field is checked here, so Studio acts only on well-formed calls.
  public static func decode(_ text: String) -> Result<AutomationBridgeRequest, AutomationBridgeError> {
    func fail(_ message: String) -> Result<AutomationBridgeRequest, AutomationBridgeError> {
      .failure(AutomationBridgeError(message))
    }
    guard let object = AutomationValue.decode(Data(text.utf8))?.object else {
      return fail("glance.js sent something that isn't a JSON object.")
    }
    guard case .string(let op)? = object["op"] else { return fail("A call needs an op.") }
    switch op {
    case "run":
      switch object["inputs"] {
      case nil, .null?: return .success(.run(inputs: [:]))
      case .object(let inputs)?: return .success(.run(inputs: inputs))
      default: return fail(#"glance.run takes an object of inputs, like { repo: "acme/app" }."#)
      }
    case "cancel":
      guard case .string(let run)? = object["runID"], isRunID(run) else {
        return fail("glance.cancel takes the id of a run.")
      }
      return .success(.cancel(run: run))
    case "runs":
      switch object["limit"] {
      case nil, .null?:
        return .success(.runs(limit: defaultRuns))
      case .number(let limit)? where limit >= 1 && limit.rounded() == limit:
        return .success(.runs(limit: Int(min(limit, Double(runsLimit)))))
      default:
        return fail("glance.runs takes a whole number of runs, 1 or more.")
      }
    case "state.get", "state.set":
      guard case .string(let key)? = object["key"], (1...keyLimit).contains(key.count) else {
        return fail("glance.state keys are text of 1 to \(keyLimit) characters.")
      }
      return .success(op == "state.get" ? .stateGet(key: key) : .stateSet(key: key, value: object["value"] ?? .null))
    case "openURL":
      guard case .string(let url)? = object["url"], !url.trimmingCharacters(in: .whitespaces).isEmpty else {
        return fail("glance.openURL takes a link or a path.")
      }
      return .success(.openURL(url))
    case "reveal":
      guard case .string(let path)? = object["path"], !path.trimmingCharacters(in: .whitespaces).isEmpty else {
        return fail("glance.reveal takes a path.")
      }
      return .success(.reveal(path))
    default:
      return fail("glance has no `\(op)`.")
    }
  }

  /// A run's id: its log's file name without ".jsonl" ("2026-10-09T09-00-00.120Z").
  public static func isRunID(_ id: String) -> Bool {
    !id.contains("/") && RunLog.start(ofFile: id + ".jsonl") != nil
  }

  /// What the page hears about a run it started (`window.__glanceReceive`): a step starting, waiting at an outward
  /// step or ending, and output as it comes. nil for the lines it doesn't hear (run.end comes as `done`).
  public static func event(run: String, _ event: RunLogEvent) -> AutomationValue? {
    func make(_ type: String, _ fields: [String: AutomationValue]) -> AutomationValue {
      .object(fields.merging(["type": .string(type), "runID": .string(run)]) { $1 })
    }
    switch event {
    case .stepStart(let step):
      return make("step", ["step": .string(step), "status": .string("running")])
    case .runPark(let step):
      return make("step", ["step": .string(step), "status": .string("waiting")])
    case .runAsk(let question):
      return make("step", ["step": .string(question.step), "status": .string("waiting"),
                           "question": .string(question.question),
                           "choices": .array(question.choices.map(AutomationValue.string))])
    case .stepOutput(let step, let chunk):
      return make("output", ["step": .string(step), "chunk": .string(chunk)])
    case .stepEnd(let step, let status, let text, let json, _, _):
      var fields: [String: AutomationValue] = ["step": .string(step), "status": .string(status.rawValue),
                                               "text": .string(text)]
      if let json { fields["json"] = json }
      return make("step", fields)
    case .runStart, .stepTool, .runResume, .runAnswer, .runEnd:
      return nil
    }
  }

  /// The run ended: `done` resolves with `{status, steps}`, every step's result.
  public static func done(_ record: RunRecord) -> AutomationValue {
    .object(["type": .string("done"), "runID": .string(record.id), "status": .string(record.status.rawValue),
             "steps": .array(record.steps.map(step))])
  }

  static func step(_ step: RunRecord.Step) -> AutomationValue {
    var fields: [String: AutomationValue] = ["id": .string(step.id), "status": .string(step.status.rawValue),
                                             "text": .string(step.text)]
    if let json = step.json { fields["json"] = json }
    return .object(fields)
  }

  /// glance.runs: `[{id, status, trigger, startedAt, durationMs}]` as given (newest first); `durationMs` is null
  /// while a run goes.
  public static func runs(_ records: [RunRecord]) -> AutomationValue {
    .array(records.map { record in
      .object(["id": .string(record.id), "status": .string(record.status.rawValue),
               "trigger": .string(record.trigger), "startedAt": .string(RunLog.timestamp.format(record.startedAt)),
               "durationMs": record.durationMs.map { .number(Double($0)) } ?? .null])
    })
  }

  /// `window.__glanceBoot`: glance.automation (`{id, name, version, inputs}`, inputs shaped as in automation.json)
  /// and the theme the page starts in.
  public static func boot(_ manifest: AutomationManifest, dark: Bool) -> AutomationValue {
    var inputs: [String: AutomationValue] = [:]
    for input in manifest.inputs {
      var fields: [String: AutomationValue] = ["type": .string(input.type), "required": .bool(input.required)]
      if let value = input.default { fields["default"] = value }
      if let description = input.description { fields["description"] = .string(description) }
      if let options = input.options { fields["options"] = .array(options.map(AutomationValue.string)) }
      inputs[input.name] = .object(fields)
    }
    let automation: AutomationValue = .object([
      "id": .string(manifest.id), "name": .string(manifest.name), "version": .number(Double(manifest.version)),
      "inputs": .object(inputs),
    ])
    return .object(["automation": automation, "theme": .string(dark ? "dark" : "light")])
  }

  /// The app's appearance changed: glance.theme and the "themechange" event.
  public static func theme(dark: Bool) -> AutomationValue {
    .object(["type": .string("theme"), "theme": .string(dark ? "dark" : "light")])
  }
}

/// glance.state (spec "Web UI contract"): one JSON object per automation, in the library's state/<id>.json. Pure:
/// Studio reads and writes the file.
public enum AutomationUIState {
  public static let limit = 1_000_000

  /// The key's value; null when it's not there (or the file is missing or unreadable).
  public static func get(_ file: Data?, key: String) -> AutomationValue {
    object(file)[key] ?? .null
  }

  /// The file with `key` set (`.null` removes it): pretty, sorted, at most 1 MB.
  public static func set(_ file: Data?, key: String, value: AutomationValue) -> Result<Data, AutomationBridgeError> {
    var members = object(file)
    members[key] = value == .null ? nil : value
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(AutomationValue.object(members)) else {
      return .failure(AutomationBridgeError("glance.state couldn't write that value."))
    }
    guard data.count <= limit else {
      return .failure(AutomationBridgeError(
        "glance.state holds at most 1 MB per automation; this would make it \(data.count / 1000) KB."))
    }
    return .success(data)
  }

  static func object(_ file: Data?) -> [String: AutomationValue] {
    file.flatMap(AutomationValue.decode)?.object ?? [:]
  }
}

/// Where glance.openURL and a link clicked in an automation's page go (spec: "routed through Studio's own routes (PR
/// pages, Razor, Chats); never a browser for github.com").
public enum AutomationLinks {
  public enum Route: Equatable, Sendable {
    /// A pull request or issue: a PR tab in Studio.
    case pullRequest(repository: String, number: Int)
    /// A Slack workspace: its Chats tab.
    case slack(team: String)
    /// A path (absolute, "~/…", or a file: URL's): the editor, Quick Look or Finder.
    case file(String)
    /// Any other web page: the browser.
    case browser(URL)
    case refused(String)
  }

  public static func route(_ text: String) -> Route {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .refused("There's no link.") }
    // Only "~" and "~/…" are the user's home; "~someone/…" is not a path Studio opens.
    if trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") { return .file(trimmed) }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
      return .refused("`\(trimmed)` isn't a link or a path.")
    }
    switch scheme {
    case "file":
      return .file(url.path)
    case "http", "https":
      // "https:/github.com/x" and "https:github.com/x" have no host and a browser might still open them.
      guard var host = url.host?.lowercased(), !host.isEmpty else {
        return .refused("That web link has no host.")
      }
      while host.hasSuffix(".") { host.removeLast() }
      if host == "github.com" || host.hasSuffix(".github.com") {
        let parts = url.path.split(separator: "/").map(String.init)
        if parts.count >= 4, ["pull", "issues"].contains(parts[2]), let number = Int(parts[3]), number >= 1,
           isRepositoryPart(parts[0]), isRepositoryPart(parts[1]) {
          return .pullRequest(repository: "\(parts[0])/\(parts[1])", number: number)
        }
        return .refused("Studio opens GitHub pull requests and issues; other GitHub pages aren't opened.")
      }
      if let team = SlackURL.teamID(url) { return .slack(team: team) }
      return .browser(url)
    default:
      return .refused("Only web links and files open from an automation.")
    }
  }

  /// An owner or repository name: letters, digits, ".", "_" and "-", and not "." or "..".
  static func isRepositoryPart(_ text: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    return text != "." && text != ".." && !text.isEmpty && text.unicodeScalars.allSatisfy(allowed.contains)
  }
}
