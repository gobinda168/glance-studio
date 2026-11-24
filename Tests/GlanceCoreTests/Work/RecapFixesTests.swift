import Foundation
import Testing
@testable import GlanceCore

// The recap's context must not become a session's name or the wall of text above what the user typed; spend is read as a
// stream; text is typed only into a shell.

private func recap() -> WorktreeRecap {
  var recap = WorktreeRecap(worktree: "/w", title: "Tour", exists: true)
  recap.branch = "feat/tour"
  recap.bullets = ["Added the tour", "Saved progress"]
  recap.commits = [.init(hash: "abc1234", subject: "tour")]
  return recap
}

@Suite struct RecapContextSplitTests {
  @Test func theContextIsSeparatedFromWhatTheUserTyped() throws {
    let first = try RecapText.firstMessage(recap: recap(), asContext: true, text: "now add the intro\nand the outro").get()
    let parts = RecapText.split(first)
    #expect(parts.context?.hasPrefix(RecapText.contextMarker) == true)
    #expect(parts.context?.contains("Added the tour") == true)
    #expect(parts.typed == "now add the intro\nand the outro")
    #expect(RecapText.typedText(first) == "now add the intro\nand the outro")
  }

  @Test func aTrimmedContextIsSeparatedToo() throws {
    var big = recap()
    big.bullets = (0..<12).map { _ in String(repeating: "y", count: 390) }
    let first = try RecapText.firstMessage(recap: big, asContext: true, text: "go").get()
    #expect(first.contains(RecapText.trimmedNote))
    #expect(RecapText.typedText(first) == "go")
  }

  @Test func textWithoutAContextIsLeftAlone() {
    #expect(RecapText.split("fix the login").context == nil)
    #expect(RecapText.typedText("fix the login") == "fix the login")
    // Mentioning the words later in the message is not a context.
    let mention = "please read: " + RecapText.contextMarker
    #expect(RecapText.typedText(mention) == mention)
  }

  @Test func aContextWithNothingTypedAfterItLeavesNothing() {
    #expect(RecapText.typedText(RecapText.contextMarker + " (branch x). Notes.\n- a\n\n") == "")
    #expect(RecapText.typedText(RecapText.contextMarker + " only") == "")
  }

  @Test func aSessionIsNamedAfterWhatWasTypedNotItsContext() throws {
    let first = try RecapText.firstMessage(recap: recap(), asContext: true, text: "add the intro").get()
    #expect(SessionName.fallback("abcdef1234", task: first) == "add the intro")
    // Only a context: the id, not the boilerplate.
    #expect(SessionName.fallback("abcdef1234", task: RecapText.contextMarker + " (branch x).\n- a\n\n") == "session abcdef12")
  }

  @Test func aSummaryTitleAndDigestUseTheTypedText() throws {
    let first = try RecapText.firstMessage(recap: recap(), asContext: true, text: "add the intro").get()
    let line = try #require(String(data: JSONSerialization.data(withJSONObject: [
      "type": "user", "cwd": "/a", "message": ["role": "user", "content": first]]), encoding: .utf8))
    let digest = TranscriptDigest.make(data: Data((line + "\n").utf8), root: "/a")
    #expect(digest.firstPrompt == "add the intro")
    #expect(digest.text == "USER: add the intro")
  }

  @Test func ordinaryMultiLineMessagesStillStartASession() throws {
    let text = "first line\n\nsecond paragraph\n  - indented\nthird"
    #expect(try RecapText.firstMessage(recap: nil, asContext: false, text: text).get() == text)
    let command = try RecapText.startCommand(recap: nil, asContext: true, text: text, channel: false).get()
    #expect(command == "claude '" + text + "'")
  }
}

