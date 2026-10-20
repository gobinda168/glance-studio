import Foundation

/// Something wrong with an automation package: where (a JSON path into automation.json such as "steps[2].tools", or a
/// package file such as "prompts/fix.md") and what, in plain words.
public struct AutomationProblem: Equatable, Hashable, Sendable, CustomStringConvertible {
  public var path: String
  public var message: String

  public init(_ path: String, _ message: String) {
    self.path = path
    self.message = message
  }

  /// "steps[2].tools: `Write` isn't in permissions.tools".
  public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

/// One input the automation takes (its form field, `{{inputs.name}}`, `GLANCE_INPUTS`).
public struct AutomationInput: Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable { case string, number, boolean, `enum`, path, text }

  public var name: String
  /// The raw type; `kind` is nil when it isn't one Glance knows (validation says so).
  public var type: String
  public var required: Bool
  public var `default`: AutomationValue?
  public var description: String?
  /// The choices of an enum input.
  public var options: [String]?

  public var kind: Kind? { Kind(rawValue: type) }

  public init(name: String, type: String = "string", required: Bool = false, default: AutomationValue? = nil,
              description: String? = nil, options: [String]? = nil) {
    self.name = name
    self.type = type
    self.required = required
    self.default = `default`
    self.description = description
    self.options = options
  }
}

/// What starts a run besides the user. Fields are flat, as in automation.json; which ones apply depends on `kind`.
public struct AutomationTrigger: Codable, Equatable, Sendable {
  public enum Kind: String, CaseIterable, Sendable { case manual, schedule, files, event, watcher }

  /// The raw kind; `typed` is nil when it isn't one Glance knows (validation says so).
  public var kind: String
  public var cron: String?
  public var path: String?
  public var glob: String?
  public var name: String?
  /// Event triggers: equality on payload fields.
  public var filter: [String: AutomationValue]?
  public var script: String?
  public var every: String?
  /// Input values this trigger runs with.
  public var inputs: [String: AutomationValue]?

  public var typed: Kind? { Kind(rawValue: kind) }

  public init(kind: String, cron: String? = nil, path: String? = nil, glob: String? = nil, name: String? = nil,
              filter: [String: AutomationValue]? = nil, script: String? = nil, every: String? = nil,
              inputs: [String: AutomationValue]? = nil) {
    self.kind = kind
    self.cron = cron
    self.path = path
    self.glob = glob
    self.name = name
    self.filter = filter
    self.script = script
    self.every = every
    self.inputs = inputs
  }

  /// One line for approvals and the Setup page: "schedule 0 9 * * 1-5", "watcher steps/watch-ci.sh every 2m".
  public var summary: String {
    switch typed {
    case .manual: "manual"
    case .schedule: "schedule \(cron ?? "")"
    case .files: "files \(path ?? "")" + (glob.map { " (\($0))" } ?? "")
    case .event: "event \(name ?? "")"
    case .watcher: "watcher \(script ?? "")" + (every.map { " every \($0)" } ?? "")
    case nil: kind
    }
  }
}

/// An `ask` step's question (spec 2026-10-10-agents-design.md): the run stops and asks the user; the answer is the
/// step's output. Every string is a template; `choices` is a list of templates, or one template that renders to a JSON
/// list of strings.
public struct AutomationAsk: Codable, Equatable, Sendable {
  public enum Choices: Equatable, Sendable {
    case list([String])
    case template(String)
  }

  /// At most this many choices (the card's ⌥1–6).
  public static let maxChoices = 6

  public var question: String
  public var body: String?
  public var choices: Choices?
  /// A typed or spoken answer outside the choices is allowed.
  public var text: Bool?

  public init(question: String, body: String? = nil, choices: Choices? = nil, text: Bool? = nil) {
    self.question = question
    self.body = body
    self.choices = choices
    self.text = text
  }

  public var allowsText: Bool { text ?? false }

