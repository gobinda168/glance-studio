import Foundation
import GlanceCore

extension Narrator {
  /// Sets this narrator up with the voice chosen in Settings → Voice: the cloud voice when it has a key, Kokoro unless
  /// the Mac voice was chosen, and the Mac voice last. Returns the cloud provider and its voice's name, nil without one.
  /// The pane's session and the meeting nudge's voice both use it, so they always sound the same.
  func useChosenVoice(cache: AudioCache) -> (provider: SpeechProvider, name: String)? {
    system.voice = MacVoices.best(preferred: Prefs.macVoice)
    let choice = Prefs.narrationVoice
    kokoro = choice == .mac ? nil : KokoroVoice.shared
    kokoroVoice = Prefs.kokoroVoice.id
    budget.reset()
    guard case .cloud(let id) = choice, let key = SpeechProviders.key(for: id) else {
      cloud = nil
      return nil
    }
    let provider = SpeechProviders.make(id, key: key)
    let voice = Prefs.voice(for: id)
    cloud = CloudVoice(provider: provider, voice: voice.id, model: Prefs.model(for: id), cache: cache)
    return (provider, "\(voice.name) (\(id.displayName))")
  }
}
