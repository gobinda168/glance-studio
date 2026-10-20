import AVFoundation
import GlanceCore

enum AudioBuffers {
  /// 16-bit LE mono PCM as float buffers of about half a second, so pause and the level meter stay responsive.
  static func make(pcm: Data, sampleRate: Double) -> [AVAudioPCMBuffer] {
    make(floats: PCM.floats(int16LE: pcm), sampleRate: sampleRate)
  }

  /// Mono float samples (-1…1) as buffers of about half a second.
  static func make(floats: [Float], sampleRate: Double) -> [AVAudioPCMBuffer] {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return [] }
    return PCM.chunks(floats, size: Int(sampleRate / 2)).compactMap { chunk in
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)),
        let channel = buffer.floatChannelData?[0]
      else { return nil }
      buffer.frameLength = AVAudioFrameCount(chunk.count)
      chunk.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: chunk.count) }
      return buffer
    }
  }

  /// Resamples buffers to `format`. One converter runs across all of them so no samples are lost at the joins.
  static func convert(_ buffers: [AVAudioPCMBuffer], to format: AVAudioFormat) -> [AVAudioPCMBuffer] {
    guard let first = buffers.first, first.format != format,
      let converter = AVAudioConverter(from: first.format, to: format)
    else { return buffers }
    return buffers.compactMap { buffer in
      let ratio = format.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
      guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
      var supplied = false
      var error: NSError?
      converter.convert(to: output, error: &error) { _, status in
        if supplied {
          status.pointee = .noDataNow
          return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
      }
      return error == nil && output.frameLength > 0 ? output : nil
    }
  }

  static func bytes(_ buffers: [AVAudioPCMBuffer]) -> Int {
    buffers.reduce(0) { $0 + Int($1.frameLength) * Int($1.format.channelCount) * 4 }
  }
}

/// Recently played cloud audio, so replays and resuming cost nothing. The least recently used entry goes first once
/// the cache passes its limit (about 5 minutes of 24 kHz audio by default).
@MainActor
final class AudioCache {
  private var entries: [String: [AVAudioPCMBuffer]] = [:]
  private var order: [String] = []
  private var bytes = 0
  private let limit: Int

  init(limit: Int = 30 << 20) {
    self.limit = limit
  }

  static func key(provider: ProviderID, voice: String, model: String, text: String) -> String {
    "\(provider.rawValue)|\(voice)|\(model)|\(text)"
  }

  func contains(_ key: String) -> Bool { entries[key] != nil }

  func get(_ key: String) -> [AVAudioPCMBuffer]? {
    guard let buffers = entries[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return buffers
  }

  func put(_ key: String, _ buffers: [AVAudioPCMBuffer]) {
    if let old = entries[key] {
      bytes -= AudioBuffers.bytes(old)
      order.removeAll { $0 == key }
    }
    entries[key] = buffers
    order.append(key)
    bytes += AudioBuffers.bytes(buffers)
    while bytes > limit, order.count > 1 {
      let oldest = order.removeFirst()
      bytes -= entries.removeValue(forKey: oldest).map(AudioBuffers.bytes) ?? 0
    }
  }
}
