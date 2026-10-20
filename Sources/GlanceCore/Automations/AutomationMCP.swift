import Foundation

/// One JSON-RPC 2.0 message Claude Code sends `glance automation mcp` (spec 2026-10-09-automations-design.md, "Claude:
/// skill + Glance MCP": stdio, MCP protocol 2025-06-18). Ids are numbers or strings and go back as they came.
public enum AutomationMCPMessage: Equatable, Sendable {
  case request(id: AutomationValue, method: String, params: [String: AutomationValue])
  /// No id: nothing goes back (notifications/initialized, notifications/cancelled), and responses to requests this
  /// server never sends.
  case notification(method: String)
  /// Can't be acted on: the error to send (id null when it couldn't be read).
  case invalid(id: AutomationValue, code: Int, message: String)
}

/// A tool call whose arguments were checked.
public enum AutomationMCPCall: Equatable, Sendable {
  case search(query: String, limit: Int)
  case get(id: String, file: String?)
  case run(id: String, inputs: [String: AutomationValue], wait: Bool)
  case runs(id: String, run: String?, limit: Int)
  /// `files` go over the files read from `from` (a draft folder: `<library>/.drafts/<id>`, written relative to the
  /// library or absolute). With no `from`, `files` go over the package already in the library.
  case save(id: String, files: [String: String], delete: [String], from: String?)
  case events
}

/// What the server does with a message.
public enum AutomationMCPReply: Equatable, Sendable {
  /// Write this line.
  case send(String)
  /// Carry out the call, then write `AutomationMCP.toolResult(id:text:isError:)`.
  case call(id: AutomationValue, AutomationMCPCall)
  case none
}

/// Why a tool call's arguments were refused (the tool result says so, with isError).
public struct AutomationMCPArgumentError: Error, Equatable, Sendable {
  public var message: String

  public init(_ message: String) { self.message = message }
}

/// The Glance MCP's protocol side: reading lines, the initialize / tools/list / tools/call / ping answers, the six
/// tools' schemas and argument checks. `glance automation mcp` (GlanceCLI) carries the calls out.
public enum AutomationMCP {
  public static let protocolVersion = "2025-06-18"
  public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
  public static let serverName = "glance"
  /// Claude Code names a plugin's MCP tools `mcp__plugin_<plugin>_<server>__<tool>` (plugin "glance", server
  /// "glance"); the server-wide permission rule is the prefix without its last "__".
  public static let toolPrefix = "mcp__plugin_glance_glance__"
  public static var serverRule: String { String(toolPrefix.dropLast(2)) }
  /// `automation_run` waits at most this long for the run to end.
  public static let waitLimit: TimeInterval = 600
  /// The most one input line may hold (a save's files fit inside); a longer line is refused, never parsed.
  public static let maxLineBytes = 4_000_000
  /// `automation_save`: one file's text, all the files' text together, and how many paths one save names.
  public static let maxFileBytes = 1_000_000
  public static let maxFilesBytes = 2_000_000
  public static let maxPaths = 500
  /// `automation_run`: the inputs, as JSON.
  public static let maxInputsBytes = 256_000

  /// Rules 1 and 2 of the skill: Claude Code shows these to every session the server is in.
  public static let instructions = """
    Glance automations are the user's saved tools in Glance Studio: triggers, script and Claude steps, and an \
    optional page. Before writing a script, pipeline or tool the user may want again, call automations_search; if \
    something close exists, run it (automation_run) or extend it with a new input, trigger or step, never a \
    near-duplicate. When the user asks for something an automation already does, run it with automation_run instead \
    of doing the work by hand. To build or change one, use the glance-automations skill.
    """

  // MARK: Lines

  /// What an input line over `maxLineBytes` is answered with (never parsed).
  public static let lineTooLong = AutomationMCPMessage.invalid(
    id: .null, code: -32600, message: "Invalid request: the line is too long.")

