import AppKit
import AVFoundation
import GlanceCore

/// Someone else takes an fn hold (spec 2026-10-09-orb-channel-design.md, "Voice"): an orb-channel card or the orb
/// assistant. The words go to it, not into the app in front; no pill shows (the card shows them).
@MainActor
public protocol VoiceDivert: AnyObject {
  /// fn held past the threshold: listening.
  func began()
  /// Words so far (Scribe only; Parakeet has none until the end).
  func heard(_ partial: String)
  func finished(_ text: String)
  func failed(_ message: String)
  /// fn released: the mic is off and the words are being made out (Parakeet, or Scribe's last words).
  func transcribing()
}

extension VoiceDivert {
  public func transcribing() {}
}

/// Hold fn → stream the mic to Scribe → put the text in the sink (typed at the cursor, for the overlay). Never presses Return.
@MainActor
public final class DictationController {
  /// True while fn is held for dictation (narration pauses), false when it ends.
  public var onHoldChanged: ((Bool) -> Void)?
  /// The terminal's window when a terminal is in front, so the pill sits above its input.
  public var anchorFrame: () -> NSRect? = { nil }
  public var latestReply: String?
  public var latestCwd: String? {
    didSet { if latestCwd != oldValue { loadProjectFiles() } }
  }
  /// Where the dictated text goes.
  public var sink: TextSink = AccessibilityTextSink()
  /// Whether a fn hold should dictate now. The overlay stands down while Glance Studio is in front; Glance Studio
  /// only dictates while it is.
  public var shouldStart: () -> Bool = { true }
  /// Asked when fn goes down: a non-nil divert takes this hold (orb-channel card, orb assistant).
  public var divert: (() -> VoiceDivert?)?
  private var diverted: VoiceDivert?
  /// This hold is transcribed on this Mac (Parakeet), not by Scribe.
  private var localCapture = false

  private var gesture = FnGesture()
  private let monitor = FnMonitor()
  private let mic = MicStream()
  private lazy var pill = DictationPill(level: mic.level)
  private var client: ScribeClient?
  /// Everything captured this hold: flushed when the session opens, replayed on a retry.
  private var audio: [Data] = []
  private var streaming = false
  private var holdActive = false
  private var awaitingFinal = false
  private var committed = ""
  private var partial = ""
  private var projectFiles: [String] = []
  private var tickTimer: Timer?
  private var finalTimeout: DispatchWorkItem?

  public init() {
    monitor.onFnDown = { [weak self] in guard let self else { return }; self.apply(self.gesture.fnDown(at: Self.now)) }
    monitor.onFnUp = { [weak self] in guard let self else { return }; self.apply(self.gesture.fnUp(at: Self.now)) }
    // A diverted hold ignores modifier changes (⌃ is held with fn for the assistant); a key press (fn+←, fn+Delete,
    // F-keys) still means fn is a modifier and cancels it.
    monitor.onOtherKey = { [weak self] isKeyDown in
      guard let self, self.diverted == nil || isKeyDown else { return }
      self.apply(self.gesture.otherKey(at: Self.now))
    }
    mic.onChunk = { [weak self] chunk in self?.captured(chunk) }
  }

  public func setEnabled(_ enabled: Bool) {
    if enabled {
      monitor.start()
    } else {
      monitor.stop()
      cancel()
    }
  }

  private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  private func apply(_ action: FnGesture.Action?) {
    switch action {
    case .arm?: arm()
    case .start?: start()
    case .commit?: commit()
    case .cancel?: cancel()
    case .capWarning?: if diverted == nil { pill.setNotice("10s left") }
    case nil: break
    }
  }

  // MARK: Lifecycle

