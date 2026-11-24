import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Command Center clips and explainers (spec 2026-11-01-command-center-design.md §4): an H.264 MP4 writer that takes
/// a time for every frame, so it serves constant-rate renders and variable-gap screencasts alike. Video only; add the
/// narration afterwards with `VideoMux.addAudio`.
///
/// `@unchecked Sendable`: the caller uses one writer from one serial context (a queue or one task at a time). Kit builds
/// in Swift 5 mode, so the compiler won't flag a second thread. There's no lock; don't share a writer.
///
/// Backpressure: `append` never waits and never crashes. It returns false when the encoder isn't ready. A realtime
/// caller (a screencast) drops that frame; a non-realtime caller (a render) waits on `isReady` with a short sleep.
public final class VideoWriter: @unchecked Sendable {
  public enum Failure: Error, LocalizedError {
    case noFrames, notWriting, closeStalled

    public var errorDescription: String? {
      switch self {
      case .noFrames: return "the video has no frames"
      case .notWriting: return "the video isn't being written"
      case .closeStalled: return "the video file didn't close in time"
      }
    }
  }

  /// The longest `finish` waits for the file to close. It rewrites the file with the moov atom first, which takes seconds
  /// at the sizes written here, so a wait this long means it's stuck.
  static let closeLimitSeconds = 120.0

  private static let timescale: CMTimeScale = 90_000
  private static let canvasGray: CGFloat = 0.06

  private let url: URL
  private let width: Int
  private let height: Int
  private let fps: Int
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  private var firstTime = CMTime.invalid
  private var lastTime = CMTime.invalid
  private var finished = false
  private var closing = false
  public private(set) var frames = 0

  /// How long `finish` waits. Tests shorten it.
  var closeLimit = VideoWriter.closeLimitSeconds
  /// Starts the close and calls back when it's over. Tests replace it with one that doesn't call back.
  var startClosing: (AVAssetWriter, @escaping @Sendable () -> Void) -> Void = { writer, done in
    writer.finishWriting(completionHandler: done)
  }

