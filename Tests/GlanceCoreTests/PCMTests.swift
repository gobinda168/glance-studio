import Foundation
import Testing
@testable import GlanceCore

@Suite struct PCMTests {
  @Test func convertsInt16LittleEndianToUnitFloats() {
    // 0, Int16.min, Int16.max, 256 (bytes 00 01), then a stray odd byte that must be dropped.
    let data = Data([0x00, 0x00, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x01, 0x42])
    let frames = PCM.floats(int16LE: data)
    #expect(frames.count == 4)
    #expect(frames[0] == 0)
    #expect(frames[1] == -1)
    #expect(frames[2] == 32_767.0 / 32_768.0)
    #expect(frames[3] == 256.0 / 32_768.0)
    #expect(PCM.floats(int16LE: Data()).isEmpty)
  }

  @Test func chunksKeepEveryFrame() {
    let chunks = PCM.chunks(Array(repeating: 0.5, count: 25), size: 10)
    #expect(chunks.map(\.count) == [10, 10, 5])
    #expect(PCM.chunks([], size: 10).isEmpty)
  }

  @Test func wavHasA44ByteHeader() {
    let wav = PCM.wav(int16LE: Data([1, 2, 3, 4]), sampleRate: 24_000)
    #expect(wav.count == 48)
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
    #expect(Array(wav[24..<28]) == [0xC0, 0x5D, 0x00, 0x00])  // 24000 little-endian
    #expect(Array(wav[40..<44]) == [4, 0, 0, 0])              // data size
    #expect(Array(wav.suffix(4)) == [1, 2, 3, 4])
  }

  @Test func shortTextIsOnePiece() {
    #expect(SpeechText.pieces("Hello there.", limit: 50) == ["Hello there."])
    #expect(SpeechText.pieces("", limit: 50).isEmpty)
  }

  @Test func longTextSplitsAtSentenceEnds() {
    #expect(SpeechText.pieces("One. Two. Three.", limit: 10) == ["One. Two.", "Three."])
  }

  @Test func withoutSentencesItSplitsAtSpacesThenAnywhere() {
    #expect(SpeechText.pieces("aaaa bbbb cccc", limit: 10) == ["aaaa bbbb", "cccc"])
    #expect(SpeechText.pieces("abcdefghijkl", limit: 5) == ["abcde", "fghij", "kl"])
  }

  @Test func piecesNeverExceedTheLimit() {
    let text = String(repeating: "This sentence is about forty characters. ", count: 200)
    let pieces = SpeechText.pieces(text, limit: 2_500)
    #expect(pieces.allSatisfy { $0.count <= 2_500 })
    #expect(pieces.joined(separator: " ").count == text.trimmingCharacters(in: .whitespaces).count)
  }

  /// A whole response must arrive within 15 s, so no single request may carry minutes of audio.
  @Test func defaultPiecesStayShortEnoughToArriveInTime() {
    let text = String(repeating: "This sentence is about forty characters. ", count: 40)
    let pieces = SpeechText.pieces(text)
    #expect(pieces.count >= 2)
    #expect(pieces.allSatisfy { $0.count <= 1_000 })
  }

  @Test func firstSentenceIsShortened() {
    #expect(SpeechText.firstSentence("Warm and clear. Great for audiobooks.") == "Warm and clear.")
    #expect(SpeechText.firstSentence("  No full stop here  ") == "No full stop here")
    let long = String(repeating: "word ", count: 30)
    let cut = SpeechText.firstSentence(long, limit: 20)
    #expect(cut.count <= 20)
    #expect(cut.hasSuffix("…"))
  }
}
