import AVFoundation
import Foundation
import GlanceCore

/// One spoken piece of a reply: the text for a single markdown block.
struct Segment: Equatable {
  let block: Int
  let text: String
}

/// Latest audio level (RMS) written from the audio thread and read by the orb every frame.
final class LevelMeter: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Float = 0

  var value: Float {
    get { lock.lock(); defer { lock.unlock() }; return current }
    set { lock.lock(); current = newValue; lock.unlock() }
  }
}


/// Speaks segments with the cloud voice when there is one, otherwise the Mac voice. Each paragraph becomes PCM
/// buffers played through AVAudioEngine, which gives exact segment boundaries (for highlighting and diagram timing)
/// and a real level tap. Only one paragraph is fetched ahead of the one playing, so stopping early never pays for
/// the rest of the reply.
@MainActor
final class Narrator {
  var onSegmentStart: ((Segment, TimeInterval) -> Void)?
  var onFinish: (() -> Void)?
  /// The voice changed: who reads now, and why the voice before it in the order isn't (nil when nothing failed).
  var onVoiceChange: ((VoiceTier, TTSFailure?) -> Void)?
  /// Characters a cloud request was billed for.
  var onBilled: ((Int) -> Void)?
  let level = LevelMeter()
  let system = SystemVoice()
  /// Nil means the Mac voice only.
  var cloud: CloudVoice?
  /// Kokoro on this Mac, nil when the Mac voice is chosen.
  var kokoro: KokoroVoice?
  var kokoroVoice = KokoroVoices.defaultVoice.id
  var budget = VoiceBudget()
  private(set) var isSpeaking = false
  private(set) var isPaused = false

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  /// Speeds the voice up or down without changing its pitch.
  private let timePitch = AVAudioUnitTimePitch()
  /// Voice speed, 0.75× to 1.5×; applies immediately, also to the paragraph playing.
  var rate: Float = 1 { didSet { timePitch.rate = rate } }
  private var playerFormat: AVAudioFormat?
  private var tapInstalled = false
  private var generation = 0
  /// The paragraph playing first, then at most one fetched ahead.
  private var scheduled: [(segment: Segment, duration: TimeInterval)] = []
  private var synthesisDone = false
  private var playbackWaiters: [CheckedContinuation<Void, Never>] = []
  private var lastVoice: (kind: VoiceTier, failure: TTSFailure?)?

  init() {
    engine.attach(player)
    engine.attach(timePitch)
  }

  func speak(_ segments: [Segment], startAt: Int = 0) {
    stop()
    guard startAt < segments.count else { return }
    let gen = generation
    isSpeaking = true
    synthesisDone = false
    lastVoice = nil
    Task {
      for index in startAt..<segments.count {
        // Fetch N+1 while N plays, and no further.
        while gen == generation, scheduled.count >= 2 { await waitForPlayback() }
        guard gen == generation else { return }
        let buffers = await audio(for: index, in: segments, gen)
        guard gen == generation else { return }
        if !buffers.isEmpty { schedule(segments[index], buffers, gen) }
      }
      synthesisDone = true
      finishIfDone(gen)
    }
  }

  func stop() {
    generation += 1
    system.stop()
    scheduled.removeAll()
    wakeWaiters()
    player.stop()
    if engine.isRunning { engine.pause() }
    isSpeaking = false
    isPaused = false
    level.value = 0
  }

  func togglePause() {
    guard isSpeaking else { return }
    if isPaused {
      if !engine.isRunning { try? engine.start() }
      player.play()
    } else {
      player.pause()
      level.value = 0
    }
    isPaused.toggle()
  }

  // MARK: - Choosing a voice

  /// The cloud voice when one is chosen, the budget allows and the request works; otherwise Kokoro; the Mac voice only
  /// when Kokoro can't speak. Some voice reads every paragraph, so nothing is skipped. A request that comes back after
  /// `stop()` (generation changed) still counts what it cost, but leaves the budget, the voice chip and the shared
  /// synthesizer to the reply that replaced it.
  private func audio(for index: Int, in segments: [Segment], _ gen: Int) async -> [AVAudioPCMBuffer] {
    let text = segments[index].text
    var reason: TTSFailure?
    if let cloud {
      switch budget.choose(characters: text.count, cached: cloud.isCached(text)) {
      case .cloud:
        let context = Narration.context(texts: segments.map(\.text), index: index)
        do {
          let result = try await cloud.audio(for: text, previous: context.previous, next: context.next)
          budget.spent(result.billed)
          if result.billed > 0 { onBilled?(result.billed) }
          guard gen == generation else { return [] }
          report(.cloud, nil)
          return result.buffers
        } catch {
          guard gen == generation else { return [] }
          let failure = error as? TTSFailure ?? .network(error.localizedDescription)
          budget.failed(failure)
          reason = failure
        }
      case .system(let failure):
        reason = failure
      }
    }
    return await local(text, reason: reason, gen)
  }