  /// - keyframeSeconds: the longest the video may go between keyframes (matters when gaps between frames are long).
  /// - realtime: true for a live source that can't wait for the encoder.
  public init(url: URL, width: Int, height: Int, bitrate: Int, fps: Int, keyframeSeconds: Double, realtime: Bool) throws {
    try? FileManager.default.removeItem(at: url)
    self.url = url
    self.width = width
    self.height = height
    self.fps = fps
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true   // the moov atom first, so it plays while it loads
    let settings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: fps * Int(max(keyframeSeconds, 1).rounded(.up)),
        AVVideoMaxKeyFrameIntervalDurationKey: keyframeSeconds,   // by the clock, not by frame count: frames can be seconds apart
        AVVideoAllowFrameReorderingKey: false,                    // no B-frames, so a frame's decode time is its show time
        AVVideoExpectedSourceFrameRateKey: fps,
      ],
    ]
    input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = realtime
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? Failure.notWriting }
    // The session starts at the first frame (see `append`), so the video has no blank lead-in.
  }

  /// Whether the encoder can take another frame now.
  public var isReady: Bool { !finished && writer.status == .writing && input.isReadyForMoreMediaData }

  /// Adds a frame shown from `seconds` until the next frame. The picture is fitted to the canvas, centred on dark,
  /// whatever its size. False, and nothing written, when the encoder isn't ready, the time isn't later than the last
  /// frame's, or the picture couldn't be drawn. The video starts at the first frame's time: a first frame at 0.5 s plays
  /// at 0 in the file, and `finish(at:)` counts from there.
  public func append(_ image: CGImage, at seconds: Double) -> Bool {
    // A render loop may never suspend, so autoreleased pixel data is freed here, not when the loop yields.
    autoreleasepool {
      guard isReady, seconds >= 0, seconds.isFinite, let pool = adaptor.pixelBufferPool else { return false }
      let time = CMTime(value: CMTimeValue((seconds * Double(Self.timescale)).rounded()), timescale: Self.timescale)
      if lastTime.isValid, time <= lastTime { return false }
      var buffer: CVPixelBuffer?
      guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
            draw(image, into: buffer) else { return false }
      if !firstTime.isValid { writer.startSession(atSourceTime: time) }
      guard adaptor.append(buffer, withPresentationTime: time) else { return false }
      if !firstTime.isValid { firstTime = time }
      lastTime = time
      frames += 1
      return true
    }
  }

  /// Ends the video at `seconds` on the same clock as `append`: the last frame is shown until then (at least one frame's
  /// time, if that is earlier).
  /// Throws when no frame was written or the file couldn't be completed in time; the partial file is removed.
  public func finish(at seconds: Double) async throws {
    guard !finished else { throw Failure.notWriting }
    guard frames > 0, writer.status == .writing else {
      cancel()
      throw writer.error ?? Failure.noFrames
    }
    finished = true
    let floor = lastTime + CMTime(value: 1, timescale: CMTimeScale(fps))
    let end = CMTime(value: CMTimeValue((seconds * Double(Self.timescale)).rounded()), timescale: Self.timescale)
    writer.endSession(atSourceTime: max(end, floor))
    input.markAsFinished()
    closing = true
    let writer = writer, url = url
    let closed = await VideoLimit.called(within: closeLimit) { done in
      // A queue of its own: this waiting call can't come back while the block it's in is still running.
      DispatchQueue(label: "dev.glance.video.close").async { self.startClosing(self.writer, done) }
    } whenLate: {
      try? FileManager.default.removeItem(at: url)   // we already said it failed, so the file it finally made isn't wanted
    }
    guard closed else {
      try? FileManager.default.removeItem(at: url)
      throw Failure.closeStalled
    }
    guard writer.status == .completed else {
      let error = writer.error ?? Failure.notWriting
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  /// Stops and removes the partial file. A video that was finished is left alone.
  public func cancel() {
    if writer.status == .completed { return }
    finished = true
    if writer.status == .writing, !closing { writer.cancelWriting() }
    try? FileManager.default.removeItem(at: url)
  }

  /// Aspect-fit into the pixel buffer: the whole picture, centred, on a dark canvas.
  /// False when the pixel buffer couldn't be drawn into (the frame must not be written with stale pixels).
  private func draw(_ image: CGImage, into buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return false }
    context.setFillColor(CGColor(gray: Self.canvasGray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height))
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    return true
  }
}

/// Puts a narration or soundtrack into a video made by `VideoWriter`.
public enum VideoMux {
  public enum Failure: Error, LocalizedError {
    case missingTrack, emptyAudio, outputIsAnInput, readerFailed, writerFailed, stalled

    public var errorDescription: String? {
      switch self {
      case .missingTrack: return "the video or the audio has no track to use"
      case .emptyAudio: return "the audio is empty"
      case .outputIsAnInput: return "the output can't be one of the inputs"
      case .readerFailed: return "the video or the audio couldn't be read"
      case .writerFailed: return "the video couldn't be written"
      case .stalled: return "reading and writing the video stopped making progress"
      }
    }
  }

  /// How long each stage may go without getting anywhere before the mux fails with `Failure.stalled`.
  struct Limits: Sendable {
    /// Opening the two files.
    var prepare: TimeInterval = 30
    /// No sample moved. A mux moves thousands a second, so this is a read or a write that isn't coming back.
    var stall: TimeInterval = 30
    /// Closing the file, once every sample is in.
    var close: TimeInterval = VideoWriter.closeLimitSeconds
    /// Stopping the reader and writer after a failure, before the caller is told anyway.
    var cleanup: TimeInterval = 5
  }

  /// Run before the blocking calls, so a test can make them block.
  struct Hooks: Sendable {
    var beforePrepare: (@Sendable () async -> Void)?
    var beforeRead: (@Sendable () -> Void)?
    var beforeClose: (@Sendable () -> Void)?
    /// Stands in for `finishWriting`: starts the close and calls back when it's over.
    var startClosing: (@Sendable (AVAssetWriter, @escaping @Sendable () -> Void) -> Void)?
  }

