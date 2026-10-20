import Foundation

/// What a session tells the orb about itself (`status`). Named apart from the panel's `OrbState` (PanelState.swift).
public enum ChannelOrbState: String, Codable, CaseIterable, Sendable {
  case working, waiting, done, error, idle
}

/// One tool call, checked (spec "The tools").
public enum ChannelCall: Equatable, Sendable {
  case nudge(title: String, body: String?, actions: [String], waitSeconds: Int)
  case ask(question: String, choices: [String], allowText: Bool, speak: Bool, waitSeconds: Int)
  case checkAnswer(id: String, waitSeconds: Int)
  case speak(text: String, interrupt: Bool)
  case tell(markdown: String, size: TellCard.Size, speak: Bool)
  case status(text: String?, state: ChannelOrbState?)
  case dismiss(id: String)

  // Secrets (spec 2026-10-10-secrets-broker-design.md): any session; Studio answers only with Feature.secrets on.
  case secretsList
  case httpRequest(SecretHTTPCall)

  // The orb assistant only (spec "The orb assistant").
  case approve(tool: String, input: JSONValue)
  case notifications(filter: String)
  case calendar(days: Int)
  case sessions
  case meetingNotes(query: String?)
  case tickets
  case open(target: String)
  case messageSession(session: String, text: String)
  case startSession(folder: String, prompt: String)
}

