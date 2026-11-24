import Testing
@testable import GlanceCore

struct WorktreesModeTests {
  @Test func worktreesIsADevelopmentFeatureWithItsOwnStripItem() {
    #expect(!Feature.worktrees.isGA)
    #expect(Feature.worktrees.title == "Worktrees")
    #expect(SidebarMode.worktrees.feature == .worktrees)
    #expect(SidebarMode.worktrees.icon == .branch)
    #expect(SidebarMode.stripModes(enabled: [.worktrees]) == [.terminal, .editor, .pullRequests, .worktrees, .captures, .mods])
    #expect(!SidebarMode.stripModes(enabled: []).contains(.worktrees))
  }

  @Test func commandTakesOverWorktreesWhileItsFlagIsOn() {
    #expect(SidebarMode.command.feature == .commandCenter)
    #expect(SidebarMode.command.title == "Command")
    #expect(SidebarMode.command.icon == .board)
    // Right after Terminal, as in the replica; Worktrees gives way.
    #expect(SidebarMode.stripModes(enabled: [.commandCenter, .worktrees])
      == [.terminal, .command, .editor, .pullRequests, .captures, .mods])
    // With Worktrees off the item still shows the board.
    #expect(SidebarMode.stripModes(enabled: [.commandCenter])
      == [.terminal, .command, .editor, .pullRequests, .captures, .mods])
    // With the flag off, nothing changes.
    #expect(SidebarMode.stripModes(enabled: [.worktrees])
      == [.terminal, .editor, .pullRequests, .worktrees, .captures, .mods])
  }

  @Test func aSavedChoiceFollowsTheFlag() {
    #expect(SidebarMode(saved: "worktrees", enabled: [.worktrees, .commandCenter]) == .command)
    #expect(SidebarMode(saved: "worktrees", enabled: [.worktrees]) == .worktrees)
    #expect(SidebarMode(saved: "command", enabled: [.commandCenter]) == .command)
    #expect(SidebarMode(saved: "command", enabled: [.worktrees]) == .worktrees)
    #expect(SidebarMode(saved: "command", enabled: []) == .terminal)
  }
}
