/// Cuts a channel's 16 kHz mono samples into pieces of speech to transcribe while the meeting goes on (spec
/// 2026-10-09-meeting-notes-design.md, "SpeechChunker"). A piece ends after `pause` of quiet once it holds
/// `minSpeech` of speech, or at `maxLength` on the quietest frame of its last 2 s. Quiet with no speech is dropped.
public struct SpeechChunker: Sendable {
  public struct Chunk: Equatable, Sendable {
    /// The first sample's index since the recording started.
    public let start: Int
    public let samples: [Float]

    public var startSeconds: Double { Double(start) / Double(SpeechChunker.sampleRate) }
    public var endSeconds: Double { Double(start + samples.count) / Double(SpeechChunker.sampleRate) }
  }

  public static let sampleRate = 16_000
  /// 30 ms frames decide speech or quiet.
  static let frame = 480

  public var threshold: Float
  public let minSpeech: Int
  public let pause: Int
  public let maxLength: Int
  /// Quiet kept before the first speech and after the last, so words aren't clipped.
  public let pad: Int

  /// Samples not yet given out; `buffer[0]` is sample `bufferStart`.
  private var buffer: [Float] = []
  private var bufferStart = 0
  /// Analysed frames of `buffer`: speech or not.
  private var frames: [Bool] = []
  private var frameLevels: [Float] = []

  public init(threshold: Float = 0.012, minSpeech: Double = 1.0, pause: Double = 0.6, maxLength: Double = 14,
              pad: Double = 0.2) {
    self.threshold = threshold
    self.minSpeech = Int(minSpeech * Double(Self.sampleRate))
    self.pause = Int(pause * Double(Self.sampleRate))
    self.maxLength = Int(maxLength * Double(Self.sampleRate))
    self.pad = Int(pad * Double(Self.sampleRate))
  }

  /// Takes more samples and returns the pieces they complete.
  public mutating func append(_ samples: [Float]) -> [Chunk] {
    buffer.append(contentsOf: samples)
    while (frames.count + 1) * Self.frame <= buffer.count {
      let from = frames.count * Self.frame
      let level = Self.rms(buffer[from..<(from + Self.frame)])
      frameLevels.append(level)
      frames.append(level >= threshold)
    }
    var out: [Chunk] = []
    while let chunk = nextChunk() { out.append(chunk) }
    return out
  }

  /// At Stop: whatever speech is left, as one last piece.
  public mutating func flush() -> Chunk? {
    defer {
      bufferStart += buffer.count
      buffer.removeAll()
      frames.removeAll()
      frameLevels.removeAll()
    }
    guard let first = frames.firstIndex(of: true), let last = frames.lastIndex(of: true),
          frames[first...last].filter({ $0 }).count >= 5 else { return nil }
    let from = max(0, first - padFrames) * Self.frame
    let to = min(buffer.count, (last + 1 + padFrames) * Self.frame)
    return Chunk(start: bufferStart + from, samples: Array(buffer[from..<to]))
  }

  private var padFrames: Int { pad / Self.frame }

  private mutating func nextChunk() -> Chunk? {
    // Drop leading quiet, keeping `pad` of it.
    guard let first = frames.firstIndex(of: true) else {
      if frames.count > padFrames { drop(frames: frames.count - padFrames) }
      return nil
    }
    if first > padFrames { drop(frames: first - padFrames) }
    let pauseFrames = pause / Self.frame
    var speech = 0
    var quietRun = 0
    for (index, isSpeech) in frames.enumerated() {
      if isSpeech {
        speech += 1
        quietRun = 0
      } else {
        quietRun += 1
      }
      if !isSpeech, quietRun >= pauseFrames, speech * Self.frame >= minSpeech {
        return cut(frames: min(index + 1, index + 1 - quietRun + padFrames))
      }
      if (index + 1) * Self.frame >= maxLength {
        // Too long: cut at the quietest frame of the last 2 s.
        let window = max(0, index - (2 * Self.sampleRate) / Self.frame)
        let quietest = (window...index).min { frameLevels[$0] < frameLevels[$1] } ?? index
        return cut(frames: quietest + 1)
      }
    }
    return nil
  }

  private mutating func cut(frames count: Int) -> Chunk {
    let chunk = Chunk(start: bufferStart, samples: Array(buffer[0..<(count * Self.frame)]))
    drop(frames: count)
    return chunk
  }

  private mutating func drop(frames count: Int) {
    buffer.removeFirst(count * Self.frame)
    bufferStart += count * Self.frame
    frames.removeFirst(count)
    frameLevels.removeFirst(count)
  }

  static func rms(_ samples: ArraySlice<Float>) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples { sum += sample * sample }
    return (sum / Float(samples.count)).squareRoot()
  }
}