  public static func parse(_ line: String) -> AutomationMCPMessage {
    guard line.utf8.count <= maxLineBytes else { return lineTooLong }
    guard let value = AutomationValue.decode(Data(line.utf8)) else {
      return .invalid(id: .null, code: -32700, message: "Parse error: the line isn't JSON.")
    }
    guard let object = value.object else {
      return .invalid(id: .null, code: -32600, message: "Invalid request: expected a JSON object.")
    }
    let id = object["id"] ?? .null
    guard case .string(let method)? = object["method"] else {
      // A response (this server sends no requests): nothing to answer.
      if object["result"] != nil || object["error"] != nil { return .notification(method: "") }
      switch id {
      case .string, .number: return .invalid(id: id, code: -32600, message: "Invalid request: no method.")
      default: return .invalid(id: .null, code: -32600, message: "Invalid request: no method.")
      }
    }
    switch id {
    case .null where object["id"] == nil:
      return .notification(method: method)
    case .string, .number:
      break
    default:
      return .invalid(id: .null, code: -32600, message: "Invalid request: the id must be a number or a string.")
    }
    switch object["params"] {
    case nil, .null?: return .request(id: id, method: method, params: [:])
    case .object(let params)?: return .request(id: id, method: method, params: params)
    default: return .invalid(id: id, code: -32602, message: "Invalid params: expected an object.")
    }
  }

  /// The answer to a message. `version` is Glance's own (serverInfo).
  public static func reply(to message: AutomationMCPMessage, version: String) -> AutomationMCPReply {
    switch message {
    case .notification:
      return .none
    case .invalid(let id, let code, let text):
      return .send(error(id: id, code: code, message: text))
    case .request(let id, let method, let params):
      switch method {
      case "initialize":
        let asked = params["protocolVersion"].flatMap { value -> String? in
          if case .string(let text) = value { return text }
          return nil
        }
        return .send(response(id: id, result: initializeResult(asked: asked, version: version)))
      case "ping":
        return .send(response(id: id, result: .object([:])))
      case "tools/list":
        return .send(response(id: id, result: .object(["tools": tools])))
      case "tools/call":
        guard case .string(let name)? = params["name"], toolNames.contains(name) else {
          return .send(error(id: id, code: -32602, message: "Unknown tool. The tools are "
                               + toolNames.joined(separator: ", ") + "."))
        }
        let arguments: [String: AutomationValue]
        switch params["arguments"] {
        case nil, .null?: arguments = [:]
        case .object(let given)?: arguments = given
        default: return .send(error(id: id, code: -32602, message: "Invalid params: arguments must be an object."))
        }
        switch call(name: name, arguments: arguments) {
        case .success(let call): return .call(id: id, call)
        case .failure(let refusal): return .send(toolResult(id: id, text: refusal.message, isError: true))
        }
      default:
        return .send(error(id: id, code: -32601, message: "Method not found: \(method)"))
      }
    }
  }

  public static func initializeResult(asked: String?, version: String) -> AutomationValue {
    let agreed = asked.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? protocolVersion
    return .object([
      "protocolVersion": .string(agreed),
      "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
      "serverInfo": .object(["name": .string(serverName), "title": .string("Glance automations"),
                             "version": .string(version)]),
      "instructions": .string(instructions),
    ])
  }

