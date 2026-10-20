import AVFoundation

/// The default microphone as 16 kHz mono 16-bit PCM in ~100 ms chunks, plus a live level for the pill.
@MainActor
final class MicStream {
  enum Failure: Error { case noInput }

  var onChunk: ((Data) -> Void)?
  let level = LevelMeter()
  private var engine: AVAudioEngine?
  private var pending = Data()

  static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
  static func requestPermission() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

  /// A fresh engine per hold picks up the current input device.
  func start() throws {
    stop()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0, let converter = PCM16Converter(from: format) else {
      throw Failure.noInput
    }
    let level = self.level
    // @Sendable: AVFAudio calls the tap on its own queue, where a main-actor closure traps (Swift 6).
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable [weak self] buffer, _ in
      level.value = Self.rms(buffer)
      let data = converter.convert(buffer)
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.append(data) } }
    }
    engine.prepare()
    try engine.start()
    self.engine = engine
  }

  /// Stops capturing and returns the audio not yet handed out (under one chunk).
  @discardableResult
  func stop() -> Data {
    guard let engine else { return Data() }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    level.value = 0
    let rest = pending
    pending = Data()
    return rest
  }

  private func append(_ data: Data) {
    guard engine != nil else { return }
    pending.append(data)
    while pending.count >= PCM16Converter.chunkBytes {
      onChunk?(Data(pending.prefix(PCM16Converter.chunkBytes)))
      pending = Data(pending.dropFirst(PCM16Converter.chunkBytes))
    }
  }

  nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
    return (sum / Float(buffer.frameLength)).squareRoot()
  }
}
