import Foundation
import Testing
@testable import GlanceCore

private let now = Date(timeIntervalSince1970: 1_760_000_000)
private func p(_ title: String, _ body: String, tag: String? = nil) -> SlackNotices.Payload {
  SlackNotices.Payload(["id": "n1", "title": title, "body": body, "tag": tag as Any])!
}

@Test func aDirectMessage() {
  let n = SlackNotices.notice(p("Riya Sharma", "can you review #412?"), team: "T1", workspace: "Acme", at: now)
  #expect(n.kind == .slackDM)
  #expect(n.title == "Riya Sharma" && n.place == "DM")
  #expect(n.preview == "can you review #412?")
  #expect(n.people == ["Riya Sharma"])
  #expect(n.target == .slack(team: "T1", notificationID: "n1", channel: nil))
  #expect(n.meta["workspace"] == "Acme")
}

@Test func aChannelMessageNamesSenderAndChannel() {
  let a = SlackNotices.notice(p("Riya Sharma in #infra", "deploy now?"), team: "T1", workspace: nil, at: now)
  #expect(a.title == "Riya Sharma" && a.place == "#infra" && a.kind == .slackChannel)
  let b = SlackNotices.notice(p("New message in #infra", "Riya Sharma: @Gobinda deploy now?"), team: "T1", workspace: nil, at: now)
  #expect(b.title == "Riya Sharma" && b.place == "#infra" && b.kind == .slackMention)
  #expect(b.preview == "@Gobinda deploy now?")
  let c = SlackNotices.notice(p("#infra", "Sam: @here lunch"), team: "T1", workspace: nil, at: now)
  #expect(c.title == "Sam" && c.place == "#infra" && c.kind == .slackMention)
}

@Test func threadsAreThreads() {
  let n = SlackNotices.notice(p("Thread in #infra", "Riya Sharma: shipped"), team: "T1", workspace: nil, at: now)
  #expect(n.kind == .slackThread && n.place == "#infra" && n.title == "Riya Sharma")
}

@Test func threadKeysUseTheTagElseThePlace() {
  #expect(SlackNotices.notice(p("Riya", "a", tag: "C1-1712.0"), team: "T1", workspace: nil, at: now).threadKey == "slack:T1:C1-1712.0")
  #expect(SlackNotices.notice(p("Riya", "a"), team: "T1", workspace: nil, at: now).threadKey == "slack:T1:DM:Riya")
  #expect(SlackNotices.notice(p("Sam in #infra", "a"), team: "T1", workspace: nil, at: now).threadKey == "slack:T1:#infra")
}

@Test func garbagePayloadsAreRejected() {
  #expect(SlackNotices.Payload("nope") == nil)
  #expect(SlackNotices.Payload(["title": 3]) == nil)
}

// Not in the brief: the other title shapes, the notice id, and the payload defaults.
@Test func otherSlackTitleShapesParse() {
  let a = SlackNotices.notice(p("New message from Riya Sharma", "hi"), team: "T1", workspace: nil, at: now)
  #expect(a.title == "Riya Sharma" && a.place == "DM" && a.kind == .slackDM)
  let b = SlackNotices.notice(p("Riya Sharma (#infra)", "hi"), team: "T1", workspace: nil, at: now)
  #expect(b.title == "Riya Sharma" && b.place == "#infra" && b.kind == .slackChannel)
  let c = SlackNotices.notice(p("Riya Sharma", "Riya Sharma mentioned you"), team: "T1", workspace: nil, at: now)
  #expect(c.kind == .slackDM)
  #expect(c.id == "slack:T1:n1:\(now.timeIntervalSince1970)")
  #expect(c.source == .slack && c.date == now && c.meta["workspace"] == nil)
}

@Test func payloadDefaults() {
  let payload = SlackNotices.Payload(["title": "Riya", "tag": NSNull(), "icon": "https://a/i.png"])
  #expect(payload?.body == "" && payload?.tag == nil && payload?.icon == "https://a/i.png")
  #expect(payload?.id.isEmpty == false)
}
