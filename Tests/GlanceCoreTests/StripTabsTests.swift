import Testing
@testable import GlanceCore

@Test func eachTabKindBelongsToItsStripItem() {
  #expect(SidebarMode.owner(ofTabKind: nil) == .terminal) // a terminal tab has no Glance kind
  #expect(SidebarMode.owner(ofTabKind: "home") == .terminal)
  #expect(SidebarMode.owner(ofTabKind: "command") == .command)
  #expect(SidebarMode.owner(ofTabKind: "razor") == .editor)
  #expect(SidebarMode.owner(ofTabKind: "studio") == .editor)
  #expect(SidebarMode.owner(ofTabKind: "editorStart") == .editor)
  #expect(SidebarMode.owner(ofTabKind: "browser") == .browser)
  #expect(SidebarMode.owner(ofTabKind: "pullRequest") == .pullRequests)
  #expect(SidebarMode.owner(ofTabKind: "newPullRequest") == .pullRequests)
  #expect(SidebarMode.owner(ofTabKind: "reviewInbox") == .pullRequests)
  #expect(SidebarMode.owner(ofTabKind: "automation") == .automations)
  #expect(SidebarMode.owner(ofTabKind: "automationBuilder") == .automations)
  #expect(SidebarMode.owner(ofTabKind: "automationsLibrary") == .automations)
  #expect(SidebarMode.owner(ofTabKind: "agentsLibrary") == .agents)
  #expect(SidebarMode.owner(ofTabKind: "tickets") == .tickets)
  #expect(SidebarMode.owner(ofTabKind: "journal") == .journal)
  #expect(SidebarMode.owner(ofTabKind: "meetings") == .meetings)
  #expect(SidebarMode.owner(ofTabKind: "usage") == .usage)
  #expect(SidebarMode.owner(ofTabKind: "notifications") == .notifications)
  #expect(SidebarMode.owner(ofTabKind: "settings") == .settings)
  #expect(SidebarMode.owner(ofTabKind: "somethingNew") == nil)
}

@Test func aStripItemGoesBackToItsRememberedTab() {
  var memory = StripMemory<Int>()
  memory.recordFront(1, mode: .terminal)   // terminal 1
  memory.recordFront(7, mode: .browser)    // the dev page
  memory.recordFront(8, mode: .browser)    // another page
  memory.recordFront(7, mode: .browser)    // back on the dev page
  memory.recordFront(2, mode: .terminal)   // terminal 2
  #expect(memory.last(for: .browser, candidates: [7, 8]) == 7)
  #expect(memory.last(for: .terminal, candidates: [1, 2]) == 2)
}

@Test func aClosedRememberedTabFallsBackToTheLatestOpenOne() {
  var memory = StripMemory<Int>()
  memory.recordFront(1, mode: .terminal)
  memory.recordFront(3, mode: .terminal)
  memory.recordFront(2, mode: .terminal)
  // 2 closed: of the open ones, 3 was in front last.
  #expect(memory.last(for: .terminal, candidates: [1, 3]) == 3)
}

@Test func withNothingRememberedTheLastOpenTabInOrderIsUsed() {
  let memory = StripMemory<Int>()
  #expect(memory.last(for: .editor, candidates: [4, 5]) == 5)
  #expect(memory.last(for: .editor, candidates: []) == nil)
}

@Test func aTabWithNoItemIsOrderedButNeverRemembered() {
  var memory = StripMemory<Int>()
  memory.recordFront(1, mode: .terminal)
  memory.recordFront(9, mode: nil) // Home
  #expect(memory.last(for: .terminal, candidates: [1]) == 1)
  #expect(memory.mostRecent(of: [1, 9]) == 9)
}

@Test func automationsAgentsAndModsOpenTheirLibrary() {
  #expect(SidebarMode.allCases.filter(\.opensLibrary) == [.agents, .automations, .mods])
}

@Test func aWorktreePageBelongsToCommandOnlyWhileCommandIsOn() {
  // With Command off the worktree page belongs to no item, as it always did.
  #expect(SidebarMode.owner(ofTabKind: "worktree", commandCenter: false) == nil)
  #expect(SidebarMode.owner(ofTabKind: "worktree", commandCenter: true) == .command)
  // Other kinds are never changed by the flag.
  #expect(SidebarMode.owner(ofTabKind: "razor", commandCenter: true) == .editor)
  #expect(SidebarMode.owner(ofTabKind: nil, commandCenter: true) == .terminal)
  #expect(SidebarMode.owner(ofTabKind: "somethingNew", commandCenter: true) == nil)
}

@Test func aTerminalTabShowingARecapBelongsToCommandOnlyWhileItShowsOneAndCommandIsOn() {
  // A recap opens from a Command row in a terminal tab: it is remembered under Command while it shows the recap.
  #expect(SidebarMode.owner(ofTabKind: nil, commandCenter: true, showingRecap: true) == .command)
  // Once a session started in it, and with Command off, it is a terminal tab as ever.
  #expect(SidebarMode.owner(ofTabKind: nil, commandCenter: true, showingRecap: false) == .terminal)
  #expect(SidebarMode.owner(ofTabKind: nil, commandCenter: false, showingRecap: true) == .terminal)
  // Only a terminal tab can show one.
  #expect(SidebarMode.owner(ofTabKind: "razor", commandCenter: true, showingRecap: true) == .editor)
}