  /// Writes `output`: the video's samples as they are (no re-encode) and `audio` as AAC-LC 48 kHz stereo, ending at the
  /// video's duration. Audio longer than the video is cut; shorter audio leaves the rest silent. Cancelling the task
  /// stops the work at once and removes `output`, and a mux that stops making progress fails with `Failure.stalled`.
  /// `output` can't be `video` or `audio`.
  public static func addAudio(video: URL, audio: URL, to output: URL, audioBitrate: Int = 128_000) async throws {
    try await addAudio(video: video, audio: audio, to: output, audioBitrate: audioBitrate, limits: Limits(), hooks: Hooks())
  }

  static func addAudio(video: URL, audio: URL, to output: URL, audioBitrate: Int = 128_000, limits: Limits, hooks: Hooks) async throws {
    let target = output.standardizedFileURL.resolvingSymlinksInPath()
    guard target != video.standardizedFileURL.resolvingSymlinksInPath(),
          target != audio.standardizedFileURL.resolvingSymlinksInPath() else { throw Failure.outputIsAnInput }
    try? FileManager.default.removeItem(at: output)
    let job = try await VideoLimit.within(limits.prepare, failing: Failure.stalled) {
      await hooks.beforePrepare?()
      return try await makeJob(video: video, audio: audio, output: output, audioBitrate: audioBitrate, limits: limits, hooks: hooks)
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        job.start(continuation)
      }
    } onCancel: {
      job.fail(CancellationError())
    }
  }

  private static func makeJob(video: URL, audio: URL, output: URL, audioBitrate: Int, limits: Limits, hooks: Hooks) async throws -> Job {
    let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
    guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
          let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw Failure.missingTrack }
    guard try await audioAsset.load(.duration).seconds > 0 else { throw Failure.emptyAudio }
    let duration = try await videoAsset.load(.duration)

    let videoReader = try AVAssetReader(asset: videoAsset)
    let audioReader = try AVAssetReader(asset: audioAsset)
    audioReader.timeRange = CMTimeRange(start: .zero, duration: duration)   // the cut
    let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)   // compressed samples, as they are
    let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    videoReader.add(videoOut)
    audioReader.add(audioOut)

    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let format = try await videoTrack.load(.formatDescriptions).first
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
    let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: audioBitrate,
    ])
    writer.add(videoIn)
    writer.add(audioIn)
    return Job(writer: writer, pumps: [
      Job.Pump(output: videoOut, reader: videoReader, input: videoIn, queue: DispatchQueue(label: "dev.glance.mux.0")),
      Job.Pump(output: audioOut, reader: audioReader, input: audioIn, queue: DispatchQueue(label: "dev.glance.mux.1")),
    ], output: output, duration: duration, limits: limits, hooks: hooks)
  }

  /// One mux in flight. Every way it can end goes through `fail` or the file closing, and only the first of those counts.
  ///
  /// `fail` runs on whoever cancels, which can be the main actor, and `copyNextSampleBuffer` can block for as long as
  /// CoreMedia likes, so nothing here that a caller waits on is held across an AVFoundation call:
  /// - `lock` guards the state and is held only to read and write it.
  /// - Each pump's reader and input are used only on its own queue. `cancelReading` while a `copyNextSampleBuffer` is in
  ///   flight crashes inside the read's wait, so a stuck read keeps its queue, and the reader, until it comes back; the
  ///   cancel waits its turn on that queue.
  /// - `writing` keeps `append` and `markAsFinished` from overlapping `cancelWriting`. Only the pumps' and `control` queues
  ///   take it.
  /// - Starting, closing and cleaning up run on `control`.
  /// These are plain serial queues, which keep running when CoreMedia's own work doesn't: with a CPU's worth of cooperative
  /// threads blocked, reads and closes stop being served until one frees up. So no blocking AVFoundation call may run on a
  /// cooperative thread, and a read can stall for reasons that have nothing to do with this mux.
  private final class Job: @unchecked Sendable {
    struct Pump {
      let output: AVAssetReaderTrackOutput
      let reader: AVAssetReader
      let input: AVAssetWriterInput
      let queue: DispatchQueue
    }

    private let writer: AVAssetWriter
    private let pumps: [Pump]
    private let output: URL
    private let duration: CMTime
    private let limits: Limits
    private let hooks: Hooks
    private let control = DispatchQueue(label: "dev.glance.mux.control")
    private let watch = DispatchQueue(label: "dev.glance.mux.watch")
    private let writing = NSLock()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var ended = false
    private var closing = false
    private var pumpsLeft: Int
    private var lastProgress = DispatchTime.now()
    private var watchdog: DispatchSourceTimer?

    init(writer: AVAssetWriter, pumps: [Pump], output: URL, duration: CMTime, limits: Limits, hooks: Hooks) {
      self.writer = writer
      self.pumps = pumps
      self.output = output
      self.duration = duration
      self.limits = limits
      self.hooks = hooks
      pumpsLeft = pumps.count
    }

    /// Returns at once; runs on the caller's cooperative thread, so the blocking calls go to `control`.
    func start(_ continuation: CheckedContinuation<Void, Error>) {
      // A failed writer may not call the pumps again, and a stuck read or close never reports anything; look for both.
      let timer = DispatchSource.makeTimerSource(queue: watch)
      timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
      timer.setEventHandler { [self] in check() }
      timer.resume()
      lock.lock()
      if let failure {   // cancelled before the work began
        lock.unlock()
        timer.cancel()
        continuation.resume(throwing: failure)
        return
      }
      self.continuation = continuation
      watchdog = timer
      lastProgress = .now()
      lock.unlock()
      control.async { [self] in begin() }
    }

    /// The first call wins: fails the job and hands the cleanup to `control`, so it never blocks the caller. The waiting
    /// call is resumed when the cleanup is done, or after `limits.cleanup` if the cleanup is itself stuck.
    func fail(_ error: Error) {
      lock.lock()
      guard !ended else { lock.unlock(); return }
      ended = true
      failure = error
      let timer = watchdog
      watchdog = nil
      lock.unlock()
      timer?.cancel()
      control.async { [self] in cleanUp() }
      VideoLimit.queue.asyncAfter(deadline: .now() + limits.cleanup) { [self] in resumeWithFailure(removingOutput: true) }
    }

    private var isOver: Bool {
      lock.lock()
      defer { lock.unlock() }
      return ended
    }

    private func madeProgress() {
      lock.lock()
      lastProgress = .now()
      lock.unlock()
    }

    private func check() {
      lock.lock()
      let over = ended
      let limit = closing ? limits.close : limits.stall
      let quiet = Double(DispatchTime.now().uptimeNanoseconds - lastProgress.uptimeNanoseconds) / 1e9
      lock.unlock()
      if over { return }
      if quiet > limit { return fail(Failure.stalled) }
      if writer.status == .failed || writer.status == .cancelled { fail(writer.error ?? Failure.writerFailed) }
    }

    /// On `control`.
    private func begin() {
      if isOver { return }
      for pump in pumps {
        guard pump.reader.startReading() else { return fail(pump.reader.error ?? Failure.readerFailed) }
      }
      guard writer.startWriting() else { return fail(writer.error ?? Failure.writerFailed) }
      writer.startSession(atSourceTime: .zero)
      for pump in pumps {
        pump.input.requestMediaDataWhenReady(on: pump.queue) { [self] in move(pump) }
      }
    }

    /// On the pump's queue: moves samples while the writer wants them; ends the input when the reader has none left.
    private func move(_ pump: Pump) {
      while !isOver, pump.input.isReadyForMoreMediaData {
        hooks.beforeRead?()
        guard let sample = pump.output.copyNextSampleBuffer() else {
          if pump.reader.status == .failed { fail(pump.reader.error ?? Failure.readerFailed) }
          else { end(pump) }
          return
        }
        madeProgress()
        writing.lock()
        if isOver { writing.unlock(); return }
        let appended = pump.input.append(sample)
        writing.unlock()
        if !appended { return fail(writer.error ?? Failure.writerFailed) }
      }
    }

    /// On the pump's queue.
    private func end(_ pump: Pump) {
      writing.lock()
      if isOver { writing.unlock(); return }
      pump.input.markAsFinished()
      writing.unlock()
      lock.lock()
      pumpsLeft -= 1
      let last = pumpsLeft == 0 && !ended
      lastProgress = .now()
      lock.unlock()
      if last { control.async { [self] in close() } }
    }

    /// On `control`.
    private func close() {
      hooks.beforeClose?()
      lock.lock()
      if ended { lock.unlock(); return }
      closing = true
      lastProgress = .now()
      lock.unlock()
      writer.endSession(atSourceTime: duration)
      if let startClosing = hooks.startClosing {
        startClosing(writer) { [self] in closed() }
      } else {
        writer.finishWriting { [self] in closed() }
      }
    }

    private func closed() {
      let completed = writer.status == .completed
      lock.lock()
      if ended {   // we gave up on it, so the file it finally made isn't wanted
        lock.unlock()
        try? FileManager.default.removeItem(at: output)
        return
      }
      guard completed else {
        lock.unlock()
        return fail(writer.error ?? Failure.writerFailed)
      }
      ended = true
      let waiting = continuation
      continuation = nil
      let timer = watchdog
      watchdog = nil
      lock.unlock()
      timer?.cancel()
      waiting?.resume()
    }

    /// On `control`, after `fail`.
    private func cleanUp() {
      for pump in pumps {
        pump.queue.async { if pump.reader.status == .reading { pump.reader.cancelReading() } }
      }
      writing.lock()
      lock.lock()
      let open = !closing   // a close in flight can't be cancelled; `closed` removes what it makes
      lock.unlock()
      if open, writer.status == .writing { writer.cancelWriting() }
      writing.unlock()
      try? FileManager.default.removeItem(at: output)
      resumeWithFailure()
    }

    /// `removingOutput`: the cleanup is stuck behind a call that hasn't come back, so it hasn't removed the file yet. Only
    /// done while the caller is still waiting: once it has its answer, the path may be in use again.
    private func resumeWithFailure(removingOutput: Bool = false) {
      lock.lock()
      let waiting = continuation
      continuation = nil
      let failure = failure
      lock.unlock()
      guard let waiting, let failure else { return }
      if removingOutput { try? FileManager.default.removeItem(at: output) }
      waiting.resume(throwing: failure)
    }
  }
}