  /// Kokoro, then the Mac voice. `reason` is why the cloud voice isn't reading, nil when there's none.
  private func local(_ text: String, reason: TTSFailure?, _ gen: Int) async -> [AVAudioPCMBuffer] {
    var reason = reason
    if VoiceTier.next(after: .cloud, kokoroAvailable: kokoro != nil) == .kokoro, let kokoro {
      do {
        let buffers = try await kokoro.audio(for: text, voice: kokoroVoice)
        guard gen == generation else { return [] }
        report(.kokoro, reason)
        return buffers
      } catch {
        guard gen == generation else { return [] }
        reason = error as? TTSFailure ?? .unavailable("Glance Voice: \(error.localizedDescription)")
      }
    }
    report(.mac, reason)
    return await system.audio(for: text)
  }

  private func report(_ kind: VoiceTier, _ failure: TTSFailure?) {
    if let last = lastVoice, last.kind == kind, last.failure == failure { return }
    lastVoice = (kind, failure)
    onVoiceChange?(kind, failure)
  }

  // MARK: - Playback

  private func schedule(_ segment: Segment, _ buffers: [AVAudioPCMBuffer], _ gen: Int) {
    var buffers = buffers
    // Reconnecting the player would cut off the paragraph playing, so a mid-reply change of voice is resampled to
    // the format already in use.
    if !scheduled.isEmpty, let current = playerFormat, current != buffers[0].format {
      buffers = AudioBuffers.convert(buffers, to: current)
      guard !buffers.isEmpty else { return }
    } else {
      guard prepareEngine(for: buffers[0].format) else { return }
    }
    let frames = buffers.reduce(0.0) { $0 + Double($1.frameLength) }
    let duration = frames / buffers[0].format.sampleRate / Double(max(rate, 0.1))
    let startsNow = scheduled.isEmpty
    scheduled.append((segment, duration))
    for (index, buffer) in buffers.enumerated() {
      if index == buffers.count - 1 {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
          Task { @MainActor in self?.segmentFinished(gen) }
        }
      } else {
        player.scheduleBuffer(buffer, completionHandler: nil)
      }
    }
    if !isPaused, !player.isPlaying { player.play() }
    if startsNow { onSegmentStart?(segment, duration) }
  }

  private func segmentFinished(_ gen: Int) {
    guard gen == generation, !scheduled.isEmpty else { return }
    scheduled.removeFirst()
    wakeWaiters()
    if let next = scheduled.first { onSegmentStart?(next.segment, next.duration) }
    finishIfDone(gen)
  }

  private func waitForPlayback() async {
    await withCheckedContinuation { playbackWaiters.append($0) }
  }

  private func wakeWaiters() {
    let waiters = playbackWaiters
    playbackWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func finishIfDone(_ gen: Int) {
    guard gen == generation, isSpeaking, synthesisDone, scheduled.isEmpty else { return }
    isSpeaking = false
    isPaused = false
    player.stop()
    if engine.isRunning { engine.pause() }
    level.value = 0
    onFinish?()
  }

  private func prepareEngine(for format: AVAudioFormat) -> Bool {
    if playerFormat != format {
      engine.stop()
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(timePitch)
      engine.connect(player, to: timePitch, format: format)
      engine.connect(timePitch, to: engine.mainMixerNode, format: format)
      playerFormat = format
    }
    if !tapInstalled {
      let level = self.level
      // @Sendable: AVFAudio calls the tap on its own queue, where a main-actor closure traps (Swift 6).
      engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        level.value = (sum / Float(count)).squareRoot()
      }
      tapInstalled = true
    }
    if !engine.isRunning {
      do { try engine.start() } catch {
        NSLog("Glance: audio engine failed to start: \(error)")
        return false
      }
    }
    return true
  }
}
