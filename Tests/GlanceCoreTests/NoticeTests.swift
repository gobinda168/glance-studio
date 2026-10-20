import Foundation
import Testing
@testable import GlanceCore

@Test func everyKindBelongsToOneSourceAndHasALabel() {
  for kind in Notice.Kind.allCases {
    #expect(!kind.label.isEmpty)
    #expect(Notice.Kind.kinds(of: kind.source).contains(kind))
  }
  #expect(Notice.Kind.kinds(of: .slack) == [.slackDM, .slackMention, .slackThread, .slackChannel])
}

@Test func needsYouIsTheDirectAsks() {
  let needs = Set(Notice.Kind.allCases.filter(\.needsYou))
  #expect(needs == [.slackDM, .slackMention, .githubReviewRequested, .githubMention, .githubAssigned,
                    .githubCIFailed, .claudeNeedsInput, .meetingStarting, .ticketSuggestion, .ticketFailed,
                    .automationApproval, .automationFailed])
}

@Test func aNoticeRoundTripsThroughJSON() throws {
  let notice = Notice(id: "github:1:2026", source: .github, kind: .githubComment, title: "acme/api #412",
                      place: "Comment", preview: "Looks good", date: Date(timeIntervalSince1970: 1_000),
                      threadKey: "github:acme/api#412",
                      target: .pullRequest(repository: "acme/api", number: 412, path: "A.swift", line: 3),
                      people: ["riya"], meta: ["thread": "1"])
  let data = try JSONEncoder().encode(notice)
  #expect(try JSONDecoder().decode(Notice.self, from: data) == notice)
  #expect(notice.state == .unread)
}

@Test func previewsAreOneTrimmedLine() {
  #expect(Notice.previewLine("  hello\n\n  world\t ") == "hello world")
  #expect(Notice.previewLine(String(repeating: "a", count: 400)).count == 280)
}
