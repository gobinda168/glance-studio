import Foundation

/// One `{{ }}` reference (spec "Templating").
public enum AutomationReference: Equatable, Hashable, Sendable {
  /// `inputs.<name>`
  case input(String)
  /// `trigger` or `trigger.<dot.path>`: the event payload, the changed paths, the watcher's line.
  case trigger([String])
  /// `steps.<id>.text`
  case stepText(String)
  /// `steps.<id>.json` or `steps.<id>.json.<dot.path>`
  case stepJSON(String, [String])
  /// `run.dir`
  case runDir
  /// `automation.dir`
  case automationDir

  /// Reads "inputs.repo", "steps.log.json.items.0"; nil when it isn't one of the forms above.
  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard !parts.contains(where: \.isEmpty) else { return nil }
    switch parts.first {
    case "inputs" where parts.count == 2: self = .input(parts[1])
    case "trigger": self = .trigger(Array(parts.dropFirst()))
    case "steps" where parts.count == 3 && parts[2] == "text": self = .stepText(parts[1])
    case "steps" where parts.count >= 3 && parts[2] == "json": self = .stepJSON(parts[1], Array(parts.dropFirst(3)))
    case "run" where parts == ["run", "dir"]: self = .runDir
    case "automation" where parts == ["automation", "dir"]: self = .automationDir
    default: return nil
    }
  }

  /// Back to its written form: "steps.log.json.items.0".
  public var text: String {
    switch self {
    case .input(let name): "inputs.\(name)"
    case .trigger(let path): (["trigger"] + path).joined(separator: ".")
    case .stepText(let id): "steps.\(id).text"
    case .stepJSON(let id, let path): (["steps", id, "json"] + path).joined(separator: ".")
    case .runDir: "run.dir"
    case .automationDir: "automation.dir"
    }
  }

  /// The step it reads, if any.
  public var step: String? {
    switch self {
    case .stepText(let id), .stepJSON(let id, _): id
    default: nil
    }
  }
}

/// Why a template didn't render; `message` is the plain words the run log and `check` show.
public enum AutomationTemplateError: Error, Equatable, Sendable {
  case unclosed
  case unknownReference(String)
  case missingInput(String)
  case missingTrigger(String)
  case missingStep(String)
  case notJSON(String)
  case missingJSONPath(step: String, path: String)
  /// A rendered value that doesn't fit where it goes (an ask step's choices).
  case invalid(String)

  public var message: String {
    switch self {
    case .unclosed:
      "a `{{` has no closing `}}`"
    case .unknownReference(let text):
      "`{{\(text)}}` isn't a reference Glance knows; use inputs.<name>, trigger.<field>, steps.<id>.text, "
        + "steps.<id>.json.<path>, run.dir or automation.dir"
    case .missingInput(let name):
      "there's no input `\(name)`"
    case .missingTrigger(let path):
      path.isEmpty ? "this run has no trigger" : "the trigger has no `\(path)`"
    case .missingStep(let id):
      "step `\(id)` hasn't run before this one"
    case .notJSON(let id):
      "step `\(id)` didn't output JSON"
    case .missingJSONPath(let step, let path):
      "step `\(step)`'s JSON has no `\(path)`"
    case .invalid(let message):
      message
    }
  }
}

/// What a finished step left for the steps after it.
public struct AutomationStepOutput: Codable, Equatable, Sendable {
  public var text: String
  public var json: AutomationValue?

  public init(text: String, json: AutomationValue? = nil) {
    self.text = text
    self.json = json
  }
}

/// Everything a template can read during a run.
public struct AutomationTemplateContext: Equatable, Sendable {
  public var inputs: [String: AutomationValue]
  /// nil for a manual run.
  public var trigger: AutomationValue?
  /// Step id → its output, for the steps that already ran.
  public var steps: [String: AutomationStepOutput]
  public var runDir: String
  public var automationDir: String
  /// `glance automation check`: what only a real run knows (a step's JSON, the trigger's payload) renders as a
  /// placeholder such as "<steps.log.json.url>" or "<trigger.title>" instead of failing.
  public var dryRun: Bool

