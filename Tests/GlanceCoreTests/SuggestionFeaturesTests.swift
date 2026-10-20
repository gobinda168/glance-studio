import Foundation
import Testing
@testable import GlanceCore

@Test func everythingStartsOn() {
  let settings = SuggestionSettings()
  #expect(SuggestionFeature.allCases.allSatisfy(settings.isOn))
  #expect(settings.recordHistory)
  #expect(settings.wireFeatures == ["tab", "ghost", "next", "up", "search", "marks", "fixes", "claude"])
}

@Test func switchingOffAndOnAgain() {
  var settings = SuggestionSettings()
  settings.set(.ghost, false)
  settings.set(.claude, false)
  #expect(!settings.isOn(.ghost) && settings.isOn(.tab))
  #expect(settings.wireFeatures == ["tab", "next", "up", "search", "marks", "fixes"])
  settings.set(.ghost, true)
  #expect(settings.isOn(.ghost))
}

@Test func storedSettingsKeepWhatWasOffAndANewFeatureStartsOn() throws {
  var settings = SuggestionSettings()
  settings.set(.marks, false)
  settings.recordHistory = false
  let data = try JSONEncoder().encode(settings)
  let back = try JSONDecoder().decode(SuggestionSettings.self, from: data)
  #expect(back == settings)
  // Saved by a build that knew another, later removed, feature: still decodes.
  let older = try JSONDecoder().decode(SuggestionSettings.self, from: Data(#"{"off":["marks","gone"],"recordHistory":true}"#.utf8))
  #expect(!older.isOn(.marks) && older.isOn(.tab))
}
