import Foundation

/// One field of the form Studio makes when a package has no ui/ (spec 2026-10-09-automations-design.md, "The UI":
/// "AutomationForm generated from inputs"): its label, its control, and what it starts with.
public struct AutomationFormField: Equatable, Identifiable, Sendable {
  public enum Control: Equatable, Sendable {
    /// One line of text (string inputs, and types Glance doesn't know).
    case line
    /// A file or folder, with Choose….
    case path
    /// Several lines (text inputs).
    case multiline
    case number
    case toggle
    /// An enum input's options.
    case choice([String])
  }

  public var name: String
  public var label: String
  public var control: Control
  public var required: Bool
  /// The input's description, shown under the label.
  public var help: String?
  /// What the field holds before the user types: the default as text ("true"/"false" for a toggle).
  public var initial: String

  public var id: String { name }

  public init(name: String, label: String, control: Control, required: Bool, help: String?, initial: String) {
    self.name = name
    self.label = label
    self.control = control
    self.required = required
    self.help = help
    self.initial = initial
  }
}

/// The generated form: a field per input, the inputs a Run sends, and what's wrong under each field.
public enum AutomationFormModel {
  public static func fields(_ manifest: AutomationManifest) -> [AutomationFormField] {
    manifest.inputs.map { input in
      let control: AutomationFormField.Control
      switch input.kind {
      case .string, nil: control = .line
      case .path: control = .path
      case .text: control = .multiline
      case .number: control = .number
      case .boolean: control = .toggle
      case .enum: control = .choice(input.options ?? [])
      }
      let initial = control == .toggle
        ? (input.default == .bool(true) ? "true" : "false")
        : (input.default.map(\.text) ?? "")
      let help = input.description?.trimmingCharacters(in: .whitespacesAndNewlines)
      return AutomationFormField(name: input.name, label: label(input.name), control: control,
                                 required: input.required, help: help?.isEmpty == false ? help : nil,
                                 initial: initial)
    }
  }

  /// An input's name as a label: "repo_path" → "Repo path", "prNumber" → "Pr number".
  public static func label(_ name: String) -> String {
    var spaced = ""
    var previous: Character?
    for character in name {
      if character == "_" || character == "-" {
        spaced.append(" ")
      } else {
        if character.isUppercase, let previous, previous.isLowercase { spaced.append(" ") }
        spaced.append(character)
      }
      previous = character
    }
    let words = spaced.split(separator: " ").joined(separator: " ").lowercased()
    return words.prefix(1).uppercased() + words.dropFirst()
  }

  /// The run's inputs from the form: toggles as true/false, other fields as typed (the engine reads "412" as a number
  /// for a number input). A field left empty is left out, so its default (or "Required.") applies. One-line fields
  /// are trimmed; multi-line text is sent as it is.
  public static func inputs(_ fields: [AutomationFormField], values: [String: String]) -> [String: AutomationValue] {
    var inputs: [String: AutomationValue] = [:]
    for field in fields {
      let value = values[field.name] ?? field.initial
      if field.control == .toggle {
        inputs[field.name] = .bool(value == "true")
        continue
      }
      let blank = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      guard !blank else { continue }
      inputs[field.name] = .string(field.control == .multiline ? value
                                     : value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return inputs
  }

  /// What's wrong per field, from the same check a run makes (`resolveInputs`), as a sentence under the field.
  public static func errors(_ manifest: AutomationManifest, inputs: [String: AutomationValue]) -> [String: String] {
    var errors: [String: String] = [:]
    for problem in manifest.resolveInputs(inputs).problems where problem.path.hasPrefix("inputs.") {
      let name = String(problem.path.dropFirst("inputs.".count))
      if errors[name] == nil { errors[name] = sentence(problem.message) }
    }
    return errors
  }

  /// "is required" → "Required."; "`12a` isn't a number" → "`12a` isn't a number.".
  static func sentence(_ message: String) -> String {
    if message == "is required" { return "Required." }
    let capital = message.prefix(1).uppercased() + message.dropFirst()
    return capital.hasSuffix(".") ? capital : capital + "."
  }
}