  public static func response(id: AutomationValue, result: AutomationValue) -> String {
    AutomationValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).json
  }

  public static func error(id: AutomationValue, code: Int, message: String) -> String {
    AutomationValue.object(["jsonrpc": .string("2.0"), "id": id,
                            "error": .object(["code": .number(Double(code)), "message": .string(message)])]).json
  }

  /// A tools/call result: the text, and isError for a refusal or a failure (MCP's tool errors).
  public static func toolResult(id: AutomationValue, text: String, isError: Bool) -> String {
    response(id: id, result: .object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                      "isError": .bool(isError)]))
  }

  // MARK: Tools

  public static let toolNames = ["automations_search", "automation_get", "automation_run", "automation_runs",
                                 "automation_save", "automation_events"]

  /// tools/list's `tools`.
  public static var tools: AutomationValue {
    func tool(_ name: String, _ title: String, _ description: String, readOnly: Bool,
              _ properties: [String: AutomationValue], required: [String]) -> AutomationValue {
      .object([
        "name": .string(name), "title": .string(title), "description": .string(description),
        "inputSchema": .object(["type": .string("object"), "properties": .object(properties),
                                "required": .array(required.map(AutomationValue.string)),
                                "additionalProperties": .bool(false)]),
        "annotations": .object(["readOnlyHint": .bool(readOnly)]),
      ])
    }
    func field(_ type: String, _ description: String) -> AutomationValue {
      .object(["type": .string(type), "description": .string(description)])
    }
    let id = field("string", "The automation's id (its folder name).")
    return .array([
      tool("automations_search", "Search automations",
           "Search the user's Glance automations: saved tools with triggers, script and Claude steps. Call it before "
             + "writing any script, pipeline or tool the user may want again; if one is close, run or extend it. "
             + "An empty query lists them all.",
           readOnly: true,
           ["query": field("string", "Words to look for in names, tags, descriptions, inputs and READMEs."),
            "limit": field("integer", "At most this many matches (1 to 50, default 10).")],
           required: ["query"]),
      tool("automation_get", "Read an automation",
           "An automation's automation.json, README and file list; with file, that file's text.",
           readOnly: true, ["id": id, "file": field("string", "A path inside the package, like steps/fetch.sh.")],
           required: ["id"]),
      tool("automation_run", "Run an automation",
           "Runs an automation in Glance Studio with these inputs and, unless wait is false, waits up to 10 minutes "
             + "for the result. It must be approved and switched on in Studio. A step marked outward waits for the "
             + "user's approval in Studio (unless they trust the automation), and an ask step waits for the user's answer: "
             + "then the status is parked.",
           readOnly: false,
           ["id": id, "inputs": field("object", "Input values by name; missing ones take their defaults."),
            "wait": field("boolean", "Wait for the run to end (default true).")],
           required: ["id"]),
      tool("automation_runs", "List runs",
           "An automation's recent runs (newest first), or with run, that run's steps and results.",
           readOnly: true, ["id": id, "run": field("string", "A run's id from the list."),
                            "limit": field("integer", "At most this many runs (1 to 50, default 10).")],
           required: ["id"]),
      tool("automation_save", "Save an automation",
           "Saves a package into the library: the files of the draft folder `from` (drafts live in "
             + "<library>/.drafts/<id>; a relative path starts at the library, an absolute one must resolve there; "
             + "the folder must hold that automation's automation.json; symlinks inside it are refused), then "
             + "`files` (path to text) over them, minus `delete`. With `files` alone, it edits the current package. "
             + "Glance validates it first and writes nothing when something is wrong; then it bumps the version and "
             + "commits. Saving never approves: new or changed permissions and triggers wait for the user's approval "
             + "in Studio.",
           readOnly: false,
           ["id": id,
            "files": field("object", "Package path to the file's full text (automation.json too, for a new one)."),
            "delete": field("array", "Package paths to remove."),
            "from": field("string", "The draft folder: .drafts/<id> in the library, or its absolute path.")],
           required: ["id"]),
      tool("automation_events", "List Glance events",
           "The Glance events an automation's event trigger can name, with their payload fields.",
           readOnly: true, [:], required: []),
    ])
  }

  /// Checks a tool's arguments.
  public static func call(name: String, arguments: [String: AutomationValue])
    -> Result<AutomationMCPCall, AutomationMCPArgumentError> {
    do {
      let known: Set<String>
      let call: AutomationMCPCall
      switch name {
      case "automations_search":
        known = ["query", "limit"]
        call = .search(query: try text("query", arguments) ?? "", limit: try count("limit", arguments, default: 10))
      case "automation_get":
        known = ["id", "file"]
        let file = try text("file", arguments)
        if let file {
          if file.isEmpty {
            throw AutomationMCPArgumentError("file can't be empty; leave it out for the whole package.")
          }
          try packagePath(file, as: "file")
        }
        call = .get(id: try automation(arguments), file: file)
      case "automation_run":
        known = ["id", "inputs", "wait"]
        let inputs: [String: AutomationValue]
        switch arguments["inputs"] {
        case nil, .null?: inputs = [:]
        case .object(let given)?: inputs = given
        default:
          throw AutomationMCPArgumentError(#"inputs must be an object of input values, like {"repo": "acme/app"}."#)
        }
        guard AutomationValue.object(inputs).json.utf8.count <= maxInputsBytes else {
          throw AutomationMCPArgumentError("inputs are too large: at most \(maxInputsBytes / 1000) KB.")
        }
        let wait: Bool
        switch arguments["wait"] {
        case nil, .null?: wait = true
        case .bool(let given)?: wait = given
        default: throw AutomationMCPArgumentError("wait must be true or false.")
        }
        call = .run(id: try automation(arguments), inputs: inputs, wait: wait)
      case "automation_runs":
        known = ["id", "run", "limit"]
        let run = try text("run", arguments)
        if let run, !isRunID(run) { throw AutomationMCPArgumentError("run must be a run id from automation_runs.") }
        call = .runs(id: try automation(arguments), run: run, limit: try count("limit", arguments, default: 10))
      case "automation_save":
        known = ["id", "files", "delete", "from"]
        var files: [String: String] = [:]
        switch arguments["files"] {
        case nil, .null?: break
        case .object(let given)?:
          guard given.count <= maxPaths else {
            throw AutomationMCPArgumentError("files names too many paths: at most \(maxPaths) in one save.")
          }
          var total = 0
          for (path, value) in given.sorted(by: { $0.key < $1.key }) {
            guard case .string(let content) = value else {
              throw AutomationMCPArgumentError("files[\"\(path)\"] must be the file's text.")
            }
            try packagePath(path, as: "files[\"\(path)\"]")
            guard content.utf8.count <= maxFileBytes else {
              throw AutomationMCPArgumentError(
                "files[\"\(path)\"] is too large: at most \(maxFileBytes / 1_000_000) MB a file.")
            }
            total += content.utf8.count
            guard total <= maxFilesBytes else {
              throw AutomationMCPArgumentError("files are too large: at most \(maxFilesBytes / 1_000_000) MB together.")
            }
            files[path] = content
          }
        default: throw AutomationMCPArgumentError("files must be an object of package path to text.")
        }
        var delete: [String] = []
        switch arguments["delete"] {
        case nil, .null?: break
        case .array(let given)?:
          guard given.count <= maxPaths else {
            throw AutomationMCPArgumentError("delete names too many paths: at most \(maxPaths) in one save.")
          }
          for value in given {
            guard case .string(let path) = value else {
              throw AutomationMCPArgumentError("delete must list package paths.")
            }
            try packagePath(path, as: "delete")
            delete.append(path)
          }
        default: throw AutomationMCPArgumentError("delete must list package paths.")
        }
        let from = try text("from", arguments)
        if let from, from.utf8.count > 1024 || from.unicodeScalars.contains("\0") {
          throw AutomationMCPArgumentError("from must be a folder path.")
        }
        guard !files.isEmpty || !delete.isEmpty || !(from ?? "").isEmpty else {
          throw AutomationMCPArgumentError("Give files, from (a folder) or delete: there's nothing to save.")
        }
        call = .save(id: try automation(arguments), files: files, delete: delete, from: from)
      case "automation_events":
        known = []
        call = .events
      default:
        throw AutomationMCPArgumentError("There's no tool \(name).")
      }
      if let extra = arguments.keys.sorted().first(where: { !known.contains($0) }) {
        throw AutomationMCPArgumentError("\(name) has no argument \(extra).")
      }
      return .success(call)
    } catch let error as AutomationMCPArgumentError {
      return .failure(error)
    } catch {
      return .failure(AutomationMCPArgumentError("\(error)"))
    }
  }

  static func automation(_ arguments: [String: AutomationValue]) throws -> String {
    guard case .string(let id)? = arguments["id"], AutomationManifest.isID(id) else {
      throw AutomationMCPArgumentError("id must be an automation's id: 1 to 48 lowercase letters, digits or dashes.")
    }
    guard !AutomationLibraryLayout.reservedIDs.contains(id) else {
      throw AutomationMCPArgumentError("`\(id)` is reserved by the library and can't be an automation's id.")
    }
    return id
  }

  /// A path inside a package: the same rule `automation_save` applies (no `..`, no leading `/`, no hidden files).
  static func packagePath(_ path: String, as name: String) throws {
    if path.unicodeScalars.contains("\0") || path.utf8.count > 512 || AutomationSave.pathProblem(path) != nil {
      throw AutomationMCPArgumentError(
        "\(name) must be a file inside the package (no `..`, no leading `/`, no hidden files).")
    }
  }

  static func text(_ name: String, _ arguments: [String: AutomationValue]) throws -> String? {
    switch arguments[name] {
    case nil, .null?: return nil
    case .string(let value)?: return value
    default: throw AutomationMCPArgumentError("\(name) must be text.")
    }
  }

  static func count(_ name: String, _ arguments: [String: AutomationValue], default value: Int) throws -> Int {
    switch arguments[name] {
    case nil, .null?: return value
    case .number(let number)? where number.rounded() == number && number >= 1 && number <= 50: return Int(number)
    default: throw AutomationMCPArgumentError("\(name) must be a whole number from 1 to 50.")
    }
  }

  /// A run's id is its log's file name: letters, digits, "-", "." and ":" only (never a path).
  public static func isRunID(_ text: String) -> Bool {
    !text.isEmpty && text.count <= 64 && !text.hasPrefix(".")
      && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-.:_".contains($0)) }
  }
}