  enum CodingKeys: String, CodingKey { case question, body, choices, text }
  static let keys: Set<String> = ["question", "body", "choices", "text"]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    question = try container.decode(String.self, forKey: .question)
    body = try container.decodeIfPresent(String.self, forKey: .body)
    text = try container.decodeIfPresent(Bool.self, forKey: .text)
    if !container.contains(.choices) || (try? container.decodeNil(forKey: .choices)) == true {
      choices = nil
    } else if let list = try? container.decode([String].self, forKey: .choices) {
      choices = .list(list)
    } else {
      choices = .template(try container.decode(String.self, forKey: .choices))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(question, forKey: .question)
    try container.encodeIfPresent(body, forKey: .body)
    switch choices {
    case .list(let list): try container.encode(list, forKey: .choices)
    case .template(let template): try container.encode(template, forKey: .choices)
    case nil: break
    }
    try container.encodeIfPresent(text, forKey: .text)
  }
}

/// One step of the pipeline. Exactly one of `run`, `claude`, `automation` or `ask` says what it does (validation
/// checks).
public struct AutomationStep: Codable, Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    /// A script in the package (`script`) or a command line for zsh (`command`).
    case script(String)
    case command(String)
    /// A prompt file in the package.
    case claude(String)
    /// Another automation's id.
    case automation(String)
    /// A question for the user (agents, spec 2026-10-10-agents-design.md).
    case ask(AutomationAsk)
  }

  public static let defaultTimeout: Double = 300
  /// The script types a `run` path can name.
  public static let scriptExtensions = ["sh", "zsh", "bash", "py", "js", "mjs", "rb"]
  public static let shellExtensions = ["sh", "zsh", "bash"]

  public var id: String
  public var run: String?
  public var claude: String?
  public var automation: String?
  public var ask: AutomationAsk?
  public var cwd: String?
  public var stdin: String?
  public var timeout: Double?
  public var outward: Bool?
  /// `if` in automation.json: a template; the step runs when it renders truthy.
  public var condition: String?
  /// "text" (the default) or "json".
  public var outputs: String?
  public var tools: [String]?
  public var mcp: [String]?
  public var model: String?
  /// Automation steps: the callee's inputs (string values are templates).
  public var inputs: [String: AutomationValue]?

  enum CodingKeys: String, CodingKey {
    case id, run, claude, automation, ask, cwd, stdin, timeout, outward, outputs, tools, mcp, model, inputs
    case condition = "if"
  }

  public init(id: String, run: String? = nil, claude: String? = nil, automation: String? = nil,
              ask: AutomationAsk? = nil, cwd: String? = nil,
              stdin: String? = nil, timeout: Double? = nil, outward: Bool? = nil, condition: String? = nil,
              outputs: String? = nil, tools: [String]? = nil, mcp: [String]? = nil, model: String? = nil,
              inputs: [String: AutomationValue]? = nil) {
    self.id = id
    self.run = run
    self.claude = claude
    self.automation = automation
    self.ask = ask
    self.cwd = cwd
    self.stdin = stdin
    self.timeout = timeout
    self.outward = outward
    self.condition = condition
    self.outputs = outputs
    self.tools = tools
    self.mcp = mcp
    self.model = model
    self.inputs = inputs
  }

  /// What the step does; nil when it names none or more than one of run / claude / automation / ask.
  public var kind: Kind? {
    let given = [run, claude, automation].compactMap { $0 }.count + (ask == nil ? 0 : 1)
    guard given == 1 else { return nil }
    if let run { return Self.scriptPath(run).map(Kind.script) ?? .command(run) }
    if let claude { return .claude(claude) }
    if let ask { return .ask(ask) }
    return automation.map(Kind.automation)
  }

  public var isClaude: Bool { claude != nil }
  public var isAsk: Bool { ask != nil }

  public var isOutward: Bool { outward ?? false }
  public var timeoutSeconds: Double { timeout ?? Self.defaultTimeout }
  public var outputsJSON: Bool { outputs == "json" }

  /// A `run` that names a file in the package: one word, relative (no "/", "~" or "$" first), no template, and either
  /// a "/" in it or a script extension. "./" in front is dropped. Anything else is a command line.
  public static func scriptPath(_ run: String) -> String? {
    var text = run.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.contains("{{"),
          !["/", "~", "$"].contains(where: { text.hasPrefix($0) }) else { return nil }
    if text.hasPrefix("./") { text.removeFirst(2) }
    let pathExtension = (text as NSString).pathExtension.lowercased()
    guard text.contains("/") || scriptExtensions.contains(pathExtension) else { return nil }
    return text
  }
}

