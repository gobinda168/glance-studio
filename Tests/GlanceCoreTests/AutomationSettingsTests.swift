import Foundation
import Testing
@testable import GlanceCore

private let waterJSON = """
{
  "id": "water", "version": 1, "name": "Water",
  "inputs": {
    "every_minutes": { "type": "number", "default": 60 },
    "speak": { "type": "boolean", "default": true },
    "message": { "type": "string", "default": "Drink water" }
  },
  "triggers": [{ "kind": "manual" }],
  "steps": [{ "id": "a", "run": "echo hi" }]
}
"""

private func water() -> AutomationManifest { AutomationManifest.parse(Data(waterJSON.utf8)).manifest! }

@Test func savedValuesStandInForTheDefaults() {
  var settings = AutomationSettings()
  settings.values["water"] = ["every_minutes": .number(30), "gone": .string("x")]
  let manifest = settings.applied(to: water())
  #expect(manifest.resolveInputs([:]).values["every_minutes"] == .number(30))
  #expect(manifest.resolveInputs([:]).values["message"] == .string("Drink water"))
  #expect(manifest.inputs.map(\.name) == water().inputs.map(\.name))
  #expect(AutomationSettings().applied(to: water()) == water())
}

@Test func savingTheFormKeepsTypedValuesForTheFieldsEdited() {
  var settings = AutomationSettings()
  settings.values["water"] = ["message": .string("Hydrate")]
  let fields = AutomationFormModel.fields(water())
  let saved = settings.saving(water(), fields: fields, edited: ["every_minutes": "15", "speak": "false"])
  #expect(saved?.values["water"] == ["every_minutes": .number(15), "speak": .bool(false), "message": .string("Hydrate")])
  // A field emptied goes back to its default.
  let cleared = settings.saving(water(), fields: fields, edited: ["message": " "])
  #expect(cleared?.values["water"] == nil)
}

@Test func savingAWrongValueSavesNothing() {
  let fields = AutomationFormModel.fields(water())
  #expect(AutomationSettings().saving(water(), fields: fields, edited: ["every_minutes": "soon"]) == nil)
}

@Test func settingsRoundTripAndABrokenFileIsNil() {
  var settings = AutomationSettings()
  settings.values["water"] = ["every_minutes": .number(30)]
  #expect(AutomationSettings.decode(settings.encoded()) == settings)
  #expect(AutomationSettings.decode(Data("nope".utf8)) == nil)
}
