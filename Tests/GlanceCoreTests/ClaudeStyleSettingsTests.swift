import Testing
@testable import GlanceCore

@Test func summaryModeFallsBackToManual() {
  #expect(SummaryMode(stored: nil) == .manual)
  #expect(SummaryMode(stored: "nonsense") == .manual)
  #expect(SummaryMode(stored: "always") == .always)
  #expect(SummaryMode.allCases.map(\.name) == ["Manual", "Once per session", "Always"])
}

@Test func responseStyleFallsBackToClaudeDefault() {
  #expect(ResponseStyle(stored: nil) == .claudeDefault)
  #expect(ResponseStyle(stored: "humanize") == .humanize)
  #expect(ResponseStyle.allCases.map(\.name) == ["Claude Default", "Glance Humanize"])
}
