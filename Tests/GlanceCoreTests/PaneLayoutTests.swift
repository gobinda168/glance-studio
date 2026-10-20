import Testing
@testable import GlanceCore

@Test func thePinCyclesAutoPinnedFloating() {
  #expect(PaneLayout.Mode.auto.next == .pinned)
  #expect(PaneLayout.Mode.pinned.next == .floating)
  #expect(PaneLayout.Mode.floating.next == .auto)
}

@Test func anUnknownSavedModeIsAuto() {
  #expect(PaneLayout.Mode(saved: nil) == .auto)
  #expect(PaneLayout.Mode(saved: "sideways") == .auto)
  #expect(PaneLayout.Mode(saved: "floating") == .floating)
}

@Test func pinnedAndFloatingIgnoreTheWidth() {
  #expect(PaneLayout.placement(mode: .pinned, width: 600, current: .floating) == .sidebar)
  #expect(PaneLayout.placement(mode: .floating, width: 3000, current: .sidebar) == .floating)
}

@Test func autoPicksTheSidebarWhenTheTerminalKeepsEnoughRoom() {
  let threshold = PaneLayout.paneWidth + PaneLayout.minTerminalWidth
  #expect(PaneLayout.placement(mode: .auto, width: 1920, current: nil) == .sidebar)
  #expect(PaneLayout.placement(mode: .auto, width: 1000, current: nil) == .floating)
  #expect(PaneLayout.placement(mode: .auto, width: threshold, current: nil) == .sidebar)
  #expect(PaneLayout.placement(mode: .auto, width: threshold - 1, current: nil) == .floating)
}

@Test func autoDoesNotFlickerNearTheThreshold() {
  let threshold = PaneLayout.paneWidth + PaneLayout.minTerminalWidth
  let slack = PaneLayout.hysteresis
  // Shown as a sidebar: it stays until the window is clearly narrower.
  #expect(PaneLayout.placement(mode: .auto, width: threshold - slack + 1, current: .sidebar) == .sidebar)
  #expect(PaneLayout.placement(mode: .auto, width: threshold - slack, current: .sidebar) == .floating)
  // Floating: it stays until the window is clearly wider.
  #expect(PaneLayout.placement(mode: .auto, width: threshold + slack - 1, current: .floating) == .floating)
  #expect(PaneLayout.placement(mode: .auto, width: threshold + slack, current: .floating) == .sidebar)
}

@Test func anUnmeasuredWindowGetsTheSidebar() {
  #expect(PaneLayout.placement(mode: .auto, width: 0, current: nil) == .sidebar)
  #expect(PaneLayout.placement(mode: .auto, width: .nan, current: .floating) == .floating)
}

// MARK: Reading docks the pane (spec 2026-10-11-humanize-summaries-design.md, "A fixed right side for reading")

@Test func readingDocksThePaneWhateverTheMode() {
  #expect(PaneLayout.placement(mode: .floating, width: 600, current: .floating, reading: true) == .sidebar)
  #expect(PaneLayout.placement(mode: .auto, width: 600, current: .floating, reading: true) == .sidebar)
  #expect(PaneLayout.placement(mode: .floating, width: 600, current: .sidebar, reading: false) == .floating)
}

@Test func theSidebarWidthIsClampedAndDefaults() {
  #expect(PaneLayout.sidebarWidth(nil) == 460)
  #expect(PaneLayout.sidebarWidth(100) == 320)
  #expect(PaneLayout.sidebarWidth(900) == 720)
  #expect(PaneLayout.sidebarWidth(560) == 560)
  #expect(PaneLayout.sidebarWidth(.nan) == 460)
}
