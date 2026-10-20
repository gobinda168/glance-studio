import AVFoundation
import GlanceCore

/// Plays voice samples in Settings: a provider's hosted sample (free), a synthesized preview, or a Mac voice. It says
/// when something starts and stops playing, for the Voice preview's orb.
@MainActor
final class SamplePlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
  private var player: AVAudioPlayer?
  private let synthesizer = AVSpeechSynthesizer()
  private var download: Task<Void, Never>?
  /// True while a sample plays.
  var onPlayingChange: ((Bool) -> Void)?

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func play(url: URL) {
    stop()
    download = Task {
      guard let data = try? await URLSession.shared.data(from: url).0, !Task.isCancelled else { return }
      start(data)
    }
  }

  /// A cloud preview: 16-bit mono PCM wrapped as WAV.
  func play(audio: SpeechAudio) {
    stop()
    start(PCM.wav(int16LE: audio.pcm, sampleRate: Int(audio.sampleRate)))
  }

  /// A local preview that is already a WAV file (Kokoro).
  func play(wav data: Data) {
    stop()
    start(data)
  }

  func speak(_ text: String, voice identifier: String?) {
    stop()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
    utterance.rate = 0.52
    synthesizer.speak(utterance)
    onPlayingChange?(true)
  }

  func stop() {
    download?.cancel()
    player?.stop()
    synthesizer.stopSpeaking(at: .immediate)
    onPlayingChange?(false)
  }

  private func start(_ data: Data) {
    player = try? AVAudioPlayer(data: data)
    player?.delegate = self
    let started = player?.play() ?? false
    onPlayingChange?(started)
  }

  // MARK: The end of a sample

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.onPlayingChange?(false) } }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.onPlayingChange?(false) } }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    DispatchQueue.main.async { MainActor.assumeIsolated { self.onPlayingChange?(false) } }
  }
}
