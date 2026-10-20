import Foundation
import Testing
@testable import GlanceCore

private let home = "/Users/me"
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func book() -> TabStatusBook { TabStatusBook(home: home, thinkingTimeout: 600) }

@Test func aPromptMakesTheFolderThink() {
  var b = book()
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: nil, at: t0)
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0) == .thinking)
  #expect(b.status(forTabFolder: "/Users/me/other", at: t0) == .idle)
}

@Test func aTurnThatEndsOutOfSightIsFinishedUntilVisited() {
  var b = book()
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: "/Users/me/other", at: t0)
  b.turn(.done, cwd: "/Users/me/app", focusedFolder: "/Users/me/other", at: t0.addingTimeInterval(5))
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(6)) == .finished)
  b.visited(folder: "/Users/me/app")
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(7)) == .idle)
}

@Test func aTurnThatEndsInTheFocusedFolderIsAlreadySeen() {
  var b = book()
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: "/Users/me/app", at: t0)
  b.turn(.done, cwd: "/Users/me/app", focusedFolder: "/Users/me/app/", at: t0.addingTimeInterval(5))
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(6)) == .idle)
}

@Test func visitingDoesNotStopThinking() {
  var b = book()
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: nil, at: t0)
  b.visited(folder: "/Users/me/app")
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(1)) == .thinking)
}

@Test func aStuckThinkingFallsBackToIdleAfterTheTimeout() {
  var b = book()
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: nil, at: t0)
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(600)) == .thinking)
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(601)) == .idle)
}

@Test func aNewPromptAfterAFinishedTurnThinksAgain() {
  var b = book()
  b.turn(.done, cwd: "/Users/me/app", focusedFolder: nil, at: t0)
  b.turn(.prompt, cwd: "/Users/me/app", focusedFolder: nil, at: t0.addingTimeInterval(10))
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0.addingTimeInterval(11)) == .thinking)
}

@Test func tabsInOneFolderShareAStatusWhateverTheSpelling() {
  var b = book()
  b.turn(.prompt, cwd: "~/app", focusedFolder: nil, at: t0)
  #expect(b.status(forTabFolder: "/Users/me/app/", at: t0) == .thinking)
  #expect(b.status(forTabFolder: "/Users/me/app", at: t0) == .thinking)
}

@Test func unknownFoldersAreIdleAndIgnored() {
  var b = book()
  b.turn(.prompt, cwd: nil, focusedFolder: nil, at: t0)
  b.turn(.prompt, cwd: "", focusedFolder: nil, at: t0)
  b.visited(folder: nil)
  #expect(b.status(forTabFolder: nil, at: t0) == .idle)
  #expect(b.status(forTabFolder: "", at: t0) == .idle)
}