/// Waiting on AVFoundation with a limit. The limit runs on a plain serial queue, so it fires even when CoreMedia's own work
/// is stuck.
enum VideoLimit {
  static let queue = DispatchQueue(label: "dev.glance.video.limit")

  /// Hands over the first result; later ones are dropped.
  private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?

    func wait(_ continuation: CheckedContinuation<T, Error>) {
      lock.lock()
      if let result {
        lock.unlock()
        continuation.resume(with: result)
        return
      }
      self.continuation = continuation
      lock.unlock()
    }

    /// False when a result had already come.
    @discardableResult
    func resolve(_ value: Result<T, Error>) -> Bool {
      lock.lock()
      if result != nil { lock.unlock(); return false }
      result = value
      let waiting = continuation
      continuation = nil
      lock.unlock()
      waiting?.resume(with: value)
      return true
    }
  }

  /// `body`'s result, or `error` once `seconds` have passed. Cancelling returns at once with `CancellationError`.
  static func within<T>(_ seconds: TimeInterval, failing error: Error, _ body: @escaping () async throws -> T) async throws -> T {
    let once = Once<T>()
    let work = Task {
      do { once.resolve(.success(try await body())) } catch { once.resolve(.failure(error)) }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        once.wait(continuation)
        queue.asyncAfter(deadline: .now() + seconds) {
          once.resolve(.failure(error))
          work.cancel()
        }
      }
    } onCancel: {
      once.resolve(.failure(CancellationError()))
      work.cancel()
    }
  }

  /// Whether `start` called back within `seconds`. `whenLate` runs if it called back after that. The limit is armed first.
  /// `start` runs at once on the caller's actor, so a main-actor caller hands its work off even with the cooperative pool
  /// full. It must hand off anything that can block: this call can't come back while `start` is running, and in a full pool
  /// its answer waits for a cooperative thread, even on the main actor (measured on macOS 27).
  static func called(within seconds: TimeInterval, isolation: isolated (any Actor)? = #isolation,
                     start: (@escaping @Sendable () -> Void) -> Void,
                     whenLate: @escaping @Sendable () -> Void) async -> Bool {
    let once = Once<Bool>()
    let called = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
      once.wait(continuation)
      queue.asyncAfter(deadline: .now() + seconds) { once.resolve(.success(false)) }
      start { if !once.resolve(.success(true)) { whenLate() } }
    }
    return called ?? false
  }
}

