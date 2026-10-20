import Testing
@testable import GlanceCore

@Test func draggingDownLandsJustBeforeTheDropOffset() {
  // [a b c d]: drag a (0) to the offset after c (3): result [b c a d], a is now at 2.
  #expect(TabOrder.insertionIndex(from: 0, toOffset: 3) == 2)
  // Drag b (1) to the very end (offset 4): lands at the last index of the remaining list, 3.
  #expect(TabOrder.insertionIndex(from: 1, toOffset: 4) == 3)
}

@Test func draggingUpLandsAtTheDropOffset() {
  #expect(TabOrder.insertionIndex(from: 3, toOffset: 0) == 0)
  #expect(TabOrder.insertionIndex(from: 2, toOffset: 1) == 1)
}

@Test func droppingInPlaceChangesNothing() {
  #expect(TabOrder.insertionIndex(from: 1, toOffset: 1) == nil)
  #expect(TabOrder.insertionIndex(from: 1, toOffset: 2) == nil) // just below itself is the same spot
  #expect(TabOrder.insertionIndex(from: 0, toOffset: 0) == nil)
}

@Test func nonsenseIndicesAreIgnored() {
  #expect(TabOrder.insertionIndex(from: -1, toOffset: 2) == nil)
  #expect(TabOrder.insertionIndex(from: 1, toOffset: -3) == nil)
}