  public init(inputs: [String: AutomationValue], trigger: AutomationValue? = nil,
              steps: [String: AutomationStepOutput] = [:], runDir: String, automationDir: String,
              dryRun: Bool = false) {
    self.inputs = inputs
    self.trigger = trigger
    self.steps = steps
    self.runDir = runDir
    self.automationDir = automationDir
    self.dryRun = dryRun
  }
}

/// `{{ }}` templates in steps (`run` command lines, `cwd`, `stdin`, `if`, an automation step's `inputs`) and in
/// prompt files.
public enum AutomationTemplate {
  /// `.shell` puts each value in single quotes: for `run` command lines, so a value (a PR title from a watcher)
  /// can't add commands. Everything else renders plain.
  public enum Quoting: Sendable { case none, shell }

  public enum Segment: Equatable, Sendable {
    case text(String)
    case reference(AutomationReference)
  }

  /// Splits a template into text and references. `{{ inputs.x }}` may have spaces inside the braces.
  public static func parse(_ template: String) throws(AutomationTemplateError) -> [Segment] {
    var segments: [Segment] = []
    var rest = Substring(template)
    while let open = rest.range(of: "{{") {
      if open.lowerBound > rest.startIndex { segments.append(.text(String(rest[..<open.lowerBound]))) }
      guard let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) else {
        throw .unclosed
      }
      let inner = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
      guard let reference = AutomationReference(inner) else { throw .unknownReference(inner) }
      segments.append(.reference(reference))
      rest = rest[close.upperBound...]
    }
    if !rest.isEmpty { segments.append(.text(String(rest))) }
    return segments
  }

  /// The references a template makes, in order.
  public static func references(in template: String) throws(AutomationTemplateError) -> [AutomationReference] {
    try parse(template).compactMap { segment in
      if case .reference(let reference) = segment { return reference }
      return nil
    }
  }

  public static func render(_ template: String, _ context: AutomationTemplateContext,
                            quoting: Quoting = .none) throws(AutomationTemplateError) -> String {
    var output = ""
    for segment in try parse(template) {
      switch segment {
      case .text(let text):
        output += text
      case .reference(let reference):
        let value = try text(of: reference, in: context)
        output += quoting == .shell ? shellQuoted(value) : value
      }
    }
    return output
  }

  /// An automation step's inputs: every string inside is a template; other values pass through.
  public static func render(_ value: AutomationValue,
                            _ context: AutomationTemplateContext) throws(AutomationTemplateError) -> AutomationValue {
    switch value {
    case .string(let template):
      return .string(try render(template, context))
    case .array(let items):
      var rendered: [AutomationValue] = []
      for item in items { rendered.append(try render(item, context)) }
      return .array(rendered)
    case .object(let members):
      var rendered: [String: AutomationValue] = [:]
      for (key, member) in members { rendered[key] = try render(member, context) }
      return .object(rendered)
    default:
      return value
    }
  }

  public static func text(of reference: AutomationReference,
                          in context: AutomationTemplateContext) throws(AutomationTemplateError) -> String {
    switch reference {
    case .input(let name):
      guard let value = context.inputs[name] else { throw .missingInput(name) }
      return value.text
    case .trigger(let path):
      if context.dryRun, context.trigger == nil { return "<\(reference.text)>" }
      guard let value = context.trigger?.value(at: path) else {
        throw .missingTrigger(path.joined(separator: "."))
      }
      return value.text
    case .stepText(let id):
      guard let output = context.steps[id] else { throw .missingStep(id) }
      return output.text
    case .stepJSON(let id, let path):
      guard let output = context.steps[id] else { throw .missingStep(id) }
      guard let json = output.json else {
        if context.dryRun { return "<\(reference.text)>" }
        throw .notJSON(id)
      }
      guard let value = json.value(at: path) else {
        throw .missingJSONPath(step: id, path: path.joined(separator: "."))
      }
      return value.text
    case .runDir:
      return context.runDir
    case .automationDir:
      return context.automationDir
    }
  }

  /// An `if` runs its step unless it renders empty, "false", "0" or "null" (any case, spaces ignored).
  public static func isTruthy(_ text: String) -> Bool {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !["", "false", "0", "null"].contains(value)
  }

  /// 'it'\''s' — safe as one zsh word.
  public static func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }
}
