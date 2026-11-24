import AVFoundation
import Combine
import Foundation

/// Plays an explainer page's beats in order with Kokoro, whichever voice is chosen elsewhere. Each beat is synthesised
/// once, saved beside the page and played from there, so replays cost nothing (spec 2026-11-03-explainer-mode-design.md §9).
@MainActor
public final class ExplainerVoicePlayer: ObservableObject {
  public static let shared = ExplainerVoicePlayer()

  public struct Beat: Equatable, Sendable {
    public let say: String
    /// Where its audio is kept.
    public let file: URL
    public init(say: String, file: URL) {
      self.say = say
      self.file = file
    }
  }

  public struct Playback: Equatable {
    /// Which page: the app's key for a session and reply.
    public let page: String
    public let count: Int
    public var beat: Int
    public var playing: Bool
    /// Still synthesising the beat it should be playing.
    public var preparing: Bool
  }

  @Published public private(set) var current: Playback?
  /// Kokoro couldn't speak this page's beats. The page stays; the bar says so.
  @Published public private(set) var unavailablePage: String?
  @Published public private(set) var speed: Float = 1
  @Published public private(set) var muted = false

  /// About 30 times a second while playing: the beat, seconds into it, and its length.
  public var onPosition: ((_ page: String, _ beat: Int, _ time: Double, _ duration: Double) -> Void)?
  /// The voice stopped or finished on this page: it goes back to rest.
  public var onStop: ((_ page: String) -> Void)?

  public var isPlaying: Bool { current?.playing == true }
  /// 0...1, for the orb.
  public var level: Double { Double(min(meter.value * 4, 1)) }

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private let meter = LevelMeter()
  private var attachedFormat: AVAudioFormat?
  private var tapInstalled = false
  private var beats: [Beat] = []
  private var generation = 0
  private var clock: Timer?
  private var playingDuration: Double = 0
  private var playingBuffer: AVAudioPCMBuffer?
  private var preparer: Task<Void, Never>?
  private var making: [URL: Task<URL?, Never>] = [:]
  private let synthesize: ExplainerRenderer.Voice

  private init() { synthesize = ExplainerVoice.wav; attachNodes() }

  /// For the tests: a voice that isn't Kokoro.
  init(voice: @escaping ExplainerRenderer.Voice) { synthesize = voice; attachNodes() }

  private func attachNodes() {
    engine.attach(player)
    engine.attach(timePitch)
  }

  /// Writes each beat's audio ahead of playing, in order, skipping what's already saved. Failures show when it plays.
  public func prepare(beats: [Beat]) {
    preparer = Task { [weak self] in
      for beat in beats {
        if Task.isCancelled { return }
        _ = await self?.audioFile(for: beat)
      }
    }
  }

  /// Plays from a beat. A page already playing moves there.
  public func play(page: String, beats: [Beat], from start: Int = 0) {
    guard beats.indices.contains(start) else { return }
    SessionVoices.silenceOthers?()
    ReplyVoice.shared.stop()
    if let current, current.page != page { onStop?(current.page) }
    self.beats = beats
    unavailablePage = nil
    current = Playback(page: page, count: beats.count, beat: start, playing: true, preparing: false)
    start_(beat: start)
  }

  public func playPause() {
    guard var now = current else { return }
    if now.playing {
      player.pause()
      meter.value = 0
      clock?.invalidate()
      now.playing = false
    } else {
      if !engine.isRunning { try? engine.start() }
      if playingBuffer != nil { player.play() }
      startClock()
      now.playing = true
    }
    current = now
  }

  public func stop() {
    generation += 1
    clock?.invalidate()
    player.stop()
    meter.value = 0
    playingBuffer = nil
    if let page = current?.page { onStop?(page) }
    current = nil
  }

  public func setSpeed(_ value: Float) {
    speed = value
    timePitch.rate = value
  }

  public func toggleMute() {
    muted.toggle()
    player.volume = muted ? 0 : 1
  }

  /// A page went away: nothing keeps talking about it.
  public func stop(page: String) {
    if current?.page == page { stop() }
  }

  // MARK: Playing

  private func start_(beat index: Int) {
    generation += 1
    let gen = generation
    clock?.invalidate()
    player.stop()
    playingBuffer = nil
    current?.beat = index
    current?.preparing = true
    let beat = beats[index]
    Task { [weak self] in
      guard let self else { return }
      let file = await self.audioFile(for: beat)
      guard gen == self.generation else { return }
      guard let file, let buffer = Self.buffer(of: file) else {
        let page = self.current?.page
        self.stop()
        self.unavailablePage = page
        return
      }
      self.schedule(buffer, gen: gen, index: index)
    }
  }

  private func schedule(_ buffer: AVAudioPCMBuffer, gen: Int, index: Int) {
    guard prepareEngine(for: buffer.format) else {
      let page = current?.page
      stop()
      unavailablePage = page
      return
    }
    playingBuffer = buffer
    playingDuration = Double(buffer.frameLength) / buffer.format.sampleRate
    player.volume = muted ? 0 : 1
    timePitch.rate = speed
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(gen: gen, index: index) } }
    }
    current?.preparing = false
    if current?.playing == true {
      player.play()
      startClock()
    }
  }

  private func finished(gen: Int, index: Int) {
    guard gen == generation, current != nil else { return }
    if beats.indices.contains(index + 1) {
      start_(beat: index + 1)
    } else {
      stop()
    }
  }

  private func prepareEngine(for format: AVAudioFormat) -> Bool {
    if attachedFormat != format {
      engine.stop()
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(timePitch)
      engine.connect(player, to: timePitch, format: format)
      engine.connect(timePitch, to: engine.mainMixerNode, format: format)
      attachedFormat = format
    }
    if !tapInstalled {
      let level = meter
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
      do { try engine.start() } catch { return false }
    }
    return true
  }

  private func startClock() {
    clock?.invalidate()
    let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    clock = timer
  }

  private func tick() {
    guard let now = current, now.playing, let node = player.lastRenderTime,
          let time = player.playerTime(forNodeTime: node), time.sampleRate > 0 else { return }
    onPosition?(now.page, now.beat, max(0, Double(time.sampleTime) / time.sampleRate), playingDuration)
  }

  // MARK: Audio files

  /// The beat's saved audio, synthesised first if it isn't there; a beat already being made is waited for, not made
  /// twice. Nil when Kokoro can't.
  private func audioFile(for beat: Beat) async -> URL? {
    if FileManager.default.fileExists(atPath: beat.file.path) { return beat.file }
    if let making = making[beat.file] { return await making.value }
    let task = Task<URL?, Never> {
      guard let made = try? await synthesize(beat.say, nil) else { return nil }
      try? FileManager.default.createDirectory(at: beat.file.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard (try? made.data.write(to: beat.file, options: .atomic)) != nil else { return nil }
      return beat.file
    }
    making[beat.file] = task
    let file = await task.value
    making[beat.file] = nil
    return file
  }

  private static func buffer(of file: URL) -> AVAudioPCMBuffer? {
    guard let audio = try? AVAudioFile(forReading: file), audio.length > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
          (try? audio.read(into: buffer)) != nil else { return nil }
    return buffer
  }
}
