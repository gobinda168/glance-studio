import Testing
@testable import GlanceCore

private let home = "/Users/me"

@Test func anOpenEditorOnTheProjectIsReusedHoweverItsFolderIsSpelled() {
  let editors: [(tab: Int, root: String)] = [(1, "/Users/me/Code/web"), (2, "/Users/me/Code/acme/")]
  #expect(TabSwitch.editor(for: "~/Code/acme", editors: editors, home: home) == .reuse(2))
  #expect(TabSwitch.editor(for: "/Users/me/Code/billing", editors: editors, home: home) == .create)
  #expect(TabSwitch.editor(for: "/private/tmp/x", editors: [(3, "/tmp/x")], home: home) == .reuse(3))
}

@Test func theProjectsMostRecentTerminalIsReused() {
  var memory = StripMemory<Int>()
  memory.recordFront(10, mode: .terminal)
  memory.recordFront(11, mode: .terminal)
  memory.recordFront(12, mode: .terminal)
  let terminals: [(tab: Int, project: String)] = [(10, "/Users/me/Code/acme"), (11, "/Users/me/Code/acme"),
                                                  (12, "/Users/me/Code/billing")]
  #expect(TabSwitch.terminal(for: "/Users/me/Code/acme", terminals: terminals, memory: memory, home: home) == .reuse(11))
  #expect(TabSwitch.terminal(for: "/Users/me/Code/docs", terminals: terminals, memory: memory, home: home) == .create)
}

@Test func withNoRecencyTheProjectsLastTerminalInOrderIsReused() {
  let terminals: [(tab: Int, project: String)] = [(10, "/Users/me/Code/acme"), (11, "/Users/me/Code/acme")]
  #expect(TabSwitch.terminal(for: "~/Code/acme", terminals: terminals, memory: StripMemory(), home: home) == .reuse(11))
}

@Test func homeAndTheDiskRootAreNotProjects() {
  #expect(TabSwitch.isProjectless("~", home: home))
  #expect(TabSwitch.isProjectless("/Users/me/", home: home))
  #expect(TabSwitch.isProjectless("/", home: home))
  #expect(!TabSwitch.isProjectless("/Users/me/Code/acme", home: home))
  #expect(!TabSwitch.isProjectless("/Users/me/Downloads", home: home))
}
