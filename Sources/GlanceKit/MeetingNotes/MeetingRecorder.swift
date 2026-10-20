import AppKit
import Combine
import GlanceCore

/// Records one meeting at a time (spec 2026-10-09-meeting-notes-design.md): the mic and the call's sound to disk at
/// once, chunks transcribed on this Mac as they come (once Parakeet is downloaded and loaded), Ask while it runs; Stop
/// transcribes the rest, frees Parakeet, tells the speakers apart, has Claude write the notes, and deletes the audio
/// unless Keep recordings is on.
@MainActor
public final class MeetingRecorder: ObservableObject {
  public static let shared = MeetingRecorder()

  public enum Phase: Equatable {
    case idle
    case recording
    /// After Stop (or on Transcribe): what it's doing now.
    case finishing(String)
  }

  /// Parakeet's state for the meeting under way.
  public enum ModelState: Equatable {
    case idle
    case downloading(Double, String)
    case loading
    case ready
    case failed(String)
  }

  @Published public private(set) var phase: Phase = .idle
  /// The meeting being recorded or finished.
  @Published public private(set) var record: MeetingRecord?
  @Published public private(set) var model: ModelState = .idle
  /// Chunks recorded but not transcribed yet.
  @Published public private(set) var backlog = 0
  @Published public private(set) var micProblem: String?
  @Published public private(set) var callProblem: String?
  /// A live Ask under way.
  @Published public private(set) var asking = false

  public var isRecording: Bool { phase == .recording }
  public var isBusy: Bool { phase != .idle }
  public var micLevel: Float { microphone.level.value }
  public var callLevel: Float { tap.level.value }

  let store = MeetingNotesStore.standard
  private let models = MeetingSpeechModels.shared
  private let microphone = MeetingMicrophone()
  private let tap = SystemAudioTap()
  /// Where the mic and the tap start and stop: starting can wait on macOS's permission prompt, and the main thread must
  /// never block on it (a blocked main thread there crashed Studio in SwiftUI's hover handling, 2026-10-09).
  private let captureQueue = DispatchQueue(label: "dev.glance.meeting-capture", qos: .userInitiated)
  private var channels: [TranscriptLine.Channel: MeetingChannel] = [:]
  private var pending: [(TranscriptLine.Channel, SpeechChunker.Chunk)] = []
  private var transcribing = false
  private var stopping = false
  /// Some speech wasn't transcribed live (the model failed for a while): at Stop the files are transcribed instead.
  private var missedSpeech = false
  private var lastSave = Date.distantPast
  private var hintTimer: Timer?
  private var askRun: ClaudeOneShot.Run?

