import Foundation

/// What the user saved in an automation's form (settings.json in the library, by automation id). Saved values stand
/// in for the inputs' defaults everywhere: the form, runs from triggers, and a watcher's `GLANCE_INPUTS`.
public struct AutomationSettings: Codable, Equatable, Sendable {
  public static let fileName = "settings.json"

  public var values: [String: [String: AutomationValue]] = [:]

  public init() {}

  public static func decode(_ data: Data) -> AutomationSettings? {
    try? JSONDecoder().decode(AutomationSettings.self, from: data)
  }

  /// Pretty, sorted keys: a stable file.
  public func encoded() -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(self)) ?? Data("{}".utf8)
  }

  /// The manifest with the saved values as its inputs' defaults. A saved value for an input that's gone, or that no
  /// longer fits its type, is ignored.
  public func applied(to manifest: AutomationManifest) -> AutomationManifest {
    guard let saved = values[manifest.id], !saved.isEmpty else { return manifest }
    var manifest = manifest
    for index in manifest.inputs.indices {
      if let value = saved[manifest.inputs[index].name], let typed = manifest.inputs[index].coerced(value) {
        manifest.inputs[index].default = typed
      }
    }
    return manifest
  }

  /// The settings after the form's Save: each edited field's typed value, or its saved value dropped when the field
  /// was emptied (its default applies again). Nil when an edited field is wrong: the form shows why under it.
  public func saving(_ manifest: AutomationManifest, fields: [AutomationFormField], edited: [String: String])
    -> AutomationSettings? {
    let typed = AutomationFormModel.inputs(fields.filter { edited[$0.name] != nil }, values: edited)
    guard AutomationFormModel.errors(manifest, inputs: typed).keys.allSatisfy({ edited[$0] == nil }) else { return nil }
    var saved = values[manifest.id] ?? [:]
    for name in edited.keys {
      saved[name] = typed[name].flatMap { value in manifest.inputs.first { $0.name == name }?.coerced(value) }
    }
    var settings = self
    settings.values[manifest.id] = saved.isEmpty ? nil : saved
    return settings
  }
}
