import Foundation
import Testing
@testable import GlanceCore

@Test func jsonIsFoundInFencesAndProse() {
  #expect(ClaudeJSON.object(in: "Sure!\n```json\n{\"ok\": true}\n```")?["ok"] as? Bool == true)
  #expect(ClaudeJSON.object(in: "Here: {\"a\": {\"b\": \"}\"}} done")?["a"] != nil)
  #expect(ClaudeJSON.object(in: "no json here") == nil)
  #expect(ClaudeJSON.object(in: "{broken") == nil)
}

@Test func aSlackThreadParses() {
  let text = #"{"channel":"C1","ts":"1712.1","thread_ts":"1712.0","permalink":"https://x.slack.com/archives/C1/p1712","messages":[{"author":"Riya","text":"deploy?","ts":"1712.0"},{"author":"Sam","text":"yes","ts":"1712.1"}]}"#
  let thread = QuickReply.slackThread(from: text)
  #expect(thread?.channel == "C1" && thread?.threadTS == "1712.0" && thread?.messages.count == 2)
  #expect(QuickReply.slackThread(from: #"{"error":"not found"}"#) == nil)
}

@Test func sentResultsParse() {
  #expect(QuickReply.sent(from: #"{"ok":true,"permalink":"https://p"}"#) == (true, "https://p"))
  #expect(QuickReply.sent(from: "I could not post.").ok == false)
}

@Test func thePromptsCarryTheNoticeAndTheRules() {
  let n = Notice(id: "s", source: .slack, kind: .slackDM, title: "Riya", place: "DM", preview: "can you review?",
                 date: Date(timeIntervalSince1970: 0), threadKey: "k", target: .slack(team: "T1", notificationID: nil, channel: nil),
                 meta: ["workspace": "Acme"])
  let p = QuickReply.prompt(.draft, notice: n, thread: [.init(author: "Riya", text: "can you review?", ts: nil)], canReadSlack: true)
  #expect(p.contains("Riya") && p.contains("can you review?") && p.contains("Acme"))
  #expect(p.contains("Do not send"))
  let send = QuickReply.sendPrompt(text: "On it", channel: "C1", threadTS: "1712.0")
  #expect(send.contains("On it") && send.contains("C1") && send.contains("1712.0"))
  #expect(QuickReply.resolvePrompt(n).contains("can you review?"))
  #expect(QuickReply.draftText("Draft:\n  On it, give me 10 min \n") == "On it, give me 10 min")
}

@Test func theRefinePromptCarriesTheDraftTheRequestAndTheRules() {
  let n = Notice(id: "s", source: .slack, kind: .slackDM, title: "Riya", place: "DM", preview: "can you review?",
                 date: Date(timeIntervalSince1970: 0), threadKey: "k", target: .slack(team: "T1", notificationID: nil, channel: nil),
                 meta: [:])
  let thread: [QuickReply.Message] = [.init(author: "Riya", text: "can you review?", ts: nil)]
  let p = QuickReply.refinePrompt(notice: n, thread: thread, draft: "sure, tmrw", instruction: "make it friendlier",
                                  canReadSlack: false)
  #expect(p.contains("sure, tmrw") && p.contains("make it friendlier") && p.contains("can you review?"))
  #expect(p.contains("Do not send") && p.contains("only the full text"))
  let empty = QuickReply.refinePrompt(notice: n, thread: thread, draft: "  ", instruction: "say yes", canReadSlack: false)
  #expect(empty.contains("(nothing yet)") && empty.contains("say yes"))
}
