import FluidAudio
import Foundation
import GlanceCore

/// The on-device speech models for meeting notes (spec 2026-10-09-meeting-notes-design.md, "Models: on demand
/// only"): Parakeet Ultra for the words and FluidAudio's offline diarizer for who said them. Nothing is bundled; the
/// first use downloads them into FluidAudio's cache. Parakeet stays loaded only while a meeting is being transcribed,
/// the diarizer only for its one pass.
public actor MeetingSpeechModels {
  public static let shared = MeetingSpeechModels()

  static let version: AsrModelVersion = .ultra
  private var asr: AsrManager?
  private var loading: Task<AsrManager, Error>?

  /// Where Parakeet Ultra lives once downloaded.
  public nonisolated static var transcriptionFolder: URL { AsrModels.defaultCacheDirectory(for: version) }
  /// Where the diarizer's models live once downloaded.
  public nonisolated static var speakerFolder: URL {
    OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
  }

  /// Parakeet is on this Mac, so recording needs no download.
  public nonisolated static var isDownloaded: Bool {
    AsrModels.modelsExist(at: transcriptionFolder, version: version)
  }

  /// The models' size on disk in bytes (both folders), 0 when nothing is downloaded.
  public nonisolated static func sizeOnDisk() -> Int64 {
    [transcriptionFolder, speakerFolder].reduce(0) { $0 + folderSize($1) }
  }

  /// Deletes both models; the next recording downloads them again.
  public nonisolated static func remove() throws {
    for folder in [transcriptionFolder, speakerFolder] where FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

  /// Downloads Parakeet when it's missing (reporting 0…1 and a phase), then loads it. Calls while it's loading share
  /// the one load.
  public func loadTranscription(progress: (@Sendable (Double, String) -> Void)? = nil) async throws {
    _ = try await transcriber(progress: progress)
  }

  private func transcriber(progress: (@Sendable (Double, String) -> Void)?) async throws -> AsrManager {
    if let asr { return asr }
    let task = loading ?? Task {
      let models = try await AsrModels.downloadAndLoad(version: Self.version) { update in
        progress?(update.fractionCompleted, Self.phase(update.phase))
      }
      let manager = AsrManager(config: .default)
      try await manager.loadModels(models)
      return manager
    }
    loading = task
    do {
      let manager = try await task.value
      asr = manager
      loading = nil
      return manager
    } catch {
      loading = nil
      throw error
    }
  }

  /// One chunk's words (16 kHz mono). Loads Parakeet first if needed. A chunk too short for the model is padded with
  /// quiet.
  public func transcribe(_ samples: [Float]) async throws -> String {
    let manager = try await transcriber(progress: nil)
    var audio = samples
    let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: SpeechChunker.sampleRate) + 1600
    if audio.count < minimum { audio += [Float](repeating: 0, count: minimum - audio.count) }
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(audio, decoderState: &state)
    return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Frees Parakeet: the next recording loads it again.
  public func releaseTranscription() async {
    loading?.cancel()
    loading = nil
    guard let asr else { return }
    self.asr = nil
    await asr.cleanup()
  }

  /// Who spoke when in a finished recording (16 kHz mono file). The diarizer is downloaded if missing, loaded for this
  /// one pass, and dropped after.
  public func speakers(in url: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [SpeakerLabels.Span] {
    let manager = OfflineDiarizerManager(config: .default)
    try await manager.prepareModels()
    let result = try await manager.process(url) { done, total in
      progress?(total > 0 ? Double(done) / Double(total) : 0)
    }
    return result.segments.map {
      SpeakerLabels.Span(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
    }
  }

  private nonisolated static func phase(_ phase: DownloadPhase) -> String {
    switch phase {
    case .listing: "Finding the transcription model…"
    case .downloading: "Downloading the transcription model…"
    case .compiling: "Preparing the transcription model…"
    }
  }

  private nonisolated static func folderSize(_ folder: URL) -> Int64 {
    guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
    else { return 0 }
    var total: Int64 = 0
    for case let file as URL in files {
      total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
    }
    return total
  }
}
