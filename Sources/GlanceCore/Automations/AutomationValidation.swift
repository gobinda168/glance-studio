import Foundation

/// What validation needs to know about the package and the library; the caller reads the disk.
public struct AutomationValidationContext: Equatable, Sendable {
  /// The package's folder name; nil skips the id = folder check.
  public var folderName: String?
  /// Every file in the package, relative to it ("steps/fetch.sh").
  public var files: Set<String>
  /// Prompt files' contents by path, for their template checks. A prompt missing here is only checked to exist.
  public var prompts: [String: String]
  /// The other automations in the library: id → the ids their steps call (for missing callees and loops).
  public var automations: [String: Set<String>]

  public init(folderName: String?, files: Set<String>, prompts: [String: String] = [:],
              automations: [String: Set<String>] = [:]) {
    self.folderName = folderName
    self.files = files
    self.prompts = prompts
    self.automations = automations
  }
}

extension AutomationManifest {
  /// Every problem with the manifest in its package (spec "Validation"): id and folder, inputs, triggers (cron syntax,
  /// event names and filters, watcher scripts and intervals), steps (ids, one kind each, files that exist, template
  /// references, Claude-only fields), tools and MCP inside the permissions, and nested automations that exist and
  /// don't call back into this one. Empty means valid.
  public func validate(_ context: AutomationValidationContext) -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    problems += validateHeader(context)
    problems += validateInputs()
    problems += validateTriggers(context)
    problems += validateSteps(context)
    problems += permissions.problems(in: self)
    for (index, server) in permissions.mcp.enumerated() where !server.hasPrefix("mcp__") {
      problems.append(AutomationProblem("permissions.mcp[\(index)]", "`\(server)` should start with mcp__"))
    }
    return problems
  }

  /// `parse` then `validate`: what `glance automation check`, the library and `automation_save` use.
  public static func check(_ data: Data, _ context: AutomationValidationContext)
    -> (manifest: AutomationManifest?, problems: [AutomationProblem]) {
    let parsed = parse(data)
    guard let manifest = parsed.manifest else { return parsed }
    return (manifest, parsed.problems + manifest.validate(context))
  }

  static func isID(_ text: String) -> Bool {
    (1...48).contains(text.unicodeScalars.count) && text.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
    }
  }

  /// Step and input names: letters, digits, "_" and "-" (no dots, which templates use as separators).
  static func isName(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
    }
  }

  /// A script path that starts at the root or has a `..` segment: it names something outside the package.
  static func leavesPackage(_ file: String) -> Bool {
    file.hasPrefix("/") || file.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }

  func validateHeader(_ context: AutomationValidationContext) -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    if !Self.isID(id) {
      problems.append(AutomationProblem("id", "`\(id)` must be 1–48 lowercase letters, digits or dashes"))
    } else if let folder = context.folderName, folder != id {
      problems.append(AutomationProblem("id", "`\(id)` must match its folder `\(folder)`"))
    }
    if version < 1 { problems.append(AutomationProblem("version", "must be 1 or more")) }
    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append(AutomationProblem("name", "can't be empty"))
    }
    if let kind, !Self.kinds.contains(kind) {
      problems.append(AutomationProblem("kind", "`\(kind)` isn't a kind; use automation or agent"))
    }
    if isAgent, !steps.isEmpty, !steps.contains(where: \.isClaude) {
      problems.append(AutomationProblem("steps", "an agent needs at least one claude step"))
    }
    return problems
  }

  func validateInputs() -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    for input in inputs {
      let path = "inputs.\(input.name)"
      if !Self.isName(input.name) {
        problems.append(AutomationProblem(path, "names are letters, digits, _ and -"))
      }
      guard let kind = input.kind else {
        let kinds = AutomationInput.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        problems.append(AutomationProblem("\(path).type", "`\(input.type)` isn't a type; use \(kinds)"))
        continue
      }
      if kind == .enum, (input.options ?? []).isEmpty {
        problems.append(AutomationProblem("\(path).options", "an enum needs its options"))
      } else if kind != .enum, input.options != nil {
        problems.append(AutomationProblem("\(path).options", "only enum inputs have options"))
      }
      if let value = input.default, value != .null, input.coerced(value) != value {
        problems.append(AutomationProblem("\(path).default", input.mismatch(value)))
      }
    }
    return problems
  }

  func validateTriggers(_ context: AutomationValidationContext) -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    for (index, trigger) in triggers.enumerated() {
      let path = "triggers[\(index)]"
      for name in (trigger.inputs ?? [:]).keys.sorted() where input(name) == nil {
        problems.append(AutomationProblem("\(path).inputs.\(name)", "there's no input `\(name)`"))
      }
      switch trigger.typed {
      case nil:
        let kinds = AutomationTrigger.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        problems.append(AutomationProblem("\(path).kind", "`\(trigger.kind)` isn't a trigger; use \(kinds)"))
      case .manual:
        break
      case .schedule:
        guard let cron = trigger.cron else {
          problems.append(AutomationProblem("\(path).cron", "a schedule needs a cron line"))
          break
        }
        do throws(CronError) {
          _ = try CronSchedule(parsing: cron)
        } catch {
          problems.append(AutomationProblem("\(path).cron", error.message))
        }
      case .files:
        if (trigger.path ?? "").isEmpty {
          problems.append(AutomationProblem("\(path).path", "a files trigger needs a path to watch"))
        }
      case .event:
        guard let name = trigger.name else {
          problems.append(AutomationProblem("\(path).name", "an event trigger needs an event name"))
          break
        }
        guard let event = AutomationEvents.named(name) else {
          let names = AutomationEvents.all.map(\.name).joined(separator: ", ")
          problems.append(AutomationProblem("\(path).name", "`\(name)` isn't a Glance event; use \(names)"))
          break
        }
        for key in (trigger.filter ?? [:]).keys.sorted() where event.field(key) == nil {
          problems.append(AutomationProblem("\(path).filter.\(key)", "`\(name)` has no field `\(key)`"))
        }
      case .watcher:
        if let script = trigger.script {
          if Self.leavesPackage(script) {
            problems.append(AutomationProblem("\(path).script", "must stay inside the package"))
          } else if !context.files.contains(script) {
            problems.append(AutomationProblem("\(path).script", "`\(script)` isn't in the package"))
          }
        } else {
          problems.append(AutomationProblem("\(path).script", "a watcher needs a script"))
        }
        if let every = trigger.every {
          if let seconds = AutomationInterval.parse(every) {
            if seconds < AutomationInterval.minimum {
              problems.append(AutomationProblem("\(path).every", "`\(every)` is too often; at least 10s"))
            }
          } else {
            problems.append(AutomationProblem("\(path).every", "`\(every)` isn't an interval; use 30s, 2m, 1h or 1d"))
          }
        }
      }
    }
    return problems
  }

  func validateSteps(_ context: AutomationValidationContext) -> [AutomationProblem] {
    guard !steps.isEmpty else { return [AutomationProblem("steps", "needs at least one step")] }
    var problems: [AutomationProblem] = []
    var earlier: [String: AutomationStep] = [:]
    var firstIndex: [String: Int] = [:]
    for (index, step) in steps.enumerated() {
      let path = "steps[\(index)]"
      var templates: [(String, String)] = []
      if !Self.isName(step.id) {
        problems.append(AutomationProblem("\(path).id", "`\(step.id)` must be letters, digits, _ or - (no dots)"))
      } else if let first = firstIndex[step.id] {
        problems.append(AutomationProblem("\(path).id", "`\(step.id)` is used by steps[\(first)] too"))
      }
      problems += validateKind(step, at: path, context)
      if step.claude == nil {
        for (field, given) in [("tools", step.tools != nil), ("mcp", step.mcp != nil), ("model", step.model != nil)]
        where given {
          problems.append(AutomationProblem("\(path).\(field)", "only Claude steps take \(field)"))
        }
      }
      if step.automation == nil, step.inputs != nil {
        problems.append(AutomationProblem("\(path).inputs", "only automation steps take inputs"))
      }
      if let ask = step.ask {
        problems += validateAsk(step, ask, at: path)
        templates += askTemplates(ask, at: "\(path).ask")
      }
      if let outputs = step.outputs, !["text", "json"].contains(outputs) {
        problems.append(AutomationProblem("\(path).outputs", "`\(outputs)` isn't text or json"))
      }
      if let timeout = step.timeout, timeout <= 0 {
        problems.append(AutomationProblem("\(path).timeout", "must be more than 0 seconds"))
      }
      if case .command(let line) = step.kind { templates.append(("\(path).run", line)) }
      if let cwd = step.cwd { templates.append(("\(path).cwd", cwd)) }
      if let stdin = step.stdin { templates.append(("\(path).stdin", stdin)) }
      if let condition = step.condition { templates.append(("\(path).if", condition)) }
      for (key, value) in (step.inputs ?? [:]).sorted(by: { $0.key < $1.key }) {
        templates += Self.strings(in: value).map { ("\(path).inputs.\(key)", $0) }
      }
      if case .claude(let prompt) = step.kind, let text = context.prompts[prompt] {
        templates.append((prompt, text))
      }
      for (location, template) in templates {
        problems += checkTemplate(template, at: location, earlier: earlier, current: step.id)
      }
      if firstIndex[step.id] == nil { firstIndex[step.id] = index }
      earlier[step.id] = step
    }
    return problems
  }

  func validateKind(_ step: AutomationStep, at path: String,
                    _ context: AutomationValidationContext) -> [AutomationProblem] {
    let given = [("run", step.run), ("claude", step.claude), ("automation", step.automation),
                 ("ask", step.ask.map { _ in "" })]
      .compactMap { name, value in value.map { _ in name } }
    guard given.count == 1, let kind = step.kind else {
      if given.isEmpty { return [AutomationProblem(path, "needs one of run, claude, automation or ask")] }
      return [AutomationProblem(path, "has \(given.joined(separator: " and ")); a step does one thing")]
    }
    switch kind {
    case .command(let line) where line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
      return [AutomationProblem("\(path).run", "can't be empty")]
    case .script(let file) where Self.leavesPackage(file):
      return [AutomationProblem("\(path).run", "must stay inside the package")]
    case .script(let file) where !context.files.contains(file):
      return [AutomationProblem("\(path).run", "`\(file)` isn't in the package")]
    case .claude(let file) where !context.files.contains(file):
      return [AutomationProblem("\(path).claude", "`\(file)` isn't in the package")]
    case .automation(let callee):
      if callee == id { return [AutomationProblem("\(path).automation", "an automation can't run itself")] }
      guard context.automations[callee] != nil else {
        return [AutomationProblem("\(path).automation", "there's no automation `\(callee)` in the library")]
      }
      if let loop = loop(from: callee, context.automations) {
        return [AutomationProblem("\(path).automation", "runs in a loop: \(loop.joined(separator: " → "))")]
      }
      return []
    default:
      return []
    }
  }

  /// An ask step: a question, 0–6 non-empty choices (at least one unless `text`), and none of the fields that only
  /// steps which run something take.
  func validateAsk(_ step: AutomationStep, _ ask: AutomationAsk, at path: String) -> [AutomationProblem] {
    var problems: [AutomationProblem] = []
    if ask.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      problems.append(AutomationProblem("\(path).ask.question", "can't be empty"))
    }
    switch ask.choices {
    case .list(let choices):
      if choices.count > AutomationAsk.maxChoices {
        problems.append(AutomationProblem("\(path).ask.choices", "at most \(AutomationAsk.maxChoices) choices"))
      }
      if choices.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
        problems.append(AutomationProblem("\(path).ask.choices", "a choice can't be empty"))
      }
      if choices.isEmpty, !ask.allowsText {
        problems.append(AutomationProblem("\(path).ask", "needs choices, or \"text\": true for a typed answer"))
      }
    case .template(let template):
      if template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        problems.append(AutomationProblem("\(path).ask.choices", "can't be empty"))
      }
    case nil:
      if !ask.allowsText {
        problems.append(AutomationProblem("\(path).ask", "needs choices, or \"text\": true for a typed answer"))
      }
    }
    let fields: [(String, Bool)] = [("cwd", step.cwd != nil), ("stdin", step.stdin != nil),
                                    ("timeout", step.timeout != nil), ("outward", step.outward != nil),
                                    ("outputs", step.outputs != nil)]
    for (field, given) in fields where given {
      problems.append(AutomationProblem("\(path).\(field)", "ask steps don't take \(field)"))
    }
    return problems
  }

  /// An ask step's templates: its question, body and choices.
  func askTemplates(_ ask: AutomationAsk, at path: String) -> [(String, String)] {
    var templates = [("\(path).question", ask.question)]
    if let body = ask.body { templates.append(("\(path).body", body)) }
    switch ask.choices {
    case .list(let choices): templates += choices.map { ("\(path).choices", $0) }
    case .template(let template): templates.append(("\(path).choices", template))
    case nil: break
    }
    return templates
  }

  /// The call chain from this automation back to itself through `callee`, if there is one.
  func loop(from callee: String, _ automations: [String: Set<String>]) -> [String]? {
    var queue: [[String]] = [[id, callee]]
    var seen: Set<String> = [callee]
    while !queue.isEmpty {
      let chain = queue.removeFirst()
      for next in (automations[chain.last!] ?? []).sorted() {
        if next == id { return chain + [id] }
        if seen.insert(next).inserted { queue.append(chain + [next]) }
      }
    }
    return nil
  }

  func checkTemplate(_ template: String, at location: String, earlier: [String: AutomationStep],
                     current: String) -> [AutomationProblem] {
    let references: [AutomationReference]
    do throws(AutomationTemplateError) {
      references = try AutomationTemplate.references(in: template)
    } catch {
      return [AutomationProblem(location, error.message)]
    }
    var problems: [AutomationProblem] = []
    for reference in references {
      switch reference {
      case .input(let name) where input(name) == nil:
        problems.append(AutomationProblem(location, "`{{\(reference.text)}}`: there's no input `\(name)`"))
      case .stepText(let id), .stepJSON(let id, _):
        guard let step = earlier[id] else {
          let reason = id == current ? "is this step" : steps.contains { $0.id == id }
            ? "runs after this one" : "doesn't exist"
          problems.append(AutomationProblem(location, "`{{\(reference.text)}}`: step `\(id)` \(reason)"))
          continue
        }
        if case .stepJSON = reference, !step.outputsJSON, step.automation == nil, step.ask == nil {
          let message = "`{{\(reference.text)}}`: step `\(id)` outputs text; give it \"outputs\": \"json\""
          problems.append(AutomationProblem(location, message))
        }
      default:
        break
      }
    }
    return problems
  }

  static func strings(in value: AutomationValue) -> [String] {
    switch value {
    case .string(let text): [text]
    case .array(let items): items.flatMap(strings)
    case .object(let members): members.keys.sorted().flatMap { strings(in: members[$0]!) }
    default: []
    }
  }
}