  /// fn went down: capture locally. Nothing leaves the Mac unless the hold becomes dictation.
  private func arm() {
    // Still finishing the last hold (Scribe's final words, or Parakeet): this one is dropped, and its divert untouched.
    guard !awaitingFinal else { gesture.reset(); return }
    diverted = divert?()
    guard diverted != nil || shouldStart() else { gesture.reset(); return }
    if MicStream.permission == .notDetermined {
      gesture.reset()
      dropDiverted()
      Task { _ = await MicStream.requestPermission() }   // macOS asks once; the next hold records
      return
    }
    audio.removeAll()
    committed = ""
    partial = ""
    streaming = false
    if MicStream.permission == .authorized {
      do { try mic.start() } catch { NSLog("Glance: microphone failed to start: \(error)") }
    }
    scheduleTick(after: FnGesture.holdThreshold + 0.01, repeating: false)
    // Warm Parakeet while the hold decides whether it's a hold.
    if diverted != nil, MeetingSpeechModels.isDownloaded {
      Task { try? await MeetingSpeechModels.shared.loadTranscription() }
    }
  }

  private func start() {
    if let diverted {
      guard MicStream.permission == .authorized else {
        return abort("Allow the microphone in System Settings → Privacy & Security → Microphone")
      }
      holdActive = true
      onHoldChanged?(true)
      if MeetingSpeechModels.isDownloaded {
        localCapture = true
        diverted.began()
        scheduleTick(after: 1, repeating: true)
        return
      }
      guard let key = KeychainStore.elevenLabs.read() else {
        return abort("Voice answers need the speech model. Download it in Settings → Orb Channel.")
      }
      localCapture = false
      diverted.began()
      connect(key: key, zeroRetention: Prefs.scribeZeroRetention, commitAtEnd: false)
      scheduleTick(after: 1, repeating: true)
      return
    }
    guard MicStream.permission == .authorized else {
      abort("Allow the microphone in System Settings → Privacy & Security → Microphone")
      return
    }
    guard sink.canInsert else {
      sink.requestAccess()   // e.g. asks macOS to show its Accessibility prompt
      abort(sink.accessHint)
      return
    }
    guard let key = KeychainStore.elevenLabs.read() else {
      abort("Add your ElevenLabs key in Glance Settings")
      return
    }
    holdActive = true
    onHoldChanged?(true)
    pill.show(.listening, near: anchorFrame())
    connect(key: key, zeroRetention: Prefs.scribeZeroRetention, commitAtEnd: false)
    scheduleTick(after: 1, repeating: true)
  }

  private func connect(key: String, zeroRetention: Bool, commitAtEnd: Bool) {
    let client = ScribeClient(key: key, keyterms: Keyterms.build(reply: latestReply, projectFiles: projectFiles),
                              zeroRetention: zeroRetention, previousText: latestReply.map { String($0.prefix(300)) })
    client.onEvent = { [weak self] event in self?.received(event, key: key, zeroRetention: zeroRetention) }
    self.client = client
    client.connect()
    for (index, chunk) in audio.enumerated() {
      client.send(audio: chunk, commit: commitAtEnd && index == audio.count - 1)
    }
    streaming = !commitAtEnd
  }

  private func captured(_ chunk: Data) {
    audio.append(chunk)
    if streaming { client?.send(audio: chunk) }
  }

