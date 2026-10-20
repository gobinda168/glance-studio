import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)

private func notice(_ kind: Notice.Kind, people: [String] = ["riya"], place: String? = "#infra", age: TimeInterval = 5)
  -> Notice {
  Notice(id: UUID().uuidString, source: kind.source, kind: kind, title: "Riya", place: place, preview: "hi",
         date: now.addingTimeInterval(-age), threadKey: "t", target: .none, people: people)
}

@Test func theDefaultsMatchTheSpec() {
  let prefs = NotificationPrefs.defaults
  let on: Set<Notice.Kind> = [.slackDM, .slackMention, .slackThread, .githubReviewRequested, .githubMention,
                              .githubComment, .githubAssigned, .githubCIFailed, .claudeNeedsInput,
                              .ticketSuggestion, .ticketMoved, .ticketFailed, .automationApproval, .automationFailed,
                              .claudeMessage]
  for kind in Notice.Kind.allCases where kind != .meetingStarting { #expect(prefs.nudges(kind) == on.contains(kind)) }
  #expect(prefs.quietInMeetings && prefs.sound && !prefs.doNotDisturb && prefs.vips.isEmpty)
}

@Test func aSwitchedOnKindNudges() {
  #expect(NudgeRules.shouldNudge(notice(.slackDM), prefs: .defaults, now: now, inMeeting: false))
  #expect(!NudgeRules.shouldNudge(notice(.slackChannel), prefs: .defaults, now: now, inMeeting: false))
}

@Test func vipsNudgeEvenWhenTheKindIsOff() {
  var prefs = NotificationPrefs.defaults
  prefs.vips = ["@Riya", "#Incidents"]
  #expect(NudgeRules.shouldNudge(notice(.slackChannel), prefs: prefs, now: now, inMeeting: false))
  #expect(NudgeRules.shouldNudge(notice(.slackChannel, people: ["sam"], place: "#incidents"), prefs: prefs, now: now,
                                 inMeeting: false))
  #expect(!NudgeRules.shouldNudge(notice(.slackChannel, people: ["sam"], place: "#random"), prefs: prefs, now: now,
                                  inMeeting: false))
}

@Test func doNotDisturbAndMeetingsSilenceEveryone() {
  var prefs = NotificationPrefs.defaults
  prefs.vips = ["riya"]
  prefs.doNotDisturb = true
  #expect(!NudgeRules.shouldNudge(notice(.slackDM), prefs: prefs, now: now, inMeeting: false))
  prefs.doNotDisturb = false
  #expect(!NudgeRules.shouldNudge(notice(.slackDM), prefs: prefs, now: now, inMeeting: true))
  prefs.quietInMeetings = false
  #expect(NudgeRules.shouldNudge(notice(.slackDM), prefs: prefs, now: now, inMeeting: true))
}

@Test func staleNoticesAndMeetingsNeverNudge() {
  #expect(!NudgeRules.shouldNudge(notice(.slackDM, age: 601), prefs: .defaults, now: now, inMeeting: false))
  #expect(!NudgeRules.shouldNudge(notice(.meetingStarting), prefs: .defaults, now: now, inMeeting: false))
}

@Test func prefsRoundTripAndSurviveNewKinds() throws {
  var prefs = NotificationPrefs.defaults
  prefs.set(.slackChannel, true)
  let data = try JSONEncoder().encode(prefs)
  #expect(try JSONDecoder().decode(NotificationPrefs.self, from: data) == prefs)
  // A kind missing from saved prefs falls back to its default.
  let partial = try JSONDecoder().decode(NotificationPrefs.self, from: Data(#"{"nudge":{},"vips":[],"doNotDisturb":false,"quietInMeetings":true,"sound":true}"#.utf8))
  #expect(partial.nudges(.slackDM))
}
