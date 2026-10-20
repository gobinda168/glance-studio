import Foundation
import GlanceCore

/// Makes and keeps session summaries (spec 2026-10-11-humanize-summaries-design.md, "Summary engine"). Everything is
/// keyed by session id: a run that ends after the user moved to another terminal is saved for its own session.
@MainActor
public final class SummaryService {
  public static let shared = SummaryService()

  public enum State: Equatable {
    case none
    case working(SummaryRecord?)
    case ready(SummaryRecord, stale: Bool)
    case failed(String, SummaryRecord?)
  }

  /// A session's state changed (its id).
  public var onChange: ((String) -> Void)?
  public static let quietDelay: TimeInterval = 60

  private var jobs = SummaryJobs()
  /// What a queued rerun summarizes, by session.
  private var pending: [String: SessionLink] = [:]
  private var failures: [String: String] = [:]
  private var timers: [String: DispatchWorkItem] = [:]
  private var runs: [String: ClaudeOneShot.Run] = [:]

  private init() {
    NotificationCenter.default.addObserver(forName: SettingsModel.summaryModeDidChange, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { SummaryService.shared.cancelTimers() }
    }
  }

  public func state(for link: SessionLink) -> State {
    let saved = SummaryStore.load(link.sessionID)
    if jobs.isRunning(link.sessionID) { return .working(saved) }
    if let failure = failures[link.sessionID] { return .failed(failure, saved) }
    guard let saved else { return .none }
    return .ready(saved, stale: Self.fileSize(link.transcriptPath) > saved.coveredBytes)
  }

  public func request(_ link: SessionLink, trigger: SummaryTrigger) {
    Self.inspect(link) { [weak self] freshness in
      guard let self else { return }
      switch SummaryPolicy.step(mode: Prefs.summaryMode, trigger: trigger, freshness: freshness) {
      case .none, .show: self.onChange?(link.sessionID)
      case .generate(let incremental): self.generate(link, incremental: incremental)
      }
    }
  }

  /// Always: after a quiet minute, update the session's summary.
  public func turnFinished(_ link: SessionLink) {
    guard Prefs.summaryMode == .always else { return }
    timers[link.sessionID]?.cancel()
    let work = DispatchWorkItem {
      MainActor.assumeIsolated {
        SummaryService.shared.timers[link.sessionID] = nil
        SummaryService.shared.request(link, trigger: .turnFinished)
      }
    }
    timers[link.sessionID] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietDelay, execute: work)
  }

  private func cancelTimers() {
    timers.values.forEach { $0.cancel() }
    timers.removeAll()
  }

  private func generate(_ link: SessionLink, incremental: Bool) {
    pending[link.sessionID] = link
    guard jobs.start(link.sessionID) else { return }
    failures[link.sessionID] = nil
    onChange?(link.sessionID)
    let previous = incremental ? SummaryStore.load(link.sessionID) : nil
    let offset = previous?.coveredBytes ?? 0
    DispatchQueue.global(qos: .utility).async {
      let head = Self.read(link.transcriptPath, from: 0, length: SummaryCache.headLength)
      let digest = TranscriptDigest.make(data: Self.read(link.transcriptPath, from: offset, length: nil), root: link.cwd)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          SummaryService.shared.fold(Fold(link: link, offset: offset, headHash: SummaryCache.headHash(head),
                                          digest: digest, previous: previous))
        }
      }
    }
  }

  /// One run's state: the digest's chunks are folded into the summary one call at a time.
  private final class Fold {
    let link: SessionLink
    let offset: Int
    let headHash: String
    let digest: TranscriptDigest
    var record: SummaryRecord
    var chunks: [String]

    init(link: SessionLink, offset: Int, headHash: String, digest: TranscriptDigest, previous: SummaryRecord?) {
      self.link = link
      self.offset = offset
      self.headHash = headHash
      self.digest = digest
      record = previous ?? SummaryRecord(
        sessionID: link.sessionID, transcriptPath: link.transcriptPath, cwd: link.cwd,
        title: digest.firstPrompt.map { String($0.prefix(60)) }, coveredBytes: 0, coveredTurns: 0, headHash: headHash,
        promptVersion: TranscriptSummaryPrompt.version, summary: "", updatedAt: Date())
      chunks = digest.text.isEmpty ? [] : TranscriptDigest.chunks(digest.text, limit: TranscriptSummaryPrompt.chunkCharacters)
    }
  }

  private func fold(_ fold: Fold) {
    guard !fold.chunks.isEmpty else { return finish(fold, failure: nil) }
    let chunk = fold.chunks.removeFirst()
    let prompt = fold.record.summary.isEmpty
      ? TranscriptSummaryPrompt.firstPrompt(digest: chunk)
      : TranscriptSummaryPrompt.revisePrompt(previous: fold.record.summary, digest: chunk)
    runs[fold.link.sessionID] = ClaudeOneShot.run(
      arguments: TranscriptSummaryPrompt.arguments(style: Resources.humanizeBody), prompt: prompt, folder: nil,
      timeout: 180) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let text):
          fold.record.summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
          self.fold(fold)
        case .failure(let failure):
          self.finish(fold, failure: failure.message)
        }
      }
  }

  /// Saves the folded summary (nothing new to fold still moves `coveredBytes` on), then starts a queued rerun.
  private func finish(_ fold: Fold, failure: String?) {
    let id = fold.link.sessionID
    if let failure {
      failures[id] = failure
    } else {
      fold.record.coveredBytes = fold.offset + fold.digest.coveredBytes
      fold.record.coveredTurns += fold.digest.turns
      fold.record.headHash = fold.headHash
      fold.record.promptVersion = TranscriptSummaryPrompt.version
      fold.record.updatedAt = Date()
      if !fold.record.summary.isEmpty { SummaryStore.save(fold.record) }
    }
    runs[id] = nil
    let again = jobs.finish(id)
    onChange?(id)
    if again, let next = pending[id] { request(next, trigger: .userAsked) }
  }

  /// Freshness of the saved summary against the file now, read off the main thread; nil when nothing is saved.
  private static func inspect(_ link: SessionLink, _ completion: @escaping @MainActor (SummaryFreshness?) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      let freshness = SummaryStore.load(link.sessionID).map {
        SummaryCache.freshness($0, fileSize: fileSize(link.transcriptPath),
                               headHash: SummaryCache.headHash(read(link.transcriptPath, from: 0,
                                                                    length: SummaryCache.headLength)),
                               promptVersion: TranscriptSummaryPrompt.version)
      }
      DispatchQueue.main.async { MainActor.assumeIsolated { completion(freshness) } }
    }
  }

  nonisolated static func fileSize(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
  }

  nonisolated static func read(_ path: String, from offset: Int, length: Int?) -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(offset))
    if let length { return ((try? handle.read(upToCount: length)) ?? nil) ?? Data() }
    return ((try? handle.readToEnd()) ?? nil) ?? Data()
  }
}
