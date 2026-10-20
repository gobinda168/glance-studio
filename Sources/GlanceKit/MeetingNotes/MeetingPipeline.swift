import Foundation
import GlanceCore

/// The steps a recording goes through, shared by the live recorder, Transcribe on a saved meeting, and `glance
/// meeting-check`: chunks to words, then the echo filter and the speakers.
public enum MeetingPipeline {
  /// A whole channel's samples to transcript lines, chunk by chunk.
  public static func transcribe(_ samples: [Float], channel: TranscriptLine.Channel,
                                models: MeetingSpeechModels = .shared,
                                progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptLine] {
    var chunker = SpeechChunker()
    var chunks: [SpeechChunker.Chunk] = []
    let step = SpeechChunker.sampleRate
    var index = 0
    while index < samples.count {
      chunks += chunker.append(Array(samples[index..<min(samples.count, index + step)]))
      index += step
    }
    if let last = chunker.flush() { chunks.append(last) }
    var lines: [TranscriptLine] = []
    for (number, chunk) in chunks.enumerated() {
      let text = try await models.transcribe(chunk.samples)
      if !text.isEmpty {
        lines.append(TranscriptLine(channel: channel, start: chunk.startSeconds, end: chunk.endSeconds, text: text))
      }
      progress?(Double(number + 1) / Double(chunks.count))
    }
    return lines
  }

  /// After the words: drops the call's echo on the mic and names the call's speakers from `systemAudio` (skipped when
  /// the call channel said little, or when the diarizer fails: the lines then stay "Others").
  public static func label(_ lines: [TranscriptLine], systemAudio: URL?, models: MeetingSpeechModels = .shared,
                           progress: (@Sendable (Double) -> Void)? = nil) async -> [TranscriptLine] {
    let kept = EchoFilter.filter(lines)
    guard let systemAudio, FileManager.default.fileExists(atPath: systemAudio.path),
          kept.filter({ $0.channel == .system }).count >= 2,
          let spans = try? await models.speakers(in: systemAudio, progress: progress)
    else { return kept }
    return SpeakerLabels.assign(kept, spans: spans)
  }
}
