import Testing
@testable import GlanceCore

// The book's mutating calls sit outside #expect: the macro captures its operands as immutable values.

@Test func aManualRunWaitsInItsTabNotOnACard() {
  var book = AutomationInlineBook()
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r1")
  let noTab = book.parked(ref, manual: true)
  #expect(!noTab) // no tab open: a card
  book.opened("fix-red-ci")
  let inTab = book.parked(ref, manual: true)
  #expect(inTab) // its tab shows it
  let byTrigger = book.parked(AutomationRunRef(automation: "fix-red-ci", run: "r2"), manual: false)
  #expect(!byTrigger) // a trigger's run
  let other = book.parked(AutomationRunRef(automation: "other", run: "r3"), manual: true)
  #expect(!other) // another automation
  #expect(book.waiting == [ref])
}

// Review focus: closing the tab never leaves an approval where nobody sees it.
@Test func closingTheLastTabHandsWaitingRunsToCards() {
  var book = AutomationInlineBook()
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r1")
  book.opened("fix-red-ci")
  book.opened("fix-red-ci") // a second window
  let parked = book.parked(ref, manual: true)
  #expect(parked)
  let first = book.closed("fix-red-ci")
  #expect(first == [])
  let last = book.closed("fix-red-ci")
  #expect(last == [ref])
  #expect(book.tabs.isEmpty && book.waiting.isEmpty)
  let stray = book.closed("fix-red-ci")
  #expect(stray == []) // a stray close
}

@Test func anAnsweredRunIsNoLongerWaiting() {
  var book = AutomationInlineBook()
  let ref = AutomationRunRef(automation: "fix-red-ci", run: "r1")
  book.opened("fix-red-ci")
  let parked = book.parked(ref, manual: true)
  #expect(parked)
  book.settled(ref)
  let cards = book.closed("fix-red-ci")
  #expect(cards == [])
}