  private init() {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                           queue: .main) { _ in
      MainActor.assumeIsolated { MeetingRecorder.shared.quitting() }
    }
  }

  /// Studio is quitting mid-recording: the files are closed and the meeting saved as it is; the next launch marks it
  /// interrupted, its audio kept for Transcribe.
  private func quitting() {
    guard phase == .recording else { return }
    // The files only: the hardware stops with the process, and the capture queue may be busy.
    for pipe in channels.values { _ = pipe.finish() }
    channels = [:]
    record?.end = Date()
    save(force: true)
  }

  private var recovered = false

  /// Once per launch, before the library first reads the folder: meetings left recording by a quit or crash become
  /// `interrupted` (or ready with a note when nothing was recorded). The meeting under way is never touched.
  public func recover() {
    guard !recovered else { return }
    recovered = true
    store.recoverInterrupted(except: record?.id)
  }

  // MARK: Recording

  /// Starts recording now. `title` and `eventID` come from the calendar when it's a meeting from the nudge.
  public func start(title: String? = nil, eventID: String? = nil) {
    guard phase == .idle else { return }
    let start = Date()
    let record = MeetingRecord(id: MeetingRecord.newID(start: start), title: title ?? MeetingNotesWriter.untitled,
                               start: start, eventID: eventID)
    self.record = record
    micProblem = nil
    callProblem = nil
    pending = []
    backlog = 0
    stopping = false
    missedSpeech = false
    phase = .recording
    save(force: true)
    startCapture(record.id)
    loadModel()
    // A call channel still silent after a minute while the mic hears speech: likely the permission.
    hintTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkCallAudio() }
    }
    MeetingNotesLibrary.shared.updated(record)
  }

  private func startCapture(_ id: String) {
    // The channels (files and chunkers) are made here; the hardware starts on the capture queue.
    for channel in [TranscriptLine.Channel.mic, .system] {
      do {
        channels[channel] = try MeetingChannel(channel: channel, file: store.audioURL(id, channel: channel)) {
          [weak self] chunk in
          Task { @MainActor in self?.enqueue(chunk, channel: channel) }
        }
      } catch {
        if channel == .mic { micProblem = error.localizedDescription } else { callProblem = error.localizedDescription }
      }
    }
    let mic = channels[.mic], call = channels[.system]
    let microphone = self.microphone, tap = self.tap, captureQueue = self.captureQueue
    Task { @MainActor in
      let micAllowed = mic != nil ? await MicStream.requestPermission() : false
      guard self.phase == .recording, self.record?.id == id else { return }
      if mic != nil && !micAllowed {
        self.micProblem = "Glance Studio can't use the microphone. Allow it in System Settings → Privacy & Security."
      }
      captureQueue.async {
        var micProblem: String?
        var callProblem: String?
        if let mic, micAllowed {
          do {
            try microphone.start { samples in mic.feed(samples) }
          } catch {
            micProblem = "No microphone to record from."
          }
        }
        if let call {
          do {
            try tap.start { samples in call.feed(samples) }
          } catch {
            callProblem = error.localizedDescription
          }
        }
        Task { @MainActor in
          if let micProblem { self.micProblem = micProblem }
          if let callProblem { self.callProblem = callProblem }
        }
      }
    }
  }

  private func checkCallAudio() {
    guard phase == .recording, callProblem == nil, let call = channels[.system], let mic = channels[.mic] else { return }
    if call.peak < 0.001 && mic.peak > 0.01 {
      callProblem = "Not hearing the call yet. If others are talking, allow Glance Studio under System Settings → "
        + "Privacy & Security → Screen & System Audio Recording → System Audio Recording Only."
    }
  }

  /// Stops recording; the rest happens on its own and the meeting turns up ready in the library.
  public func stop() {
    guard phase == .recording, var record else { return }
    hintTimer?.invalidate()
    record.end = Date()
    record.status = .transcribing
    self.record = record
    phase = .finishing("Finishing…")
    save(force: true)
    let channels = self.channels
    self.channels = [:]
    let microphone = self.microphone, tap = self.tap
    // After the start queued before it (a stop right after Record waits for the start to finish).
    captureQueue.async {
      microphone.stop()
      tap.stop()
      let lasts = channels.compactMap { channel, pipe in pipe.finish().map { (channel, $0) } }
      Task { @MainActor in
        for (channel, chunk) in lasts { self.enqueue(chunk, channel: channel) }
        self.stopping = true
        self.phase = .finishing(self.backlog > 0 ? "Transcribing the rest…" : "Finishing…")
        self.finishIfDone()
      }
    }
  }

  // MARK: Parakeet

  private func loadModel() {
    model = MeetingSpeechModels.isDownloaded ? .loading : .downloading(0, "Downloading the transcription model…")
    Task { @MainActor in
      do {
        try await models.loadTranscription { fraction, phase in
          Task { @MainActor in
            guard case .downloading = self.model else { return }
            self.model = fraction >= 1 ? .loading : .downloading(fraction, phase)
          }
        }
        model = .ready
        pump()
      } catch {
        model = .failed(error.localizedDescription)
        // The audio is on disk: it's transcribed from the files at Stop, or by Transcribe later.
        if !pending.isEmpty { missedSpeech = true }
        pending = []
        backlog = 0
        finishIfDone()
      }
    }
  }

  /// Download again after a failure; the chunks recorded meanwhile are transcribed from the files at Stop.
  public func retryModel() {
    guard case .failed = model, phase != .idle else { return }
    loadModel()
  }

  private func enqueue(_ chunk: SpeechChunker.Chunk, channel: TranscriptLine.Channel) {
    if case .failed = model {
      missedSpeech = true
      return
    }
    pending.append((channel, chunk))
    backlog = pending.count
    pump()
  }

  /// Transcribes the oldest chunk, one at a time.
  private func pump() {
    guard !transcribing, model == .ready, let (channel, chunk) = pending.first else { return }
    transcribing = true
    Task { @MainActor in
      let text = try? await models.transcribe(chunk.samples)
      pending.removeFirst()
      backlog = pending.count
      transcribing = false
      if let text, !text.isEmpty, var record {
        record.lines.append(TranscriptLine(channel: channel, start: chunk.startSeconds, end: chunk.endSeconds,
                                           text: text))
        self.record = record
        save()
      }
      pump()
      finishIfDone()
    }
  }

  // MARK: Finishing

  private func finishIfDone() {
    guard stopping, !transcribing, pending.isEmpty, let record else { return }
    stopping = false
    let modelFailed: String? = if case .failed(let reason) = model { reason } else { nil }
    if modelFailed == nil && missedSpeech {
      // The model came back after a failure: the files have everything.
      model = .idle
      transcribeFiles(record)
      return
    }
    Task { @MainActor in
      await models.releaseTranscription()
      model = .idle
      if let modelFailed {
        var record = record
        record.status = .interrupted
        record.problem = "Couldn't load the transcription model (\(modelFailed)). The audio is kept: Transcribe tries "
          + "again."
        self.record = record
        done()
        return
      }
      await label(record)
    }
  }

  /// The speakers, then the notes.
  private func label(_ record: MeetingRecord) async {
    var record = record
    phase = .finishing("Telling the speakers apart…")
    record.lines = await MeetingPipeline.label(record.lines, systemAudio: store.audioURL(record.id, channel: .system),
                                               models: models)
    self.record = record
    save(force: true)
    writeNotes()
  }

  private func writeNotes() {
    guard var record else { return }
    guard !record.lines.isEmpty else {
      record.status = .ready
      record.problem = "Nothing was said that could be transcribed."
      self.record = record
      done()
      return
    }
    record.status = .summarizing
    self.record = record
    phase = .finishing("Claude is writing the notes…")
    save(force: true)
    MeetingNotesWriter.notes(for: record) { [weak self] result in
      guard let self, var record = self.record else { return }
      switch result {
      case .success(let summary):
        record.summary = summary
        record.problem = nil
        if record.title == MeetingNotesWriter.untitled, let title = summary.title { record.title = title }
      case .failure(let error):
        record.problem = "Notes not written: \(error.localizedDescription)"
      }
      record.status = .ready
      self.record = record
      self.done()
    }
  }

  /// Saves the finished meeting, deletes its audio unless kept (or still needed for Transcribe), and goes idle.
  private func done() {
    guard var record else { return }
    if record.status == .ready, !Prefs.meetingKeepRecordings {
      store.deleteAudio(record.id)
      record.hasAudio = false
    }
    self.record = record
    save(force: true)
    MeetingNotesLibrary.shared.updated(record)
    phase = .idle
    self.record = nil
    asking = false
  }

  // MARK: Transcribe a saved meeting

  /// Transcribes a saved meeting's audio again (an interrupted meeting, or one whose model failed), then labels it
  /// and writes the notes, like a Stop.
  public func transcribe(_ saved: MeetingRecord) {
    guard phase == .idle, saved.hasAudio else { return }
    transcribeFiles(saved)
  }

  /// Both channels' files to words, then speakers and notes.
  private func transcribeFiles(_ saved: MeetingRecord) {
    var started = saved
    started.status = .transcribing
    started.problem = nil
    record = started
    phase = .finishing("Loading the transcription model…")
    MeetingNotesLibrary.shared.updated(started)
    Task { @MainActor in
      var record = started
      do {
        try await models.loadTranscription { fraction, _ in
          Task { @MainActor in
            self.phase = .finishing("Downloading the transcription model… \(Int(fraction * 100))%")
          }
        }
        var lines: [TranscriptLine] = []
        for channel in [TranscriptLine.Channel.mic, .system] {
          let url = store.audioURL(record.id, channel: channel)
          guard FileManager.default.fileExists(atPath: url.path) else { continue }
          phase = .finishing(channel == .mic ? "Transcribing your side…" : "Transcribing the call…")
          let samples = try MeetingAudioFile.samples(at: url)
          lines += try await MeetingPipeline.transcribe(samples, channel: channel, models: models)
        }
        await models.releaseTranscription()
        record.lines = lines.sorted { $0.start < $1.start }
        if record.end == nil { record.end = record.start.addingTimeInterval(lines.map(\.end).max() ?? 0) }
        self.record = record
        await label(record)
      } catch {
        await models.releaseTranscription()
        record.status = .interrupted
        record.problem = "Couldn't transcribe: \(error.localizedDescription)"
        self.record = record
        done()
      }
    }
  }

  // MARK: Ask live

  /// A question during the meeting, about the transcript so far. The answer joins the meeting's Q&A.
  public func ask(_ question: String) {
    guard let record, !asking, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    asking = true
    askRun = MeetingNotesWriter.ask(question, about: record, live: phase == .recording) { [weak self] result in
      guard let self else { return }
      self.asking = false
      let answer = switch result {
      case .success(let text): text
      case .failure(let error): "Couldn't answer: \(error.localizedDescription)"
      }
      guard var current = self.record else { return }
      current.asks.append(MeetingAsk(question: question, answer: answer, date: Date()))
      self.record = current
      self.save(force: true)
    }
  }

  // MARK: Saving

  private func save(force: Bool = false) {
    guard let record, force || Date().timeIntervalSince(lastSave) > 5 else { return }
    lastSave = Date()
    try? store.save(record)
  }
}

