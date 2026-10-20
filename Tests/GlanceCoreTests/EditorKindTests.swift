import Testing
@testable import GlanceCore

@Test func razorCodeIsTheDefault() {
  #expect(EditorKind.defaultKind == .razor)
  #expect(EditorKind(stored: nil) == .razor)
  #expect(EditorKind(stored: "vscode") == .razor)
  #expect(EditorKind(stored: "studio") == .studio)
}

@Test func eachEditorHasItsNameIconAndSwap() {
  #expect(EditorKind.razor.name == "Razor Code")
  #expect(EditorKind.studio.name == "GS Code")
  #expect(EditorKind.razor.symbol == "bolt.fill")
  #expect(EditorKind.studio.symbol == "g.square.fill")
  #expect(EditorKind.razor.other == .studio && EditorKind.studio.other == .razor)
  #expect(EditorKind.razor.swapTitle == "Open in GS Code")
  #expect(EditorKind.studio.swapTitle == "Open in Razor Code")
}

@Test func linksGoToAnOpenTabBeforeOpeningANewOne() {
  #expect(EditorKind.target(open: [], preferred: .razor) == .razor)
  #expect(EditorKind.target(open: [.studio], preferred: .razor) == .studio)
  #expect(EditorKind.target(open: [.studio, .razor], preferred: .razor) == .razor)
  #expect(EditorKind.target(open: [.razor], preferred: .studio) == .razor)
}