@Suite struct TranscriptSpendTests {
  // Real Claude Code lines: a prompt, an assistant message with usage (twice: streamed lines repeat a message's id), a
  // sidechain one, one with no usage, one that is not JSON.
  static let lines = [
    #"{"type":"user","uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z","message":{"role":"user","content":"fix the login bug"}}"#,
    #"{"type":"assistant","uuid":"a1","timestamp":"2026-11-01T10:00:02.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Looking."}],"stop_reason":"tool_use","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":50}}}"#,
    #"{"type":"assistant","uuid":"a1b","timestamp":"2026-11-01T10:00:03.000Z","message":{"id":"m1","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"Looking."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":40000,"cache_creation_input_tokens":2000,"output_tokens":900}}}"#,
    #"{"type":"assistant","uuid":"a2","isSidechain":true,"message":{"id":"m2","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"sub"}],"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":0,"output_tokens":20}}}"#,
    #"{"type":"assistant","uuid":"a3","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"no usage"}]}}"#,
    "this is not json",
  ]

  func write(_ lines: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString).jsonl")
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  @Test func theTotalIsWhatTheTimelineCounts() throws {
    var timeline = SessionTimeline(root: nil)
    timeline.ingest(lines: Self.lines)
    #expect(timeline.usage.cost > 0)
    let url = try write(Self.lines)
    defer { try? FileManager.default.removeItem(at: url) }
    let total = try #require(TranscriptSpend.total(of: url))
    #expect(abs(total - timeline.usage.cost) < 1e-9)
  }

  @Test func theChunkSizeDoesNotChangeTheAnswer() throws {
    let url = try write(Self.lines)
    defer { try? FileManager.default.removeItem(at: url) }
    let whole = try #require(TranscriptSpend.total(of: url))
    var reads = 0
    // Smaller than any one line, so every line spans several reads.
    let tiny = try #require(TranscriptSpend.total(of: url, chunk: 37, onRead: { _ in reads += 1 }))
    #expect(abs(tiny - whole) < 1e-9)
    // The file is read in pieces, never whole.
    let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    #expect(reads >= size / 37)
  }

  @Test func aHugeLineIsSkippedWithoutBeingHeld() throws {
    let huge = #"{"type":"user","message":{"role":"user","content":""# + String(repeating: "x", count: 200_000) + #""}}"#
    let url = try write([Self.lines[1], huge, Self.lines[3]])
    defer { try? FileManager.default.removeItem(at: url) }
    var timeline = SessionTimeline(root: nil)
    timeline.ingest(lines: [Self.lines[1], Self.lines[3]])
    // A limit far under the line: it is dropped, and the lines around it still count.
    let total = try #require(TranscriptSpend.total(of: url, chunk: 4096, lineLimit: 50_000))
    #expect(abs(total - timeline.usage.cost) < 1e-9)
  }

  static func usageLine(_ id: String) -> String {
    #"{"type":"assistant","uuid":"u\#(id)","message":{"id":"\#(id)","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":10,"cache_read_input_tokens":4000,"cache_creation_input_tokens":200,"output_tokens":50}}}"#
  }

  /// A transcript of `megabytes` MB made of small usage lines among big ones, written a megabyte at a time into the temp folder.
  private func writeLarge(megabytes: Int) throws -> (url: URL, size: Int, messages: Int) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-large-\(UUID().uuidString).jsonl")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let filler = String(repeating: "x", count: 8_000)
    var messages = 0
    for block in 0..<megabytes {
      var text = ""
      var lines = 0
      while text.utf8.count < 1 << 20 {
        let id = "m\(block)-\(lines)"
        text += Self.usageLine(id) + "\n"
        text += #"{"type":"user","uuid":"b\#(id)","message":{"role":"user","content":"\#(filler)"}}"# + "\n"
        lines += 1
        messages += 1
      }
      try handle.write(contentsOf: Data(text.utf8))
    }
    return (url, (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0, messages)
  }

