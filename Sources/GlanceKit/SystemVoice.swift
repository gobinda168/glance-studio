import AVFoundation

/// The Mac's own voice, synthesized to buffers (not spoken) so `Narrator` plays it like any other audio.
@MainActor
final class SystemVoice {
  var voice: AVSpeechSynthesisVoice?
  var rate: Float = 0.52
  private let synthesizer = AVSpeechSynthesizer()

  func audio(for text: String) async -> [AVAudioPCMBuffer] {
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = rate
    return await withCheckedContinuation { continuation in
      let collector = BufferCollector(continuation)
      // @Sendable: the synthesizer calls back on its own queue, where a main-actor closure traps (Swift 6).
      synthesizer.write(utterance) { @Sendable buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { collector.finish() } else { collector.append(pcm) }
      }
      // Guard against a voice that never reports the end of its output.
      DispatchQueue.main.asyncAfter(deadline: .now() + 20) { collector.finish() }
    }
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
  }
}

/// Installed English voices, best first: premium, then enhanced, US English first, skipping the novelty voices.
/// `best` and the Settings popup share this order so they always agree.
public enum MacVoices {
  public static func english() -> [AVSpeechSynthesisVoice] {
    let novelty = ["speech.synthesis.voice", "eloquence"]
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { voice in voice.language.hasPrefix("en") && !novelty.contains { voice.identifier.contains($0) } }
      .sorted { rank($0) > rank($1) }
  }

  /// The preferred voice if installed, otherwise the best English voice.
  public static func best(preferred identifier: String?) -> AVSpeechSynthesisVoice? {
    if let identifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) { return voice }
    return english().first ?? AVSpeechSynthesisVoice(language: "en-US")
  }

  public static func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
    switch voice.quality {
    case .premium: "Premium"
    case .enhanced: "Enhanced"
    default: "Compact"
    }
  }

  public static var hasPremium: Bool { english().contains { $0.quality == .premium } }

  private static func rank(_ voice: AVSpeechSynthesisVoice) -> (Int, Int, Int) {
    (voice.quality.rawValue, voice.language == "en-US" ? 1 : 0, voice.name == "Samantha" ? 1 : 0)
  }
}

/// Gathers synthesized buffers (converted to the engine's float format) and resumes exactly once.
private final class BufferCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffers: [AVAudioPCMBuffer] = []
  private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

  init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
    self.continuation = continuation
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    guard let converted = Self.standardize(buffer) else { return }
    lock.lock()
    buffers.append(converted)
    lock.unlock()
  }

  func finish() {
    lock.lock()
    let pending = continuation
    continuation = nil
    let result = buffers
    lock.unlock()
    pending?.resume(returning: result)
  }

  /// Copies a synthesizer buffer (often 16-bit integer) into a deinterleaved float buffer the player accepts.
  private static func standardize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let source = buffer.format
    guard let target = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: source.channelCount),
      let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
      let converter = AVAudioConverter(from: source, to: target)
    else { return nil }
    do { try converter.convert(to: output, from: buffer) } catch { return nil }
    return output
  }
}