/// What the automation may do; approved once by the user (spec "Approvals").
public struct AutomationPermissions: Codable, Equatable, Hashable, Sendable {
  /// Shown at approval; not enforceable inside scripts.
  public var commands: [String]
  /// Claude built-in tool patterns ("Edit", "Bash(git:*)").
  public var tools: [String]
  /// MCP tool names ("mcp__server__tool") or whole servers ("mcp__server").
  public var mcp: [String]
  /// Write access besides the run directory.
  public var folders: [String]
  public var network: Bool

  public init(commands: [String] = [], tools: [String] = [], mcp: [String] = [], folders: [String] = [],
              network: Bool = false) {
    self.commands = commands
    self.tools = tools
    self.mcp = mcp
    self.folders = folders
    self.network = network
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    commands = try container.decodeIfPresent([String].self, forKey: .commands) ?? []
    tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
    mcp = try container.decodeIfPresent([String].self, forKey: .mcp) ?? []
    folders = try container.decodeIfPresent([String].self, forKey: .folders) ?? []
    network = try container.decodeIfPresent(Bool.self, forKey: .network) ?? false
  }
}

/// automation.json (spec "The package format"). `parse(_:)` reads it; `validate(_:)` (AutomationValidation.swift)
/// checks it against its package.
public struct AutomationManifest: Codable, Equatable, Sendable {
  public static let fileName = "automation.json"

  public static let kinds = ["automation", "agent"]

  public var id: String
  /// "automation" (nil, the default) or "agent": an automation whose steps are Claude working with tools, and that
  /// can stop to ask (spec 2026-10-10-agents-design.md). Studio lists agents under Agents.
  public var kind: String?
  public var version: Int
  public var name: String
  public var description: String
  public var tags: [String]
  /// In the order automation.json lists them (the generated form's order).
  public var inputs: [AutomationInput]
  public var triggers: [AutomationTrigger]
  public var steps: [AutomationStep]
  public var permissions: AutomationPermissions

  public init(id: String, kind: String? = nil, version: Int = 1, name: String, description: String = "",
              tags: [String] = [], inputs: [AutomationInput] = [], triggers: [AutomationTrigger] = [],
              steps: [AutomationStep] = [], permissions: AutomationPermissions = AutomationPermissions()) {
    self.id = id
    self.kind = kind
    self.version = version
    self.name = name
    self.description = description
    self.tags = tags
    self.inputs = inputs
    self.triggers = triggers
    self.steps = steps
    self.permissions = permissions
  }

  enum CodingKeys: String, CodingKey {
    case id, kind, version, name, description, tags, inputs, triggers, steps, permissions
  }

  public var isAgent: Bool { kind == "agent" }

