@preconcurrency import AVFoundation
import GlanceCore

/// 16 kHz mono Float32, what Parakeet and the diarizer read and what the meeting's CAF files hold.
enum MeetingAudioFormat {
  static let sampleRate = Double(SpeechChunker.sampleRate)
  static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                                    interleaved: false)!
}

/// Any capture format to 16 kHz mono samples. Used from one audio thread at a time.
final class MonoResampler: @unchecked Sendable {
  private let converter: AVAudioConverter
  private let input: AVAudioFormat

  init?(from input: AVAudioFormat) {
    guard let converter = AVAudioConverter(from: input, to: MeetingAudioFormat.format) else { return nil }
    // Mix every channel down rather than keeping the first.
    converter.downmix = input.channelCount > 1
    self.converter = converter
    self.input = input
  }

  func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
    let ratio = MeetingAudioFormat.sampleRate / input.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
    guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: capacity)
    else { return [] }
    var supplied = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if supplied {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let channel = out.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
  }

  /// The RMS level of a capture buffer's first channel, for the live page's meters.
  static func level(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
    return (sum / Float(buffer.frameLength)).squareRoot()
  }
}

/// A meeting channel's CAF file, appended off the main thread.
final class MeetingAudioFile: @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.glance.meeting-audio-file")
  private var file: AVAudioFile?

  init(url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    file = try AVAudioFile(forWriting: url, settings: MeetingAudioFormat.format.settings,
                           commonFormat: .pcmFormatFloat32, interleaved: false)
  }

  func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    queue.async { [self] in
      guard let file,
            let buffer = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format,
                                          frameCapacity: AVAudioFrameCount(samples.count)) else { return }
      buffer.frameLength = AVAudioFrameCount(samples.count)
      samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
      try? file.write(from: buffer)
    }
  }

  /// Writes what's queued and closes the file.
  func close() {
    queue.sync { file = nil }
  }

  /// A finished file's samples, 16 kHz mono.
  static func samples(at url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
    else { return [] }
    try file.read(into: buffer)
    if file.processingFormat.sampleRate == MeetingAudioFormat.sampleRate, file.processingFormat.channelCount == 1,
       let channel = buffer.floatChannelData?[0] {
      return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
    return MonoResampler(from: file.processingFormat)?.convert(buffer) ?? []
  }
}

/// A meeting's live sound level per channel, read by the live page.
final class MeetingLevel: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Float = 0

  var value: Float {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// The microphone for a meeting (spec "MeetingMicrophone"): the default input, 16 kHz mono, handed to `onSamples` on
/// the audio thread. Started and stopped only on the recorder's capture queue, never the main thread.
final class MeetingMicrophone: @unchecked Sendable {
  enum Failure: Error { case noInput }

  let level = MeetingLevel()
  private var engine: AVAudioEngine?

  func start(onSamples: @escaping @Sendable ([Float]) -> Void) throws {
    stop()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0, let resampler = MonoResampler(from: format) else {
      throw Failure.noInput
    }
    let level = self.level
    // @Sendable: AVFAudio calls the tap on its own queue, where a main-actor closure traps (Swift 6).
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
      level.value = MonoResampler.level(buffer)
      onSamples(resampler.convert(buffer))
    }
    engine.prepare()
    try engine.start()
    self.engine = engine
  }

  func stop() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
    level.value = 0
  }
}
