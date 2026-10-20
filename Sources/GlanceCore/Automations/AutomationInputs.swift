import Foundation

extension AutomationInput {
  /// The value as this input's type, or nil when it can't be one. Forms and `--inputs` send text, so "412" is a number
  /// for a number input and "true" a boolean; a number is text for a string input.
  public func coerced(_ value: AutomationValue) -> AutomationValue? {
    switch (kind, value) {
    case (.string, .string), (.path, .string), (.text, .string):
      return value
    case (.string, .number), (.string, .bool), (.path, .number), (.text, .number), (.text, .bool):
      return .string(value.text)
    case (.number, .number):
      return value
    case (.number, .string(let text)):
      return Double(text.trimmingCharacters(in: .whitespaces)).map(AutomationValue.number)
    case (.boolean, .bool):
      return value
    case (.boolean, .string(let text)):
      switch text.lowercased() {
      case "true": return .bool(true)
      case "false": return .bool(false)
      default: return nil
      }
    case (.enum, .string), (.enum, .number):
      return (options ?? []).contains(value.text) ? .string(value.text) : nil
    default:
      return nil
    }
  }

  /// A stand-in value of this input's type, for `glance automation check` when nothing was given.
  public var sample: AutomationValue {
    switch kind {
    case .number: .number(1)
    case .boolean: .bool(false)
    case .enum: .string(options?.first ?? "")
    case .path: .string("/tmp/glance-sample")
    case .string, .text, nil: .string("<\(name)>")
    }
  }

  /// What a wrong value gets told: "isn't a number", "isn't one of a, b".
  func mismatch(_ value: AutomationValue) -> String {
    switch kind {
    case .number: "`\(value.text)` isn't a number"
    case .boolean: "`\(value.text)` isn't true or false"
    case .enum: "`\(value.text)` isn't one of \((options ?? []).joined(separator: ", "))"
    default: "`\(value.text)` isn't text"
    }
  }
}

extension AutomationManifest {
  /// The inputs a run uses: given values (as their types) over defaults; an optional input with neither is null
  /// (it renders as nothing). Problems: an unknown name, a wrong type, a required input with no value.
  public func resolveInputs(_ given: [String: AutomationValue])
    -> (values: [String: AutomationValue], problems: [AutomationProblem]) {
    resolve(given, samples: false)
  }

  /// `glance automation check`'s inputs: like `resolveInputs`, but a required input with no value gets its sample.
  public func sampleInputs(_ given: [String: AutomationValue])
    -> (values: [String: AutomationValue], problems: [AutomationProblem]) {
    resolve(given, samples: true)
  }

  func resolve(_ given: [String: AutomationValue], samples: Bool)
    -> (values: [String: AutomationValue], problems: [AutomationProblem]) {
    var values: [String: AutomationValue] = [:]
    var problems: [AutomationProblem] = []
    for name in given.keys.sorted() where input(name) == nil {
      problems.append(AutomationProblem("inputs.\(name)", "there's no input `\(name)`"))
    }
    for input in inputs {
      if let value = given[input.name], value != .null {
        if let typed = input.coerced(value) {
          values[input.name] = typed
        } else {
          problems.append(AutomationProblem("inputs.\(input.name)", input.mismatch(value)))
        }
      } else if let value = input.default {
        values[input.name] = value
      } else if input.required {
        if samples {
          values[input.name] = input.sample
        } else {
          problems.append(AutomationProblem("inputs.\(input.name)", "is required"))
        }
      } else {
        values[input.name] = .null
      }
    }
    return (values, problems)
  }
}