  /// The keys automation.json may use, per object; anything else is reported (a typo would otherwise be ignored).
  static let topKeys: Set<String> = ["id", "kind", "version", "name", "description", "tags", "inputs", "triggers", "steps",
                                     "permissions"]
  static let inputKeys: Set<String> = ["type", "required", "default", "description", "options"]
  static let triggerKeys: Set<String> = ["kind", "cron", "path", "glob", "name", "filter", "script", "every", "inputs"]
  static let stepKeys: Set<String> = ["id", "run", "claude", "automation", "ask", "cwd", "stdin", "timeout", "outward", "if",
                                      "outputs", "tools", "mcp", "model", "inputs"]
  static let permissionKeys: Set<String> = ["commands", "tools", "mcp", "folders", "network"]

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    triggers = try container.decodeIfPresent([AutomationTrigger].self, forKey: .triggers) ?? []
    steps = try container.decodeIfPresent([AutomationStep].self, forKey: .steps) ?? []
    permissions = try container.decodeIfPresent(AutomationPermissions.self, forKey: .permissions)
      ?? AutomationPermissions()
    inputs = []
    if container.contains(.inputs) {
      let fields = try container.nestedContainer(keyedBy: AnyKey.self, forKey: .inputs)
      for key in fields.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
        let field = try fields.nestedContainer(keyedBy: InputKeys.self, forKey: key)
        inputs.append(AutomationInput(
          name: key.stringValue,
          type: try field.decodeIfPresent(String.self, forKey: .type) ?? "string",
          required: try field.decodeIfPresent(Bool.self, forKey: .required) ?? false,
          default: try field.decodeIfPresent(AutomationValue.self, forKey: .default),
          description: try field.decodeIfPresent(String.self, forKey: .description),
          options: try field.decodeIfPresent([String].self, forKey: .options)))
      }
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encodeIfPresent(kind, forKey: .kind)
    try container.encode(version, forKey: .version)
    try container.encode(name, forKey: .name)
    try container.encode(description, forKey: .description)
    try container.encode(tags, forKey: .tags)
    var fields = container.nestedContainer(keyedBy: AnyKey.self, forKey: .inputs)
    for input in inputs {
      var field = fields.nestedContainer(keyedBy: InputKeys.self, forKey: AnyKey(input.name))
      try field.encode(input.type, forKey: .type)
      if input.required { try field.encode(true, forKey: .required) }
      try field.encodeIfPresent(input.default, forKey: .default)
      try field.encodeIfPresent(input.description, forKey: .description)
      try field.encodeIfPresent(input.options, forKey: .options)
    }
    try container.encode(triggers, forKey: .triggers)
    try container.encode(steps, forKey: .steps)
    try container.encode(permissions, forKey: .permissions)
  }

  enum InputKeys: String, CodingKey { case type, required, `default`, description, options }

  struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  /// The input by name.
  public func input(_ name: String) -> AutomationInput? { inputs.first { $0.name == name } }

  /// The ids of the automations its steps call.
  public var callees: Set<String> { Set(steps.compactMap(\.automation)) }

  /// Reads automation.json. Bad JSON, a wrong type ("version": "3") and unknown fields come back as problems with
  /// their path; the manifest is nil only when it couldn't be decoded at all.
  public static func parse(_ data: Data) -> (manifest: AutomationManifest?, problems: [AutomationProblem]) {
    guard let tree = AutomationValue.decode(data) else {
      return (nil, [AutomationProblem(fileName, "isn't valid JSON (\(jsonError(data)))")])
    }
    guard tree.object != nil else { return (nil, [AutomationProblem(fileName, "must be a JSON object")]) }
    var problems = unknownFields(tree)
    do {
      var manifest = try JSONDecoder().decode(AutomationManifest.self, from: data)
      let order = JSONKeyOrder.keys(of: "inputs", in: data)
      manifest.inputs.sort { (order.firstIndex(of: $0.name) ?? .max) < (order.firstIndex(of: $1.name) ?? .max) }
      return (manifest, problems)
    } catch let error as DecodingError {
      problems.insert(problem(error), at: 0)
      return (nil, problems)
    } catch {
      return (nil, [AutomationProblem(fileName, error.localizedDescription)])
    }
  }

  /// Foundation's reason a document isn't JSON ("Unexpected character '}' around line 9, column 1.").
  static func jsonError(_ data: Data) -> String {
    do {
      _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      return "not JSON"
    } catch {
      let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
      return reason?.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) ?? "not JSON"
    }
  }

  static func problem(_ error: DecodingError) -> AutomationProblem {
    switch error {
    case .typeMismatch(let type, let context):
      return AutomationProblem(path(context.codingPath), "should be \(typeName(type))")
    case .valueNotFound(let type, let context):
      return AutomationProblem(path(context.codingPath), "should be \(typeName(type)), not null")
    case .keyNotFound(let key, let context):
      return AutomationProblem(path(context.codingPath + [key]), "is required")
    case .dataCorrupted(let context):
      return AutomationProblem(path(context.codingPath), context.debugDescription)
    @unknown default:
      return AutomationProblem(fileName, "\(error)")
    }
  }

  static func typeName(_ type: Any.Type) -> String {
    switch type {
    case is String.Type: "text"
    case is Int.Type: "a whole number"
    case is Double.Type: "a number"
    case is Bool.Type: "true or false"
    case is [String].Type, is [AutomationTrigger].Type, is [AutomationStep].Type: "a list"
    default: "an object"
    }
  }

  /// "steps[2].tools" from a decoder's coding path.
  static func path(_ keys: [CodingKey]) -> String {
    keys.reduce(into: "") { text, key in
      if let index = key.intValue {
        text += "[\(index)]"
      } else {
        text += text.isEmpty ? key.stringValue : ".\(key.stringValue)"
      }
    }
  }

  static func unknownFields(_ tree: AutomationValue) -> [AutomationProblem] {
    guard let top = tree.object else { return [] }
    var problems = unknown(top, known: topKeys, at: "")
    for (name, field) in (top["inputs"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
      problems += unknown(field.object ?? [:], known: inputKeys, at: "inputs.\(name)")
    }
    for (label, known) in [("triggers", triggerKeys), ("steps", stepKeys)] {
      guard case .array(let items) = top[label] else { continue }
      for (index, item) in items.enumerated() {
        problems += unknown(item.object ?? [:], known: known, at: "\(label)[\(index)]")
        if label == "steps", let ask = item.object?["ask"]?.object {
          problems += unknown(ask, known: AutomationAsk.keys, at: "steps[\(index)].ask")
        }
      }
    }
    problems += unknown(top["permissions"]?.object ?? [:], known: permissionKeys, at: "permissions")
    return problems
  }

  static func unknown(_ object: [String: AutomationValue], known: Set<String>, at path: String) -> [AutomationProblem] {
    object.keys.sorted().filter { !known.contains($0) }.map { key in
      let close = known.sorted().first { editDistance($0, key) <= 2 }
      let hint = close.map { " (did you mean `\($0)`?)" } ?? ""
      return AutomationProblem(path.isEmpty ? key : "\(path).\(key)", "isn't a field Glance knows\(hint)")
    }
  }

  static func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    guard !a.isEmpty else { return b.count }
    guard !b.isEmpty else { return a.count }
    var row = Array(0...b.count)
    for i in 1...a.count {
      var diagonal = row[0]
      row[0] = i
      for j in 1...b.count {
        let above = row[j]
        row[j] = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
        diagonal = above
      }
    }
    return row[b.count]
  }
}

