import Foundation
import Testing
@testable import GlanceCore

/// A fake growing file: `append` adds bytes, `events` asks the tail with the file's current size.
private struct FakeFile {
  var bytes = Data()
  var tail = TranscriptTail()
  let path = "/p/s.jsonl"

  mutating func append(_ text: String) { bytes.append(Data(text.utf8)) }
  mutating func append(_ data: Data) { bytes.append(data) }

  mutating func events() -> [TurnEvent] {
    let bytes = self.bytes
    return tail.events(in: path, size: UInt64(bytes.count)) { from, to in bytes.subdata(in: Int(from)..<Int(to)) }
  }
}

private let prompt = #"{"type":"user","cwd":"/a","message":{"content":"hi"}}"#
private let done = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[]}}"#

@Test func tailTurnsCompleteLinesIntoEvents() {
  var file = FakeFile()
  file.append(prompt + "\n")
  #expect(file.events() == [TurnEvent(kind: .prompt, cwd: "/a")])
  #expect(file.events() == [])   // nothing new
}

@Test func tailWaitsForTheRestOfAPartialLine() {
  var file = FakeFile()
  file.append(String(prompt.prefix(20)))
  #expect(file.events() == [])
  file.append(String(prompt.dropFirst(20)) + "\n")
  #expect(file.events() == [TurnEvent(kind: .prompt, cwd: "/a")])
}

@Test func tailKeepsSplitUTF8Intact() {
  var file = FakeFile()
  let line = Data((#"{"type":"user","cwd":"/café","message":{"content":"hi"}}"# + "\n").utf8)
  let cut = line.firstIndex(of: 0xC3)! + 1   // between the two bytes of "é"
  file.append(line.prefix(upTo: cut))
  #expect(file.events() == [])
  file.append(line.suffix(from: cut))
  #expect(file.events() == [TurnEvent(kind: .prompt, cwd: "/café")])
}

@Test func tailCarriesTheFilesLastCwd() {
  var file = FakeFile()
  file.append(prompt + "\n" + done + "\n")
  #expect(file.events() == [TurnEvent(kind: .prompt, cwd: "/a"), TurnEvent(kind: .done, cwd: "/a")])
}

@Test func tailSkipsHistoryButReadsNewFiles() {
  var tail = TranscriptTail()
  let old = Data((prompt + "\n").utf8)
  tail.skip(file: "/p/old.jsonl", size: UInt64(old.count))
  #expect(tail.events(in: "/p/old.jsonl", size: UInt64(old.count)) { _, _ in old } == [])
  let new = Data((prompt + "\n").utf8)
  #expect(tail.events(in: "/p/new.jsonl", size: UInt64(new.count)) { from, to in new.subdata(in: Int(from)..<Int(to)) }
    == [TurnEvent(kind: .prompt, cwd: "/a")])
}

@Test func tailRereadsAFileThatShrank() {
  var file = FakeFile()
  file.append(prompt + "\n" + String(done.prefix(10)))   // leaves a partial line behind
  _ = file.events()
  file.bytes = Data((#"{"type":"user","cwd":"/b","message":{"content":"new"}}"# + "\n").utf8)   // rewritten, shorter
  #expect(file.events() == [TurnEvent(kind: .prompt, cwd: "/b")])
}

@Test func tailTriesAgainWhenAReadFails() {
  var tail = TranscriptTail()
  let bytes = Data((prompt + "\n").utf8)
  #expect(tail.events(in: "/p/s.jsonl", size: UInt64(bytes.count)) { _, _ in nil } == [])
  #expect(tail.events(in: "/p/s.jsonl", size: UInt64(bytes.count)) { from, to in bytes.subdata(in: Int(from)..<Int(to)) }
    == [TurnEvent(kind: .prompt, cwd: "/a")])
}

@Test func tailKeepsFilesApart() {
  var tail = TranscriptTail()
  let a = Data(String(prompt.prefix(20)).utf8)
  let b = Data((done + "\n").utf8)
  #expect(tail.events(in: "/p/a.jsonl", size: UInt64(a.count)) { _, _ in a } == [])
  #expect(tail.events(in: "/p/b.jsonl", size: UInt64(b.count)) { _, _ in b } == [TurnEvent(kind: .done, cwd: nil)])
}
