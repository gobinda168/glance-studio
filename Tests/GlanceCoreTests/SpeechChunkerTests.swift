import Foundation
import Testing
@testable import GlanceCore

@Suite struct SpeechChunkerTests {
  private let rate = Double(SpeechChunker.sampleRate)

  private func tone(_ seconds: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(sin(Double($0) * 2 * .pi * 220 / rate) * 0.2) }
  }

  private func quiet(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * rate))
  }

  @Test func silenceGivesNothing() {
    var chunker = SpeechChunker()
    #expect(chunker.append(quiet(30)).isEmpty)
    #expect(chunker.flush() == nil)
  }

  @Test func cutsAtAPauseAfterEnoughSpeech() {
    var chunker = SpeechChunker()
    let chunks = chunker.append(quiet(2) + tone(2) + quiet(1) + tone(1.5) + quiet(1))
    #expect(chunks.count == 2)
    let first = chunks[0]
    // Starts ~0.2 s before the speech at 2 s, ends ~0.2 s after it at 4 s.
    #expect(abs(first.startSeconds - 1.8) < 0.05)
    #expect(abs(first.endSeconds - 4.2) < 0.05)
    #expect(abs(chunks[1].startSeconds - 4.8) < 0.05)
    #expect(abs(chunks[1].endSeconds - 6.7) < 0.05)
  }

  @Test func shortBlipsWaitForMoreSpeech() {
    var chunker = SpeechChunker()
    // 0.3 s of speech then a pause: under a second of speech, so no cut yet.
    #expect(chunker.append(tone(0.3) + quiet(0.8)).isEmpty)
    let chunks = chunker.append(tone(1) + quiet(1))
    #expect(chunks.count == 1)
    #expect(chunks[0].startSeconds < 0.05)
  }

  @Test func longSpeechIsCutAtTheMaximum() {
    var chunker = SpeechChunker()
    let chunks = chunker.append(tone(30))
    #expect(chunks.count == 2)
    #expect(chunks.allSatisfy { $0.samples.count <= 14 * SpeechChunker.sampleRate })
    // Contiguous: nothing lost between pieces.
    #expect(chunks[1].start == chunks[0].start + chunks[0].samples.count)
    let rest = chunker.flush()
    #expect(rest != nil)
    #expect(rest!.start == chunks[1].start + chunks[1].samples.count)
  }

  @Test func feedsInSmallPiecesLikeAMicrophone() {
    var chunker = SpeechChunker()
    let signal = quiet(1) + tone(2) + quiet(1)
    var chunks: [SpeechChunker.Chunk] = []
    for start in stride(from: 0, to: signal.count, by: 1600) {
      chunks += chunker.append(Array(signal[start..<min(signal.count, start + 1600)]))
    }
    #expect(chunks.count == 1)
    #expect(abs(chunks[0].startSeconds - 0.8) < 0.05)
  }

  @Test func flushKeepsTrailingSpeech() {
    var chunker = SpeechChunker()
    #expect(chunker.append(quiet(1) + tone(0.5)).isEmpty)
    let rest = chunker.flush()
    #expect(rest != nil)
    #expect(abs(rest!.startSeconds - 0.8) < 0.05)
    #expect(chunker.flush() == nil)
  }
}
