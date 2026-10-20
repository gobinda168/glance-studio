import Testing
@testable import GlanceCore

@Test func theWidthStaysWithinTheBounds() {
  #expect(TabSidebarLayout.minWidth == 260)
  #expect(TabSidebarLayout.maxWidth == 400)
  #expect(TabSidebarLayout.clamp(100) == 260)
  #expect(TabSidebarLayout.clamp(220) == 260) // the old split view's default is too narrow now
  #expect(TabSidebarLayout.clamp(500) == 400)
  #expect(TabSidebarLayout.clamp(320) == 320)
  #expect(TabSidebarLayout.clamp(.nan) == TabSidebarLayout.defaultWidth)
}

@Test func theDefaultWidthIsTheCanvasSideBar() {
  #expect(TabSidebarLayout.defaultWidth == 300)
  #expect(TabSidebarLayout.clamp(TabSidebarLayout.defaultWidth) == TabSidebarLayout.defaultWidth)
}