/// A still and a length for a finished video, for the Assets grid and the timeline.
///
/// Both go through `MediaGate`: on threads of its own and not the cooperative pool, two at a time, each with a time limit
/// (nil after it, so a tile shows its placeholder instead of waiting for ever). A grid can ask for dozens at once.
public enum VideoThumbnail {
  /// How long one read waits for AVFoundation, a little under the gate's limit so that the thread is not left behind.
  private static let wait: TimeInterval = 8

  private final class Box<T>: @unchecked Sendable { var value: T? }

  /// The first frame, scaled to fit `maxSide` points on its longer side. Nil when the file can't be read.
  public static func image(of url: URL, maxSide: Int) async -> CGImage? {
    await MediaGate.shared.run { firstFrame(of: url, maxSide: maxSide, wait: wait) }
  }

  /// Seconds, or nil when the file can't be read or has no length.
  public static func duration(of url: URL) async -> Double? {
    await MediaGate.shared.run { length(of: url, wait: wait) }
  }

  /// Blocks the calling thread up to `wait`: call it only from a thread that may be blocked.
  static func firstFrame(of url: URL, maxSide: Int, wait: TimeInterval) -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    let box = Box<CGImage>(), done = DispatchSemaphore(value: 0)
    generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
      box.value = image
      done.signal()
    }
    if done.wait(timeout: .now() + wait) == .timedOut {
      generator.cancelAllCGImageGeneration()
      return nil
    }
    return box.value
  }

  static func length(of url: URL, wait: TimeInterval) -> Double? {
    let asset = AVURLAsset(url: url)
    let box = Box<Double>(), done = DispatchSemaphore(value: 0)
    let task = Task.detached {
      if let time = try? await asset.load(.duration), time.isNumeric, time.seconds > 0 { box.value = time.seconds }
      done.signal()
    }
    if done.wait(timeout: .now() + wait) == .timedOut {
      task.cancel()
      return nil
    }
    return box.value
  }
}

/// A picture's thumbnail for the Assets grid, decoded through the same kind of gate as a video's: threads of its own, a
/// few at a time, a time limit. (ImageIO on a global utility queue would not be served while the cooperative pool is
/// blocked.)
public enum PictureThumbnail {
  private static let gate = MediaGate(width: 3, limit: 10, maxAbandoned: 4)

  /// The picture scaled so its longer side is at most `maxPixel` pixels, honouring its orientation. Nil when the file
  /// is missing or isn't a picture ImageIO reads.
  public static func image(of url: URL, maxPixel: Int) async -> CGImage? {
    await gate.run {
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
      let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceShouldCache: false,
                                      kCGImageSourceThumbnailMaxPixelSize: maxPixel]
      return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
  }
}
