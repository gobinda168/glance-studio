import Foundation
import Testing
@testable import GlanceCore

private let ref = AutomationRunRef(automation: "fix-red-ci", run: "2026-10-09T09-00-00.000Z")
private let date = Date(timeIntervalSince1970: 1_791_536_400)

@Test func aParkedRunAsksWithTheRenderedCommand() {
  let plan = AutomationStepPlan(step: "comment", work: .shell("gh pr comment '412' -F -"), cwd: "/tmp",
                                stdin: "Pushed a fix.", outward: true)
  let notice = AutomationNotices.parked(name: "Fix red CI", ref: ref, plan: plan, date: date)
  #expect(notice.source == .automations && notice.kind == .automationApproval && notice.kind.needsYou)
  #expect(notice.title == "Fix red CI")
  #expect(notice.place == "wants to run comment")
  #expect(notice.meta["detail"] == "gh pr comment '412' -F -\n\nstdin:\nPushed a fix.")
  #expect(notice.preview == "gh pr comment '412' -F - stdin: Pushed a fix.")
  #expect(notice.actions?.map(\.title) == ["Approve", "Skip", "Trust this automation"])
  #expect(notice.actions?.map(\.id) == ["approve", "skip", "trust"])
  #expect(notice.threadKey == "automations:fix-red-ci/2026-10-09T09-00-00.000Z")
  #expect(AutomationNotices.ref(notice) == ref)
  #expect(NudgeRules.shouldNudge(notice, prefs: .defaults, now: date, inMeeting: false))
}

@Test func aFailedRunShowsItsLastTwentyLinesAndTheWayToFixIt() {
  let output = (1...30).map { "line \($0)" }.joined(separator: "\n") + "\n"
  let notice = AutomationNotices.failed(name: "Fix red CI", ref: ref, step: "fix", output: output, status: .failed,
                                        date: date)
  #expect(notice.kind == .automationFailed)
  #expect(notice.place == "failed at fix")
  #expect(notice.meta["detail"]?.split(separator: "\n").first == "line 11")
  #expect(notice.meta["detail"]?.split(separator: "\n").count == 20)
  #expect(notice.actions?.map(\.title) == ["Open run", "Ask Claude to fix"])
  #expect(notice.threadKey == AutomationNotices.threadKey(ref))
  let expired = AutomationNotices.failed(name: "Fix red CI", ref: ref, step: "comment", output: "", status: .expired,
                                         date: date)
  #expect(expired.place == "expired waiting for approval at comment")
  #expect(expired.preview == "expired waiting for approval at comment")
}

@Test func runsThatCouldntStartAndBrokenWatchersSayWhy() {
  let start = AutomationNotices.couldNotStart(name: "Fix red CI", automation: "fix-red-ci", trigger: "event pr.ci.failed",
                                              problems: [AutomationProblem("inputs.repo", "is required")], date: date)
  #expect(start.place == "couldn't start from event pr.ci.failed")
  #expect(start.preview == "inputs.repo: is required")
  #expect(AutomationNotices.ref(start) == nil)
  let watcher = AutomationNotices.watcherBroken(name: "Fix red CI", automation: "fix-red-ci",
                                                stderr: "gh: auth required\n", date: date)
  #expect(watcher.preview == "gh: auth required")
  #expect(watcher.actions?.map(\.id) == ["enable"])
  #expect(Notice.Source.automations.title == "Automations")
  #expect(Notice.Kind.kinds(of: .automations) == [.automationApproval, .automationFailed])
}

@Test func anAgentsQuestionIsACardThatOpensItsRun() {
  let question = AutomationQuestion(step: "propose", question: "Push the fix?", body: "CI fails on lint.",
                                    choices: ["Yes", "No"], allowsText: false)
  let notice = AutomationNotices.asked(name: "Fix red CI", ref: ref, question: question, date: date)
  #expect(notice.kind == .automationApproval && notice.kind.needsYou)
  #expect(notice.place == "is asking you" && notice.preview == "Push the fix?")
  #expect(notice.meta["detail"] == "Push the fix?\n\nCI fails on lint.")
  #expect(notice.actions?.map(\.id) == ["open-run"])
  #expect(notice.threadKey == AutomationNotices.threadKey(ref) && AutomationNotices.ref(notice) == ref)
}