/// One channel under way: its file, its chunker on its own queue, and the loudest sample heard (for the permission
/// hint). Fed from the audio thread.
final class MeetingChannel: @unchecked Sendable {
  let channel: TranscriptLine.Channel
  private let queue: DispatchQueue
  private var chunker = SpeechChunker()
  private let file: MeetingAudioFile
  private let onChunk: @Sendable (SpeechChunker.Chunk) -> Void
  private var loudest: Float = 0

  init(channel: TranscriptLine.Channel, file url: URL, onChunk: @escaping @Sendable (SpeechChunker.Chunk) -> Void) throws {
    self.channel = channel
    self.file = try MeetingAudioFile(url: url)
    self.onChunk = onChunk
    queue = DispatchQueue(label: "dev.glance.meeting-\(channel.rawValue)", qos: .userInitiated)
  }

  func feed(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    file.append(samples)
    queue.async { [self] in
      for sample in samples where abs(sample) > loudest { loudest = abs(sample) }
      for chunk in chunker.append(samples) { onChunk(chunk) }
    }
  }

  var peak: Float { queue.sync { loudest } }

  /// At Stop: the last piece of speech, and the file closed.
  func finish() -> SpeechChunker.Chunk? {
    let last = queue.sync { chunker.flush() }
    file.close()
    return last
  }
}
