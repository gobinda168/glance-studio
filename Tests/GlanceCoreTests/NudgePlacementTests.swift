import CoreGraphics
import Testing
@testable import GlanceCore

private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
private let card = CGSize(width: 440, height: 64)

@Test func theCardSitsTopCentreUnderTheMenuBar() {
  #expect(NudgePlacement.frame(card: card, screen: screen, visible: visible)
    == CGRect(x: 500, y: 875 - 10 - 64, width: 440, height: 64))
}

@Test func theCardCentresOnTheScreenNotTheSpaceBesideASideDock() {
  let docked = CGRect(x: 80, y: 0, width: 1360, height: 875)
  #expect(NudgePlacement.frame(card: card, screen: screen, visible: docked).minX == 500)
}

@Test func theCardStaysOnANarrowScreen() {
  let narrow = CGRect(x: 2000, y: 0, width: 400, height: 875)
  #expect(NudgePlacement.frame(card: card, screen: narrow, visible: narrow).minX == 2008)
}