  /// Counts how many of its instances are alive.
  private final class Marker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    static var alive: Int { lock.lock(); defer { lock.unlock() }; return count }
    init() { Self.lock.lock(); Self.count += 1; Self.lock.unlock() }
    deinit { Self.lock.lock(); Self.count -= 1; Self.lock.unlock() }
  }

  /// The scan's memory is measured by what its autorelease pools do, not by the process's resident size (which other suites
  /// running alongside move by hundreds of MB). `onRead` is called inside the chunk's pool, so an object it autoreleases
  /// lives until that chunk ends: with a pool per chunk at most the current one's is alive, however large the file; without
  /// pools every chunk's stays until the scan returns, which is how a 398 MB file held 406 MB.
  @Test func eachChunkOfALargeTranscriptIsReadInItsOwnAutoreleasePool() throws {
    let file = try writeLarge(megabytes: 20)
    defer { try? FileManager.default.removeItem(at: file.url) }
    var reads = 0
    var highest = 0
    let total = try #require(TranscriptSpend.total(of: file.url, chunk: 64 << 10, onRead: { _ in
      reads += 1
      _ = Unmanaged.passRetained(Marker()).autorelease()
      highest = max(highest, Marker.alive)
    }))
    #expect(reads >= 300)
    #expect(highest <= 2, "\(highest) chunks' objects were alive at once over \(reads) reads: the chunks are not each in a pool")
    // And the answer at this size is the right one: every message counted once.
    let one = try #require(TranscriptSpend.cost(line: Data(Self.usageLine("m").utf8)))
    #expect(abs(total - one.cost * Double(file.messages)) < 1e-6 * total)
  }

  @Test func aCancelledScanStopsAndSaysNothing() throws {
    let url = try write(Self.lines)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(TranscriptSpend.total(of: url, isCancelled: { true }) == nil)
  }

  @Test func aMissingFileHasNoSpend() {
    #expect(TranscriptSpend.total(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")) == nil)
  }
}

@Suite struct TerminalProgramTests {
  @Test func aShellIsAShellWhateverItsLoginDash() {
    #expect(TerminalProgram.state(executable: "/bin/zsh", arguments: ["-zsh"], loginShell: "/bin/zsh") == .shell)
    #expect(TerminalProgram.state(executable: "/opt/homebrew/bin/fish", arguments: ["fish"], loginShell: nil) == .shell)
    #expect(TerminalProgram.state(executable: "/usr/local/bin/mysh", arguments: ["-mysh"], loginShell: "/usr/local/bin/mysh") == .shell)
  }

  @Test func claudeAndOtherProgramsAreNotAShell() {
    #expect(TerminalProgram.state(executable: "/Users/me/.local/share/claude/versions/2.1.285", arguments: ["claude"],
                                  loginShell: "/bin/zsh") == .running("claude"))
    #expect(TerminalProgram.state(executable: "/usr/bin/vim", arguments: ["vim", "notes.md"], loginShell: "/bin/zsh") == .running("vim"))
  }

  @Test func aProgramThatCantBeReadIsUnknown() {
    #expect(TerminalProgram.state(executable: nil, arguments: [], loginShell: "/bin/zsh") == .unknown)
  }

  @Test func onlyAShellTakesTypedText() throws {
    #expect(TerminalProgram.refusal(.shell, action: "resuming") == nil)
    for state in [TerminalProgram.State.running("claude"), .running("vim"), .unknown] {
      let reason = try #require(TerminalProgram.refusal(state, action: "resuming"))
      #expect(reason.contains("resuming"))
    }
    #expect(TerminalProgram.refusal(.running("claude"), action: "starting")?.contains("Claude") == true)
  }
}

@Suite struct DigestWithoutARecapTests {
  @Test func anEmptyFirstPromptKeepsItsEmptyTextAsBefore() throws {
    // Outside a recap nothing about the first prompt changes: a prompt with no text of its own (a Razor selection sent alone)
    // stays the first prompt, as it always did.
    let selection = #"{"type":"user","cwd":"/a","message":{"role":"user","content":"[Razor Code: a.ts, line 3 selected] "}}"#
    let text = #"{"type":"user","cwd":"/a","message":{"role":"user","content":"Fix the login bug"}}"#
    let digest = TranscriptDigest.make(data: Data((selection + "\n" + text + "\n").utf8), root: "/a")
    #expect(digest.turns == 2)
    #expect(digest.firstPrompt == "")
  }
}