/// How the tools' results read: JSON text for Claude, plain sentences for refusals.
public enum AutomationMCPText {
  /// One automation in a search result.
  public static func listing(_ manifest: AutomationManifest, enabled: Bool, approved: Bool) -> AutomationValue {
    .object([
      "id": .string(manifest.id), "name": .string(manifest.name), "description": .string(manifest.description),
      "version": .number(Double(manifest.version)), "tags": .array(manifest.tags.map(AutomationValue.string)),
      "inputs": .array(manifest.inputs.map { input in
        var fields: [String: AutomationValue] = ["name": .string(input.name), "type": .string(input.type),
                                                 "required": .bool(input.required)]
        if let description = input.description { fields["description"] = .string(description) }
        if let value = input.default { fields["default"] = value }
        if let options = input.options { fields["options"] = .array(options.map(AutomationValue.string)) }
        return .object(fields)
      }),
      "triggers": .array(manifest.triggers.map { .string($0.summary) }),
      "enabled": .bool(enabled), "approved": .bool(approved),
    ])
  }

  public static func search(_ listings: [AutomationValue], query: String) -> String {
    guard !listings.isEmpty else {
      return query.isEmpty ? "The library is empty. Build one with the glance-automations skill."
        : "No automation matches \"\(query)\". Build one with the glance-automations skill."
    }
    return AutomationValue.object(["matches": .array(listings)]).json
  }

