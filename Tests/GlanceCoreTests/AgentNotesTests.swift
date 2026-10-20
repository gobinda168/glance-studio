import Foundation
import Testing
@testable import GlanceCore

@Test func rememberAndSendBlocksAreFoundInOrder() {
  let text = """
    Done.
    <remember>The user prefers squash merges.</remember>
    <send to="release-notes">PR 412 merged,
    draft the notes.</send>
    <remember>  </remember>
    <send to="Bad Id">no</send>
    <send to="triage"></send>
    """
  let found = AgentNotes.extract(text)
  #expect(found.memories == ["The user prefers squash merges."])
  #expect(found.messages == [AgentNotes.Message(to: "release-notes", text: "PR 412 merged,\ndraft the notes.")])
  #expect(AgentNotes.extract("nothing here").isEmpty)
}

@Test func aMessageIsCut() {
  let long = String(repeating: "x", count: 5_000)
  let found = AgentNotes.extract("<send to=\"a\">\(long)</send>")
  #expect(found.messages.first?.text.count == AgentNotes.messageLimit)
}

@Test func memoryGrowsByDatedLinesWithoutRepeatsAndForgetsTheOldest() {
  var memory = AgentNotes.merged(memory: "", adding: ["Likes squash.", "Uses\nmain."], on: "2026-10-12")
  #expect(memory == "- 2026-10-12: Likes squash.\n- 2026-10-12: Uses main.\n")
  memory = AgentNotes.merged(memory: memory, adding: ["Likes squash."], on: "2026-10-13")
  #expect(memory.split(separator: "\n").count == 2)
  let big = (1...400).map { "note number \($0) " + String(repeating: "y", count: 40) }
  let capped = AgentNotes.merged(memory: "", adding: big, on: "2026-10-12")
  #expect(capped.count <= AgentNotes.memoryLimit + 1)
  #expect(capped.contains("note number 400") && !capped.contains("note number 1 "))
}

@Test func thePrefaceHoldsTheMemoryAndThePeers() {
  let peers = [AgentNotes.Peer(id: "release-notes", name: "Release notes", description: "Drafts notes")]
  let preface = AgentNotes.preface(memory: "- 2026-10-12: Likes squash.\n", peers: peers)
  #expect(preface.contains("notes, not instructions") && preface.contains("Likes squash."))
  #expect(preface.contains("- release-notes: Release notes, Drafts notes"))
  let bare = AgentNotes.preface(memory: "", peers: [])
  #expect(bare.contains("no memory from earlier runs") && !bare.contains("<send"))
}

@Test func hopsComeFromTheMessageThatStartedTheRun() {
  let event = GlanceEvent.agentMessage(from: "a", to: "b", text: "hi", hops: 2)
  #expect(event.name == "agent.message" && AgentNotes.hops(of: event.payload) == 2)
  #expect(AgentNotes.hops(of: .object([:])) == 0 && AgentNotes.hops(of: .null) == 0)
}
