import AVFoundation
import GlanceCore

/// A provider plus the chosen voice and model, with the cache in front.
@MainActor
final class CloudVoice {
  let provider: SpeechProvider
  let voice: String
  let model: String
  private let cache: AudioCache

  init(provider: SpeechProvider, voice: String, model: String, cache: AudioCache) {
    self.provider = provider
    self.voice = voice
    self.model = model
    self.cache = cache
  }

  func isCached(_ text: String) -> Bool { cache.contains(key(text)) }

  /// Audio for the text and the characters it cost (0 when cached). Text over the provider-safe length is sent in
  /// pieces. Throws `TTSFailure`.
  func audio(for text: String, previous: String?, next: String?) async throws
    -> (buffers: [AVAudioPCMBuffer], billed: Int) {
    let key = key(text)
    if let cached = cache.get(key) { return (cached, 0) }
    let pieces = SpeechText.pieces(text)
    var buffers: [AVAudioPCMBuffer] = []
    var billed = 0
    for (index, piece) in pieces.enumerated() {
      let audio = try await provider.synthesize(
        piece, voice: voice, model: model,
        previous: index == 0 ? previous : pieces[index - 1],
        next: index == pieces.count - 1 ? next : pieces[index + 1])
      buffers += AudioBuffers.make(pcm: audio.pcm, sampleRate: audio.sampleRate)
      billed += audio.charactersBilled
    }
    cache.put(key, buffers)
    return (buffers, billed)
  }

  private func key(_ text: String) -> String {
    AudioCache.key(provider: provider.id, voice: voice, model: model, text: text)
  }
}
