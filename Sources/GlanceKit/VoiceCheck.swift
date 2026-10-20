import Foundation
import GlanceCore

/// `glance voice-check <elevenlabs|minimax> [text]`: lists voices and synthesizes one sentence with the saved key
/// and the chosen voice and model, so a provider can be checked without the panel. Costs about 20 characters.
public enum VoiceCheckCommand {
  public static func run(_ arguments: [String]) -> Int32 {
    if arguments.first == "kokoro" {
      let typed = arguments.dropFirst().joined(separator: " ")
      let text = typed.isEmpty ? "Hello from Glance. This voice runs on your Mac." : typed
      return MainActor.assumeIsolated { DebugCommands.kokoroCheck(text) }
    }
    guard let name = arguments.first, let id = ProviderID(rawValue: name) else {
      print("usage: glance voice-check <\((ProviderID.allCases.map(\.rawValue) + ["kokoro"]).joined(separator: "|"))> [text]")
      return 2
    }
    guard let key = SpeechProviders.key(for: id) else {
      print("No \(id.displayName) key saved. Add it in Glance Settings.")
      return 1
    }
    let typed = arguments.dropFirst().joined(separator: " ")
    let text = typed.isEmpty ? "Hello from Glance." : typed
    let provider = SpeechProviders.make(id, key: key)
    let done = DispatchSemaphore(value: 0)
    let outcome = Outcome()
    Task.detached {
      defer { done.signal() }
      do {
        let voices = try await provider.voices()
        print("voices: \(voices.count), e.g. \(voices.prefix(3).map(\.name).joined(separator: ", "))")
        let started = Date()
        let audio = try await provider.synthesize(text, voice: Prefs.voice(for: id).id, model: Prefs.model(for: id),
                                                  previous: nil, next: nil)
        print(String(format: "speech: %.2f s, %d bytes at %.0f Hz, %d characters billed",
                     Date().timeIntervalSince(started), audio.pcm.count, audio.sampleRate, audio.charactersBilled))
        print("usage: " + UsageLine.text(await provider.usage(), sessionCharacters: audio.charactersBilled))
      } catch {
        print("failed: " + ((error as? TTSFailure)?.message(provider: id.displayName) ?? error.localizedDescription))
        outcome.status = 1
      }
    }
    done.wait()
    return outcome.status
  }

  /// The detached task's exit status; read only after the semaphore, so no data race.
  private final class Outcome: @unchecked Sendable {
    var status: Int32 = 0
  }
}