  public static func package(manifest: String, readme: String, files: [String]) -> String {
    var parts = ["automation.json:\n" + manifest]
    if !readme.isEmpty { parts.append("README.md:\n" + readme) }
    parts.append("Files:\n" + files.sorted().map { "- " + $0 }.joined(separator: "\n"))
    return parts.joined(separator: "\n\n")
  }

  /// After a save: the version and commit, and what the user has to do in Studio.
  public static func saved(id: String, name: String, version: Int, commit: String?,
                           approval: AutomationApprovalStatus) -> String {
    let stamp = commit.map { " (commit \($0.prefix(7)))" } ?? " (no history: git isn't installed)"
    let next: String
    switch approval {
    case .approved:
      next = "Its approval still holds: the new steps stay inside the permissions the user approved."
    case .changed:
      next = "It needs approval again: its permissions or triggers changed. Tell the user to approve it in Glance "
        + "Studio (Automations, \(name), Setup) before its triggers run."
    case .never:
      next = "It needs approval: tell the user to approve it in Glance Studio (Automations, \(name), Setup). Until "
        + "then its triggers stay off and it can't run."
    }
    return "Saved \(id) v\(version)\(stamp). " + next
  }

  public static func notFound(_ id: String) -> String { "There's no automation `\(id)` in the library." }
}