  private func commit() {
    if diverted != nil, localCapture {
      stopTick()
      endHold()
      audio.append(mic.stop())
      let samples = PCM.floats(int16LE: audio.reduce(into: Data()) { $0.append($1) })
      audio.removeAll()
      awaitingFinal = true
      // The words belong to this hold: once it's cancelled (or a new one took over) they go nowhere.
      let target = diverted
      target?.transcribing()
      Task { [weak self] in
        do {
          let text = try await MeetingSpeechModels.shared.transcribe(samples)
          guard let self, self.diverted === target else { return }
          self.finishDiverted(DictationText.finalize(text))
        } catch {
          guard let self, self.diverted === target else { return }
          self.abort("Couldn't make out the words: \(error.localizedDescription)")
        }
      }
      return
    }
    stopTick()
    endHold()
    streaming = false
    let rest = mic.stop()
    let tail = rest.isEmpty ? Data(count: 320) : rest   // the commit flag needs a chunk to ride on
    audio.append(tail)
    guard let client else { return }
    awaitingFinal = true
    if let diverted { diverted.transcribing() } else { pill.set(.finishing) }
    client.send(audio: tail, commit: true)
    let timeout = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.finish() } }
    finalTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + (client.hasStarted ? 1.5 : 5), execute: timeout)
  }

  private func received(_ event: ScribeEvent, key: String, zeroRetention: Bool) {
    switch event {
    case .started:
      break
    case .partial(let text):
      partial = text
      if let diverted { diverted.heard(Self.join(committed, text)) } else { pill.update(text: Self.join(committed, text)) }
    case .committed(let text):
      committed = Self.join(committed, text)
      partial = ""
      if let diverted { diverted.heard(committed) } else { pill.update(text: committed) }
      if awaitingFinal { finish() }
    case .failure(let kind, let message):
      // Accounts without zero retention reject enable_logging=false: remember that and retry once without it.
      if zeroRetention, client?.hasStarted == false, ["invalid_request", "http"].contains(kind) {
        Prefs.scribeZeroRetention = false
        client?.close()
        connect(key: key, zeroRetention: false, commitAtEnd: awaitingFinal)
        return
      }
      abort(ScribeMessages.describe(kind: kind, message: message))
    }
  }

  private func finish() {
    guard awaitingFinal else { return }
    awaitingFinal = false
    let text = DictationText.finalize(Self.join(committed, partial))
    teardown()
    if diverted != nil { return finishDiverted(text) }
    guard !text.isEmpty else { showMessage("Didn't catch that"); return }
    switch sink.insert(text) {
    case .inserted:
      if Prefs.fnUsage.conflictsWithDictation, !Prefs.fnNoticeShown {
        Prefs.fnNoticeShown = true
        showMessage("Tip: Keyboard settings → “Press 🌐 key to” → Do Nothing", seconds: 5)
      } else {
        pill.hide()
      }
    case .notAllowed:
      showError(sink.accessHint)
    case .secureInput:
      showError("Can't type into a password field")
    case .failed:
      showError("Couldn't type the text")
    }
  }

  private func finishDiverted(_ text: String) {
    awaitingFinal = false
    let target = diverted
    diverted = nil
    localCapture = false
    guard let target else { return }
    if text.isEmpty { target.failed("Didn't catch that") } else { target.finished(text) }
  }

  /// A divert that took fn down but won't get the hold: it stops listening, with nothing to say.
  private func dropDiverted() {
    guard let target = diverted else { return }
    diverted = nil
    localCapture = false
    target.failed("")
  }

  /// fn used as a modifier, Glance disabled, or a short tap: drop everything quietly.
  func cancel() {
    stopTick()
    endHold()
    awaitingFinal = false
    teardown()
    gesture.reset()
    dropDiverted()
    pill.hide()
  }

  private func abort(_ message: String) {
    stopTick()
    endHold()
    awaitingFinal = false
    teardown()
    gesture.reset()
    showError(message)
  }

  private func endHold() {
    guard holdActive else { return }
    holdActive = false
    onHoldChanged?(false)
  }

  private func teardown() {
    finalTimeout?.cancel()
    finalTimeout = nil
    streaming = false
    mic.stop()
    client?.close()
    client = nil
    audio.removeAll()
  }

  // MARK: Helpers

  private func showError(_ message: String) {
    if let target = diverted { diverted = nil; localCapture = false; return target.failed(message) }
    pill.show(.message(message, isError: true), near: anchorFrame())
    pill.hide(after: 3)
  }

  private func showMessage(_ message: String, seconds: TimeInterval = 1.6) {
    if let target = diverted { diverted = nil; localCapture = false; return target.failed(message) }
    pill.show(.message(message, isError: false), near: anchorFrame())
    pill.hide(after: seconds)
  }

  private func scheduleTick(after delay: TimeInterval, repeating: Bool) {
    tickTimer?.invalidate()
    tickTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: repeating) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.apply(self.gesture.tick(at: Self.now))
      }
    }
  }

  private func stopTick() {
    tickTimer?.invalidate()
    tickTimer = nil
  }

  private func loadProjectFiles() {
    guard let cwd = latestCwd else { projectFiles = []; return }
    Task { [weak self] in
      let files = await Task.detached(priority: .utility) { ProjectFiles.recent(cwd: cwd) }.value
      if self?.latestCwd == cwd { self?.projectFiles = files }
    }
  }

  private static func join(_ a: String, _ b: String) -> String {
    [a, b].filter { !$0.isEmpty }.joined(separator: " ")
  }
}
