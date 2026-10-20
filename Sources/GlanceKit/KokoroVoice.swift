import AVFoundation
import FluidAudio
import GlanceCore

/// Kokoro-82M on this Mac, through FluidAudio's Core ML pipeline (shown as "Glance Voice"). It loads on first use and
/// is freed after a few idle minutes, then loads again on the next request. One shared instance serves narration and
/// Settings previews, so the model is in memory at most once.
@MainActor
final class KokoroVoice {
  static let shared = KokoroVoice()

  /// Why Kokoro couldn't load. Set by the first failed load; later requests fail straight away with it.
  private(set) var loadFailure: String?
  private var manager: KokoroAneManager?
  private var loading: Task<KokoroAneManager, Error>?
  private lazy var idle = IdleRelease(after: .seconds(180)) { [weak self] in await self?.unload() }

  /// Loads the model now (Settings and `voice-check` time it). Narration loads on its first paragraph.
  func prepare() async throws {
    idle.begin()
    defer { idle.end() }
    _ = try await loaded()
  }

  /// One paragraph as playable 24 kHz buffers. Long text is chunked inside FluidAudio.
  func audio(for text: String, voice: String) async throws -> [AVAudioPCMBuffer] {
    idle.begin()
    defer { idle.end() }
    let result = try await loaded().synthesizeDetailed(text: text, voice: voice)
    return AudioBuffers.make(floats: result.samples, sampleRate: Double(result.sampleRate))
  }

  /// A short preview as a WAV file's bytes.
  func wav(for text: String, voice: String) async throws -> Data {
    idle.begin()
    defer { idle.end() }
    return try await loaded().synthesize(text: text, voice: voice)
  }

  /// Drops the models and voice packs. The next request loads them again.
  private func unload() async {
    guard let manager else { return }
    self.manager = nil
    loading = nil
    await manager.cleanup()
  }

  private func loaded() async throws -> KokoroAneManager {
    if let manager { return manager }
    if let loadFailure { throw TTSFailure.unavailable(loadFailure) }
    let task = loading ?? Task { try await Self.load() }
    loading = task
    do {
      let manager = try await task.value
      self.manager = manager
      return manager
    } catch {
      loading = nil
      let reason = "Glance Voice unavailable: \(error.localizedDescription)"
      loadFailure = reason
      throw TTSFailure.unavailable(reason)
    }
  }

  /// Copies the bundled model into FluidAudio's cache where it's missing, then loads from the cache. With every file
  /// present FluidAudio downloads nothing.
  nonisolated private static func load() async throws -> KokoroAneManager {
    let bundled = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Kokoro")
    try KokoroSeed.seed(bundle: bundled, cache: try TtsCacheDirectory.ensure().appendingPathComponent("Models"))
    let manager = KokoroAneManager()
    try await manager.initialize()
    return manager
  }
}
