import AVFoundation

/// Converts audio to what Scribe expects: 16 kHz, mono, 16-bit little-endian PCM. Safe to call from the
/// audio thread (one converter per stream, used serially).
final class PCM16Converter: @unchecked Sendable {
  static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
  /// About 100 ms of audio.
  static let chunkBytes = 3_200
  private let converter: AVAudioConverter

  init?(from source: AVAudioFormat) {
    guard let converter = AVAudioConverter(from: source, to: Self.format) else { return nil }
    self.converter = converter
  }

  /// `endOfStream` flushes the resampler; pass it for the last buffer of a file.
  func convert(_ buffer: AVAudioPCMBuffer, endOfStream: Bool = false) -> Data {
    let ratio = Self.format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
    guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return Data() }
    var supplied = false
    var error: NSError?
    _ = converter.convert(to: output, error: &error) { _, status in
      if supplied {
        status.pointee = endOfStream ? .endOfStream : .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let samples = output.int16ChannelData, output.frameLength > 0 else { return Data() }
    return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
  }
}