/// The tools' schemas for `tools/list` and their argument checks. Errors name the field, in a sentence Claude can act
/// on.
public enum ChannelTools {
  public struct Failure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
  }

  static let waitRange = 1...540
  public static let speakLimit = 400
  /// `http_request`: the most `body` text taken inline (the request body limit), and header entries.
  static let requestBodyLimit = 10 * 1024 * 1024
  static let headerLimit = 50

  public static func definitions(assistant: Bool) -> [JSONValue] {
    assistant ? sessionTools + assistantTools : sessionTools + secretTools
  }

  static let sessionTools: [JSONValue] = [
    tool("nudge", "Show the user a card at the top of their screen (the orb glows). Without actions it returns at "
         + "once. With actions (button titles, at most 3) it waits for the click and returns {action} or "
         + "{dismissed}, or {status: \"pending\", id} if they haven't chosen in time.",
         ["title": string("One line: what happened."), "body": string("Optional detail, a sentence or two."),
          "actions": strings("Up to 3 short button titles."),
          "wait_seconds": integer("How long to wait for a click, 1–540. Default 300.")], required: ["title"]),
    tool("ask", "Ask the user a question and wait for the answer: a card with choice buttons and a reply field, read "
         + "aloud. Returns {answer, via: click|text|voice}, or {status: \"pending\", id} if they haven't answered in "
         + "time (the card stays; use check_answer).",
         ["question": string("The question, one or two sentences."),
          "choices": strings("Up to 4 short answers to offer as buttons."),
          "allow_text": boolean("Let the user type or say any answer. Default true."),
          "speak": boolean("Read the question aloud. Default true."),
          "wait_seconds": integer("How long to wait, 1–540. Default 300.")], required: ["question"]),
    tool("check_answer", "Collect the answer to an earlier ask or nudge that returned status pending.",
         ["id": string("The id ask or nudge returned."),
          "wait_seconds": integer("How long to wait for it, 0–540. Default 0 (just look).")], required: ["id"]),
    tool("speak", "Say something out loud in Glance's voice (at most 400 characters). Returns when it has been said, "
         + "or {skipped: reason} (in a meeting, Do not disturb, or the user turned speech off).",
         ["text": string("What to say."), "interrupt": boolean("Cut off whatever Glance is saying. Default false.")],
         required: ["text"]),
    tool("tell", "Tell the user something in Glance's own card beside the orb, read aloud: use it when the user asked "
         + "to be told something (\"let me know when CI finishes\"). Markdown (tables, lists, code) up to 20000 "
         + "characters; the card fits the content. Returns {shown, spoken}.",
         ["markdown": string("What to tell, as markdown. Lead with one short sentence."),
          "size": .object(["type": "string", "enum": ["auto", "short", "full"],
                           "description": "auto (default) fits the content; short keeps it small; full opens it tall."]),
          "speak": boolean("Read it aloud. Default true.")], required: ["markdown"]),
    tool("status", "Set this session's state on the orb, with a short caption.",
         ["text": string("A few words: what you're doing."),
          "state": .object(["type": "string", "enum": ["working", "waiting", "done", "error", "idle"],
                            "description": "working, waiting (you need the user), done, error, or idle."])],
         required: []),
    tool("dismiss", "Take away a card this session showed.", ["id": string("The card's id.")], required: ["id"]),
  ]

  /// Sessions only: the orb assistant doesn't get the secrets tools in S1 (spec "Session tools only").
  static let secretTools: [JSONValue] = [
    tool("secrets_list", "The user's secrets this session may use with http_request: name, what it's for, the hosts "
         + "it may be sent to, how it's sent, and whether the user is asked first. Never the values: you can't see "
         + "them, and you don't need to.", [:], required: []),
    tool("http_request", "Make an HTTPS request with one of the user's secrets added by Glance (you never see it). "
         + "Only to the secret's hosts; the user may be asked to approve. Returns {status, headers, body} or "
         + "{status, headers, saved_to, bytes}; any echo of the secret comes back as [secret NAME].",
         ["secret": string("The secret's name from secrets_list."),
          "method": .object(["type": "string", "enum": ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"],
                             "description": "Default GET."]),
          "url": string("The full https:// URL."),
          "headers": .object(["type": "object", "additionalProperties": ["type": "string"],
                              "description": "Extra headers (not the secret's own header, not Authorization)."]),
          "body": string("The request body, as text."),
          "body_file": string("Or: a file in the project folder to send as the body."),
          "save_to": string("A file in the project folder to write the response body to (needed over 1 MB or for "
                            + "binary bodies).")],
         required: ["secret", "url"]),
  ]

  static let assistantTools: [JSONValue] = [
    tool("approve", "Glance's permission prompt: asks the user to allow or deny a tool call.",
         ["tool_name": string("The tool."), "input": .object(["type": "object", "description": "Its input."])],
         required: ["tool_name", "input"]),
    tool("notifications", "The user's notifications in Glance (Slack, GitHub, meetings, Claude sessions, tickets).",
         ["filter": .object(["type": "string", "enum": ["unread", "needs_you", "all"],
                             "description": "unread (default), needs_you, or all."])], required: []),
    tool("calendar", "The user's meetings from today on.",
         ["days": integer("How many days, 1–7. Default 1 (today).")], required: []),
    tool("sessions", "The user's Claude Code sessions connected to Glance: folder, state, what they're doing, and "
         + "whether they can be messaged.", [:], required: []),
    tool("meeting_notes", "Notes of the user's recorded meetings: overview, decisions, action items.",
         ["query": string("Words to look for in the title or notes; leave out for the latest.")], required: []),
    tool("tickets", "The user's tickets, in today's order.", [:], required: []),
    tool("open", "Open something in Glance Studio: a notification (its id), a session (its name from sessions()), or "
         + "a GitHub pull request (URL or owner/repo#number).", ["target": string("What to open.")],
         required: ["target"]),
    tool("message_session", "Send a message to one of the user's Claude sessions (by its name from sessions()).",
         ["session": string("The session's name from sessions()."), "text": string("The message.")],
         required: ["session", "text"]),
    tool("start_session", "Open a new Studio terminal tab in a folder running Claude Code with a first prompt.",
         ["folder": string("The project folder (absolute or ~/…)."), "prompt": string("What to ask Claude.")],
         required: ["folder", "prompt"]),
  ]

  public static func parse(name: String, arguments: JSONValue, assistant: Bool) -> Result<ChannelCall, Failure> {
    let args = Arguments(arguments)
    do {
      switch name {
      case "nudge":
        let actions = try args.strings("actions", max: 3, tooMany: "nudge takes at most 3 actions.")
        return .success(.nudge(title: try args.text("title"), body: try args.optionalText("body"), actions: actions,
                               waitSeconds: try args.integer("wait_seconds", in: waitRange, default: 300)))
      case "ask":
        let choices = try args.strings("choices", max: 4, tooMany: "ask takes at most 4 choices.")
        let allowText = try args.flag("allow_text", default: true)
        guard !choices.isEmpty || allowText else { throw Failure("ask needs choices or allow_text.") }
        return .success(.ask(question: try args.text("question"), choices: choices, allowText: allowText,
                             speak: try args.flag("speak", default: true),
                             waitSeconds: try args.integer("wait_seconds", in: waitRange, default: 300)))
      case "check_answer":
        return .success(.checkAnswer(id: try args.text("id"),
                                     waitSeconds: try args.integer("wait_seconds", in: 0...540, default: 0)))
      case "speak":
        let text = try args.text("text")
        guard text.count <= speakLimit else {
          throw Failure("speak takes at most 400 characters; put the rest in a nudge.")
        }
        return .success(.speak(text: text, interrupt: try args.flag("interrupt", default: false)))
      case "tell":
        let markdown = try args.text("markdown")
        guard markdown.count <= 20_000 else { throw Failure("tell takes at most 20000 characters.") }
        let size = try args.optionalText("size").map { raw -> TellCard.Size in
          guard let size = TellCard.Size(rawValue: raw) else { throw Failure("size must be one of auto, short, full.") }
          return size
        } ?? .auto
        return .success(.tell(markdown: markdown, size: size, speak: try args.flag("speak", default: true)))
      case "status":
        let text = try args.optionalText("text")
        let state = try args.optionalText("state").map { raw -> ChannelOrbState in
          guard let state = ChannelOrbState(rawValue: raw) else {
            throw Failure("state must be one of working, waiting, done, error, idle.")
          }
          return state
        }
        guard text != nil || state != nil else { throw Failure("status needs text or state.") }
        return .success(.status(text: text, state: state))
      case "dismiss":
        return .success(.dismiss(id: try args.text("id")))
      case "secrets_list" where !assistant:
        return .success(.secretsList)
      case "http_request" where !assistant:
        let method = (try args.optionalText("method") ?? "GET").uppercased()
        guard SecretRequestPolicy.methods.contains(method) else {
          throw Failure("method must be one of \(SecretRequestPolicy.methods.sorted().joined(separator: ", ")).")
        }
        let body = try args.rawText("body")
        let bodyFile = try args.optionalText("body_file")
        guard body == nil || bodyFile == nil else { throw Failure("Give body or body_file, not both.") }
        guard (body?.utf8.count ?? 0) <= requestBodyLimit else {
          throw Failure("body is over 10 MB; put it in a file and give body_file.")
        }
        let headers = try args.stringMap("headers")
        guard headers.count <= headerLimit else { throw Failure("headers takes at most \(headerLimit) entries.") }
        return .success(.httpRequest(SecretHTTPCall(
          secret: try args.text("secret"), method: method, url: try args.text("url"),
          headers: headers, body: body, bodyFile: bodyFile, saveTo: try args.optionalText("save_to"))))
      case "approve" where assistant:
        guard let input = args.values["input"], input != .null else { throw Failure("input is required.") }
        return .success(.approve(tool: try args.text("tool_name"), input: input))
      case "notifications" where assistant:
        let filter = try args.optionalText("filter") ?? "unread"
        guard ["unread", "needs_you", "all"].contains(filter) else {
          throw Failure("filter must be one of unread, needs_you, all.")
        }
        return .success(.notifications(filter: filter))
      case "calendar" where assistant:
        return .success(.calendar(days: try args.integer("days", in: 1...7, default: 1)))
      case "sessions" where assistant:
        return .success(.sessions)
      case "meeting_notes" where assistant:
        return .success(.meetingNotes(query: try args.optionalText("query")))
      case "tickets" where assistant:
        return .success(.tickets)
      case "open" where assistant:
        return .success(.open(target: try args.text("target")))
      case "message_session" where assistant:
        return .success(.messageSession(session: try args.text("session"), text: try args.text("text")))
      case "start_session" where assistant:
        return .success(.startSession(folder: try args.text("folder"), prompt: try args.text("prompt")))
      default:
        throw Failure("Unknown tool \(name).")
      }
    } catch let failure as Failure {
      return .failure(failure)
    } catch {
      return .failure(Failure(String(describing: error)))
    }
  }

  // MARK: - Schemas

  static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue],
                   required: [String]) -> JSONValue {
    ["name": .string(name), "description": .string(description),
     "inputSchema": ["type": "object", "properties": .object(properties),
                     "required": .array(required.map(JSONValue.string))]]
  }
  static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
  static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
  static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }
  static func strings(_ description: String) -> JSONValue {
    ["type": "array", "items": ["type": "string"], "description": .string(description)]
  }

  /// Reads one call's arguments, throwing a `Failure` that names the field.
  struct Arguments {
    let values: [String: JSONValue]
    init(_ value: JSONValue) { values = value.object ?? [:] }

    func text(_ key: String) throws -> String {
      guard let value = try optionalText(key) else { throw Failure("\(key) is required.") }
      return value
    }

    /// Trimmed; nil when missing, null or blank.
    func optionalText(_ key: String) throws -> String? {
      guard let value = values[key], value != .null else { return nil }
      guard let text = value.string else { throw Failure("\(key) must be a string.") }
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }

    /// Untrimmed; nil when missing or null.
    func rawText(_ key: String) throws -> String? {
      guard let value = values[key], value != .null else { return nil }
      guard let text = value.string else { throw Failure("\(key) must be a string.") }
      return text
    }

    func stringMap(_ key: String) throws -> [String: String] {
      guard let value = values[key], value != .null else { return [:] }
      guard let object = value.object else { throw Failure("\(key) must be an object of strings.") }
      return try object.mapValues { item in
        guard let text = item.string else { throw Failure("\(key) must be an object of strings.") }
        return text
      }
    }

    func strings(_ key: String, max: Int, tooMany: String) throws -> [String] {
      guard let value = values[key], value != .null else { return [] }
      guard let items = value.array else { throw Failure("\(key) must be a list of strings.") }
      let texts = try items.map { item -> String in
        guard let text = item.string else { throw Failure("\(key) must be strings.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      guard texts.count <= max else { throw Failure(tooMany) }
      return texts
    }

    func integer(_ key: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
      guard let value = values[key], value != .null else { return fallback }
      guard let number = value.int, range.contains(number) else {
        throw Failure("\(key) must be between \(range.lowerBound) and \(range.upperBound).")
      }
      return number
    }

    func flag(_ key: String, default fallback: Bool) throws -> Bool {
      guard let value = values[key], value != .null else { return fallback }
      guard let flag = value.bool else { throw Failure("\(key) must be true or false.") }
      return flag
    }
  }
}
