import Foundation

/// 16-bit little-endian PCM, the format every cloud provider is asked for.
public enum PCM {
  /// Samples scaled to -1…1. A trailing odd byte is dropped.
  public static func floats(int16LE data: Data) -> [Float] {
    let count = data.count / 2
    var frames = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
      for i in 0..<count {
        let value = Int16(bitPattern: UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8)
        frames[i] = Float(value) / 32_768
      }
    }
    return frames
  }

  public static func chunks(_ frames: [Float], size: Int) -> [[Float]] {
    stride(from: 0, to: frames.count, by: size).map { Array(frames[$0..<min($0 + size, frames.count)]) }
  }

  /// A mono 16-bit WAV file, so AVAudioPlayer can play a preview.
  public static func wav(int16LE data: Data, sampleRate: Int) -> Data {
    let samples = data.prefix(data.count & ~1)
    var out = Data()
    func ascii(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
    ascii("RIFF"); u32(UInt32(36 + samples.count)); ascii("WAVE")
    ascii("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
    ascii("data"); u32(UInt32(samples.count))
    out.append(samples)
    return out
  }
}

/// Text shaping for cloud requests.
public enum SpeechText {
  /// Splits text longer than `limit` at sentence ends, else at spaces, else anywhere. 1,000 characters is about a
  /// minute of speech: well inside every provider's length limit and quick enough to arrive within the 15 s response
  /// timeout.
  public static func pieces(_ text: String, limit: Int = 1_000) -> [String] {
    var rest = Substring(text.trimmingCharacters(in: .whitespaces))
    var pieces: [String] = []
    while rest.count > limit {
      let window = rest.prefix(limit)
      let cut = window.lastIndex(where: { ".!?".contains($0) }).map { window.index(after: $0) }
        ?? window.lastIndex(of: " ")
        ?? window.endIndex
      pieces.append(rest[..<cut].trimmingCharacters(in: .whitespaces))
      rest = rest[cut...].drop { $0 == " " }
    }
    if !rest.isEmpty { pieces.append(String(rest)) }
    return pieces.filter { !$0.isEmpty }
  }

  /// The first sentence, cut to `limit` characters with an ellipsis: voice descriptions in Settings.
  public static func firstSentence(_ text: String, limit: Int = 60) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sentence = trimmed.firstIndex(where: { ".!?".contains($0) }).map { String(trimmed[...$0]) } ?? trimmed
    guard sentence.count > limit else { return sentence }
    return sentence.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
  }
}
