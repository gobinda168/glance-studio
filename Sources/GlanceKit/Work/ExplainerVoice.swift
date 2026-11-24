import AVFoundation
import Foundation
import GlanceCore

/// The voice of Make explainer: always Glance Voice (Kokoro, on this Mac), whichever voice the user has picked for
/// Glance's own speech, so a film is never narrated by a cloud provider behind their back.
public enum ExplainerVoice {
  /// The rate of the narration the renderer joins and muxes.
  static let sampleRate = 24_000

  /// `say` as a WAV and its length. `voice` is a Kokoro voice id; nil is the user's chosen one (`Prefs.kokoroVoice`).
  /// Throws what Kokoro throws (it can't load, it refuses the text).
  public static func wav(say: String, voice: String?) async throws -> (data: Data, ms: Int) {
    let id = voice ?? Prefs.kokoroVoice.id
    let data = try await KokoroVoice.shared.wav(for: say, voice: id)
    return (data, milliseconds(of: try samples(fromWAV: data)))
  }

  static func milliseconds(of samples: [Float]) -> Int { samples.count * 1000 / sampleRate }

  /// A WAV file's bytes as 24 kHz mono samples, resampled and down-mixed when it is something else.
  static func samples(fromWAV data: Data) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("explainer-voice-\(UUID().uuidString).wav")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
    guard file.length > 0 else { return [] }
    guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
      throw Failure.unreadable
    }
    try file.read(into: input)
    if file.processingFormat == target { return floats(input) }

    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw Failure.unreadable }
    let capacity = AVAudioFrameCount(Double(input.frameLength) * target.sampleRate / file.processingFormat.sampleRate) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure.unreadable }
    var supplied = false
    var failure: NSError?
    let status = converter.convert(to: output, error: &failure) { _, inputStatus in
      if supplied { inputStatus.pointee = .endOfStream; return nil }
      supplied = true
      inputStatus.pointee = .haveData
      return input
    }
    if status == .error { throw failure ?? Failure.unreadable }
    return floats(output)
  }

  enum Failure: Error, LocalizedError {
    case unreadable
    var errorDescription: String? { "the voice's audio couldn't be read" }
  }

  private static func floats(_ buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }
}
