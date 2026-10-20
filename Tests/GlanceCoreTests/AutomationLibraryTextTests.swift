import Foundation
import Testing

@testable import GlanceCore

@Test func aLibraryCardNamesEachTriggerInFewWords() {
  #expect(AutomationText.chip(AutomationTrigger(kind: "schedule", cron: "0 9 * * 1-5")) == "0 9 * * 1-5")
  #expect(AutomationText.chip(AutomationTrigger(kind: "files", path: "~/Downloads", glob: "*.pdf")) == "~/Downloads (*.pdf)")
  #expect(AutomationText.chip(AutomationTrigger(kind: "event", name: "meeting.ended")) == "meeting.ended")
  #expect(AutomationText.chip(AutomationTrigger(kind: "watcher", script: "steps/watch-ci.sh", every: "2m"))
    == "watch-ci.sh every 2m")
  #expect(AutomationText.chip(AutomationTrigger(kind: "manual")) == nil)
  #expect(AutomationText.chip(AutomationTrigger(kind: "somethingNew")) == nil)
}
