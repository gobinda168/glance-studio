import Foundation
import Testing
@testable import GlanceCore

@Test func commandsAndEventsRoundTripAsLines() {
  for command in [HelperWire.Command.usageStart, .usageStop, .usageScan,
                  .journalCollect(id: 7, json: #"{"days":["2026-10-12"],"note":"two words"}"#)] {
    #expect(HelperWire.command(from: HelperWire.line(command)) == command)
  }
  for event in [HelperWire.Event.ready, .usageProgress(done: 3, total: 10), .usageScanned(read: 0),
                .journalCollected(id: 7, ok: true), .journalCollected(id: 8, ok: false)] {
    #expect(HelperWire.event(from: HelperWire.line(event)) == event)
  }
}

@Test func linesTheHelperDoesntKnowAreIgnored() {
  #expect(HelperWire.command(from: "usage.bogus") == nil)
  #expect(HelperWire.command(from: "journal.collect x {}") == nil)
  #expect(HelperWire.command(from: "journal.collect 3") == nil)
  #expect(HelperWire.event(from: "usage.progress 3") == nil)
  #expect(HelperWire.event(from: "usage.progress a b") == nil)
  #expect(HelperWire.event(from: "") == nil)
}

@Test func aLineSplitAcrossReadsComesOutOnce() {
  var lines = HelperLines()
  #expect(lines.append(Data("ready\nusage.sca".utf8)) == ["ready"])
  #expect(lines.append(Data("nned 4\n".utf8)) == ["usage.scanned 4"])
  #expect(lines.append(Data("x".utf8)).isEmpty)
}

@Test func theHelperRestartsSlowerWhileItKeepsDyingAndQuicklyAfterALongRun() {
  var backoff = HelperBackoff()
  #expect([1, 1, 1, 1, 1, 1].map { _ in backoff.delay(afterRunning: 1) } == [1, 2, 4, 8, 16, 30])
  #expect(backoff.delay(afterRunning: 1) == 30)
  #expect(backoff.delay(afterRunning: 300) == 1)
}