/// The order of an object's keys as written (Foundation's decoders forget it): the keys of the top-level member
/// `member`, when it is an object.
enum JSONKeyOrder {
  static func keys(of member: String, in data: Data) -> [String] {
    let bytes = Array(data)
    var stack: [UInt8] = []
    var expectKey = false
    var topKey: String?
    var collecting = false
    var keys: [String] = []
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      switch byte {
      case UInt8(ascii: "\""):
        var end = index + 1
        while end < bytes.count, bytes[end] != UInt8(ascii: "\"") {
          end += bytes[end] == UInt8(ascii: "\\") ? 2 : 1
        }
        guard end < bytes.count else { return keys }
        if expectKey, stack.last == UInt8(ascii: "{"),
           let key = try? JSONDecoder().decode(String.self, from: Data(bytes[index...end])) {
          if stack.count == 1 { topKey = key }
          if stack.count == 2, collecting { keys.append(key) }
          expectKey = false
        }
        index = end
      case UInt8(ascii: "{"), UInt8(ascii: "["):
        stack.append(byte)
        expectKey = byte == UInt8(ascii: "{")
        if stack.count == 2, byte == UInt8(ascii: "{"), stack.first == UInt8(ascii: "{"), topKey == member {
          collecting = true
        }
      case UInt8(ascii: "}"), UInt8(ascii: "]"):
        if !stack.isEmpty { stack.removeLast() }
        if stack.count < 2 { collecting = false }
      case UInt8(ascii: ","):
        expectKey = stack.last == UInt8(ascii: "{")
      default:
        break
      }
      index += 1
    }
    return keys
  }
}
