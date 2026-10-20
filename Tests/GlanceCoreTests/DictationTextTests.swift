import Testing
@testable import GlanceCore

@Suite struct DictationTextTests {
  @Test func finalizeNeverLeavesANewline() {
    // A newline typed into Claude Code's prompt would press Return and send it.
    #expect(DictationText.finalize("  Rename the hook.\nThen run tests.\r\n ") == "Rename the hook. Then run tests.")
    #expect(DictationText.finalize("a\t\tb") == "a b")
    #expect(DictationText.finalize(" \n ") == "")
  }

  @Test func chunksRespectTheLimitAndJoinBack() {
    let text = "Explain how React Fiber schedules work"
    let chunks = DictationText.chunks(text, maxUTF16: 10)
    #expect(chunks.joined() == text)
    #expect(chunks.allSatisfy { $0.utf16.count <= 10 })
  }

  @Test func chunksNeverSplitACharacter() {
    let text = "ok 👍🏽 done 🇮🇳 café"
    let chunks = DictationText.chunks(text, maxUTF16: 4)
    #expect(chunks.joined() == text)
    #expect(chunks.contains("👍🏽"))   // a 4-unit emoji with skin tone stays whole
    #expect(chunks.contains { $0.contains("🇮🇳") })
  }
}
