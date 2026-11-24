import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import GlanceKit

// MARK: helpers

private func tempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("videowriter-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func solidImage(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
  let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
  return ctx.makeImage()!
}

/// The red, green, blue (0...255) of the pixel at x, y (y counts from the top).
private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
  var bytes = [UInt8](repeating: 0, count: 4)
  let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
  return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

private func sineWAV(at url: URL, seconds: Double) throws {
  let rate = 44100.0
  let count = Int(seconds * rate)
  let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
  let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
  buffer.frameLength = AVAudioFrameCount(count)
  for i in 0..<count { buffer.int16ChannelData![0][i] = Int16(sin(2 * .pi * 440 * Double(i) / rate) * 8000) }
  try file.write(from: buffer)
}

/// Waits for the encoder, then appends (what a non-realtime caller does).
@discardableResult
private func appendWhenReady(_ writer: VideoWriter, _ image: CGImage, at seconds: Double) async -> Bool {
  while !writer.isReady { try? await Task.sleep(nanoseconds: 1_000_000) }
  return writer.append(image, at: seconds)
}

private struct VideoInfo {
  var codec: FourCharCode = 0
  var size = CGSize.zero
  var times: [Double] = []
  var sampleSizes: [Int] = []
  var duration = 0.0
  var audioCodec: FourCharCode?
}

private func inspect(_ url: URL) async throws -> VideoInfo {
  let asset = AVURLAsset(url: url)
  var info = VideoInfo()
  info.duration = try await asset.load(.duration).seconds
  if let audio = try await asset.loadTracks(withMediaType: .audio).first,
     let format = try await audio.load(.formatDescriptions).first {
    info.audioCodec = CMFormatDescriptionGetMediaSubType(format)
  }
  guard let video = try await asset.loadTracks(withMediaType: .video).first else { return info }
  if let format = try await video.load(.formatDescriptions).first { info.codec = CMFormatDescriptionGetMediaSubType(format) }
  info.size = try await video.load(.naturalSize)
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
  reader.add(output)
  reader.startReading()
  let loaded = info
  return try await onOwnThread {
    var info = loaded
    while let buffer = output.copyNextSampleBuffer() {
      // A buffer from the reader can hold several samples; list each one.
      var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: CMSampleBufferGetNumSamples(buffer))
      var timingCount = 0
      CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: timings.count, arrayToFill: &timings, entriesNeededOut: &timingCount)
      info.times += timings.map { $0.presentationTimeStamp.seconds }
      var sizes = [Int](repeating: 0, count: timings.count)
      var sizeCount = 0
      CMSampleBufferGetSampleSizeArray(buffer, entryCount: sizes.count, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
      info.sampleSizes += sizes
    }
    return info
  }
}

/// A video of `count` frames at `fps`, written the way a non-realtime caller does.
private func makeVideo(at url: URL, count: Int, fps: Int = 30) async throws {
  let writer = try VideoWriter(url: url, width: 1280, height: 720, bitrate: 2_000_000, fps: fps, keyframeSeconds: 2, realtime: false)
  for i in 0..<count {
    let shade = CGFloat(i % 10) / 10
    await appendWhenReady(writer, solidImage(640, 360, red: shade, green: 0.4, blue: 1 - shade), at: Double(i) / Double(fps))
  }
  try await writer.finish(at: Double(count) / Double(fps))
}

// MARK: tests

@Test func ninetyFramesAtThirtyFpsAreThreeSecondsOfH264() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("a.mp4")
  try await makeVideo(at: url, count: 90)
  let info = try await inspect(url)
  #expect(info.codec == kCMVideoCodecType_H264)
  #expect(info.times.count == 90)
  #expect(abs(info.duration - 3.0) < 0.02)
  #expect(info.size == CGSize(width: 1280, height: 720))
  #expect(info.audioCodec == nil)
}

@Test func irregularGapsKeepIncreasingTimesAndTheEndTime() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("b.mp4")
  let writer = try VideoWriter(url: url, width: 1280, height: 720, bitrate: 2_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  let gaps = [0.016, 0.05, 0.3, 2.0, 0.033, 0.016, 1.0, 0.1]
  var t = 0.0
  var expected: [Double] = []
  for i in 0..<24 {
    expected.append(t)
    #expect(await appendWhenReady(writer, solidImage(1280, 720, red: CGFloat(i % 2), green: 0.3, blue: 0.5), at: t))
    t += gaps[i % gaps.count]
  }
  #expect(writer.frames == 24)
  try await writer.finish(at: t)
  let info = try await inspect(url)
  #expect(info.times.count == 24)
  #expect(zip(info.times, info.times.dropFirst()).allSatisfy { $0 < $1 })
  for (got, want) in zip(info.times, expected) { #expect(abs(got - want) < 0.002) }
  #expect(abs(info.duration - t) < 0.05)
}

@Test func aWiderFrameMidStreamFitsTheCanvasOnDark() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("c.mp4")
  let writer = try VideoWriter(url: url, width: 1280, height: 720, bitrate: 4_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(await appendWhenReady(writer, solidImage(1280, 720, red: 0, green: 0.8, blue: 0), at: 0))
  #expect(await appendWhenReady(writer, solidImage(1600, 400, red: 1, green: 0, blue: 0), at: 0.5))
  try await writer.finish(at: 1.0)
  let info = try await inspect(url)
  #expect(info.size == CGSize(width: 1280, height: 720))
  #expect(info.times.count == 2)

  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  let wide = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 90000)).image
  #expect(wide.width == 1280 && wide.height == 720)
  let top = pixel(wide, 640, 20)       // above the 1280x320 picture: the dark canvas
  let middle = pixel(wide, 640, 360)   // inside it: red
  #expect(top.r < 50 && top.g < 50 && top.b < 50)
  #expect(middle.r > 150 && middle.g < 90 && middle.b < 90)
}

@Test func timesThatDoNotIncreaseAreRefused() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let writer = try VideoWriter(url: dir.appendingPathComponent("d.mp4"), width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  let image = solidImage(640, 360, red: 0.2, green: 0.2, blue: 0.2)
  #expect(!writer.append(image, at: -0.5))
  #expect(writer.append(image, at: 1.0))
  #expect(!writer.append(image, at: 1.0))
  #expect(!writer.append(image, at: 0.5))
  #expect(await appendWhenReady(writer, image, at: 1.5))
  #expect(writer.frames == 2)
  writer.cancel()
}

@Test func cancelLeavesNoFile() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("e.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(writer.append(solidImage(640, 360, red: 0.5, green: 0.5, blue: 0.5), at: 0))
  writer.cancel()
  #expect(!FileManager.default.fileExists(atPath: url.path))
  #expect(!writer.isReady)
  #expect(!writer.append(solidImage(640, 360, red: 0.5, green: 0.5, blue: 0.5), at: 1))
}

@Test func finishingWithoutFramesThrowsAndLeavesNoFile() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("f.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  await #expect(throws: (any Error).self) { try await writer.finish(at: 1) }
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func audioIsAddedAsAACAndTheVideoSamplesAreUntouched() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("s.wav")
  let output = dir.appendingPathComponent("out.mp4")
  try await makeVideo(at: video, count: 60)
  try sineWAV(at: wav, seconds: 2.0)
  try await VideoMux.addAudio(video: video, audio: wav, to: output)

  let before = try await inspect(video)
  let after = try await inspect(output)
  #expect(after.codec == kCMVideoCodecType_H264)
  #expect(after.audioCodec == kAudioFormatMPEG4AAC)
  #expect(after.times == before.times)
  #expect(after.sampleSizes == before.sampleSizes)
  #expect(abs(after.duration - before.duration) < 0.1)
}

@Test func audioLongerThanTheVideoIsCutAtTheVideosEnd() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("long.wav")
  let output = dir.appendingPathComponent("out.mp4")
  try await makeVideo(at: video, count: 30)   // 1 s
  try sineWAV(at: wav, seconds: 4.0)
  try await VideoMux.addAudio(video: video, audio: wav, to: output)

  let after = try await inspect(output)
  #expect(after.audioCodec == kAudioFormatMPEG4AAC)
  #expect(after.duration < 1.1)
  #expect(after.duration > 0.9)
}

@Test func theThumbnailAndDurationComeFromTheFile() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("t.mp4")
  try await makeVideo(at: video, count: 45)
  let image = await VideoThumbnail.image(of: video, maxSide: 320)
  #expect(image != nil)
  #expect(max(image?.width ?? 0, image?.height ?? 0) <= 320)
  let duration = await VideoThumbnail.duration(of: video)
  #expect(abs((duration ?? 0) - 1.5) < 0.05)
  #expect(await VideoThumbnail.image(of: dir.appendingPathComponent("missing.mp4"), maxSide: 320) == nil)
  #expect(await VideoThumbnail.duration(of: dir.appendingPathComponent("missing.mp4")) == nil)
}

// MARK: fix round

@Test func cancelAfterAFinishedVideoKeepsTheVideo() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("g.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(await appendWhenReady(writer, solidImage(640, 360, red: 0.5, green: 0.5, blue: 0.5), at: 0))
  try await writer.finish(at: 1)
  writer.cancel()
  #expect(FileManager.default.fileExists(atPath: url.path))
  #expect(try await inspect(url).times.count == 1)
}

@Test func aFirstFrameAfterZeroLeavesNoBlankLeadIn() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("h.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(await appendWhenReady(writer, solidImage(640, 360, red: 0.9, green: 0.1, blue: 0.1), at: 0.5))
  #expect(await appendWhenReady(writer, solidImage(640, 360, red: 0.1, green: 0.9, blue: 0.1), at: 1.0))
  try await writer.finish(at: 1.5)   // one second of video: from the first frame to here
  let info = try await inspect(url)
  #expect(info.times.count == 2)
  #expect(abs((info.times.first ?? 9) - 0) < 0.002)
  #expect(abs((info.times.last ?? 9) - 0.5) < 0.002)
  #expect(abs(info.duration - 1.0) < 0.05)
  let thumbnail = await VideoThumbnail.image(of: url, maxSide: 320)
  #expect(thumbnail != nil)
  if let thumbnail { #expect(pixel(thumbnail, thumbnail.width / 2, thumbnail.height / 2).r > 150) }   // the first frame, not the canvas
}

@Test func audioShorterThanTheVideoLeavesTheRestSilent() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("short.wav")
  let output = dir.appendingPathComponent("out.mp4")
  try await makeVideo(at: video, count: 60)   // 2 s
  try sineWAV(at: wav, seconds: 0.5)
  try await VideoMux.addAudio(video: video, audio: wav, to: output)
  let after = try await inspect(output)
  #expect(after.audioCodec == kAudioFormatMPEG4AAC)
  #expect(after.times.count == 60)
  #expect(abs(after.duration - 2.0) < 0.1)
}

@Test func anAudioFileWithNoSamplesFailsAndLeavesNoOutput() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("empty.wav")
  let output = dir.appendingPathComponent("out.mp4")
  try await makeVideo(at: video, count: 30)
  do {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
    _ = try AVAudioFile(forWriting: wav, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
  }
  await #expect(throws: VideoMux.Failure.self) { try await VideoMux.addAudio(video: video, audio: wav, to: output) }
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test func theOutputCanNotBeTheVideoOrTheAudio() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("s.wav")
  try await makeVideo(at: video, count: 30)
  try sineWAV(at: wav, seconds: 1)
  await #expect(throws: VideoMux.Failure.self) { try await VideoMux.addAudio(video: video, audio: wav, to: video) }
  await #expect(throws: VideoMux.Failure.self) { try await VideoMux.addAudio(video: video, audio: wav, to: wav) }
  #expect(FileManager.default.fileExists(atPath: video.path))
  #expect(FileManager.default.fileExists(atPath: wav.path))
  #expect(try await inspect(video).times.count == 30)
}

@Test func aFileThatIsNotAVideoGivesNoThumbnailOrDuration() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("broken.mp4")
  try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
  #expect(await VideoThumbnail.image(of: url, maxSide: 320) == nil)
  #expect(await VideoThumbnail.duration(of: url) == nil)
}

@Test(.timeLimit(.minutes(1)))
func cancellingALongMuxReturnsPromptlyAndLeavesNoOutput() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let video = dir.appendingPathComponent("v.mp4")
  let wav = dir.appendingPathComponent("long.wav")
  let output = dir.appendingPathComponent("out.mp4")
  // Three frames spread over 20 minutes (tiny to write), with 20 minutes of audio to encode.
  let writer = try VideoWriter(url: video, width: 320, height: 180, bitrate: 500_000, fps: 30, keyframeSeconds: 2, realtime: false)
  for i in 0..<3 { await appendWhenReady(writer, solidImage(320, 180, red: CGFloat(i) / 3, green: 0.2, blue: 0.2), at: Double(i) * 400) }
  try await writer.finish(at: 1200)
  try sineWAV(at: wav, seconds: 1200)

  let started = Date()
  let task = Task { try await VideoMux.addAudio(video: video, audio: wav, to: output) }
  try await Task.sleep(nanoseconds: 100_000_000)
  task.cancel()
  await #expect(throws: (any Error).self) { try await task.value }
  #expect(Date().timeIntervalSince(started) < 5)
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

// MARK: a read or a close that doesn't come back

/// A short video and a second of audio to mux.
private func muxInputs(in dir: URL) async throws -> (video: URL, audio: URL, output: URL) {
  let video = dir.appendingPathComponent("v.mp4")
  let audio = dir.appendingPathComponent("s.wav")
  try await makeVideo(at: video, count: 30)
  try sineWAV(at: audio, seconds: 1)
  return (video, audio, dir.appendingPathComponent("out.mp4"))
}

@Test(.timeLimit(.minutes(1)))
func aReadThatDoesNotComeBackFailsTheMuxInBoundedTime() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (video, audio, output) = try await muxInputs(in: dir)
  let gate = SelfOpeningGate(opensAfter: 15)
  defer { gate.open() }
  let hooks = VideoMux.Hooks(beforeRead: { gate.wait() })

  let started = Date()
  await #expect(throws: VideoMux.Failure.stalled) {
    try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(stall: 0.5), hooks: hooks)
  }
  #expect(Date().timeIntervalSince(started) < 10)   // well before the gate opens
  #expect(!FileManager.default.fileExists(atPath: output.path))
  #expect(VideoMux.Failure.stalled.localizedDescription.contains("progress"))
}

@Test(.timeLimit(.minutes(1)))
func cancellingWhileAReadIsStuckReturnsAtOnceAndTheReadCanComeBackLater() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (video, audio, output) = try await muxInputs(in: dir)
  let gate = SelfOpeningGate(opensAfter: 15)
  defer { gate.open() }
  let inRead = DispatchSemaphore(value: 0)
  let hooks = VideoMux.Hooks(beforeRead: { inRead.signal(); gate.wait() })

  let started = Date()
  let task = Task { try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(stall: 600), hooks: hooks) }
  #expect(try await reached(inRead))

  // A task's onCancel runs on the canceller's thread, and in the app that's the main actor (ExplainerRun.cancel).
  let cancelTook = try await onOwnThread { () -> TimeInterval in
    let before = Date()
    task.cancel()
    return Date().timeIntervalSince(before)
  }
  #expect(cancelTook < 1)
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(Date().timeIntervalSince(started) < 10)   // well before the gate opens
  #expect(!FileManager.default.fileExists(atPath: output.path))

  // The read comes back to a finished job: it touches nothing and the reader is stopped on its own queue.
  gate.open()
  try await Task.sleep(nanoseconds: 300_000_000)
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test(.timeLimit(.minutes(1)))
func aStuckControlQueueStillEndsTheMuxInBoundedTimeWithItsOutputGone() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (video, audio, output) = try await muxInputs(in: dir)
  let gate = SelfOpeningGate(opensAfter: 15)
  defer { gate.open() }
  // Every sample is in, and `control` sticks before the close starts: the cleanup queues behind it, so only the limit on
  // the cleanup can tell the caller.
  let hooks = VideoMux.Hooks(beforeClose: { gate.wait() })

  let started = Date()
  await #expect(throws: VideoMux.Failure.stalled) {
    try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(stall: 0.5, cleanup: 0.5), hooks: hooks)
  }
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(!FileManager.default.fileExists(atPath: output.path))   // with `control` still stuck

  gate.open()
  try await Task.sleep(nanoseconds: 300_000_000)
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

/// What a stuck close was given, for the test to finish it late.
private final class HeldClose: @unchecked Sendable {
  private let lock = NSLock()
  private var value: (AVAssetWriter, @Sendable () -> Void)?

  func hold(_ writer: AVAssetWriter, _ done: @escaping @Sendable () -> Void) {
    lock.lock()
    value = (writer, done)
    lock.unlock()
  }

  var held: (writer: AVAssetWriter, done: @Sendable () -> Void)? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@Test(.timeLimit(.minutes(1)))
func aFinishWritingThatDoesNotCallBackFailsAtTheCloseLimitAndALateCloseLeavesNoOutput() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (video, audio, output) = try await muxInputs(in: dir)
  let close = HeldClose()
  let hooks = VideoMux.Hooks(startClosing: { writer, done in close.hold(writer, done) })

  // The stall limit is out of reach, so only the close limit can end this.
  let started = Date()
  await #expect(throws: VideoMux.Failure.stalled) {
    try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(stall: 600, close: 0.5), hooks: hooks)
  }
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(!FileManager.default.fileExists(atPath: output.path))
  let held = try #require(close.held, "the mux never reached its close")

  // The close comes back after all. A writer that was cancelled during its close would raise here, and a second resume of
  // the waiting call would trap, so getting through this is the proof of both. What it made isn't wanted.
  let (writer, done) = held
  let closedLate = DispatchSemaphore(value: 0)
  writer.finishWriting {
    FileManager.default.createFile(atPath: output.path, contents: Data([0]))   // a close may leave the file again as it ends
    done()
    closedLate.signal()
  }
  #expect(try await reached(closedLate))
  #expect(writer.status == .completed)
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test(.timeLimit(.minutes(1)))
func filesThatDoNotOpenFailTheMuxInBoundedTimeAndACancelReturnsAtOnce() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (video, audio, output) = try await muxInputs(in: dir)
  let hooks = VideoMux.Hooks(beforePrepare: { try? await Task.sleep(nanoseconds: 30_000_000_000) })

  let started = Date()
  await #expect(throws: VideoMux.Failure.stalled) {
    try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(prepare: 0.3), hooks: hooks)
  }
  #expect(Date().timeIntervalSince(started) < 10)

  let cancelled = Date()
  let task = Task { try await VideoMux.addAudio(video: video, audio: audio, to: output, limits: .init(prepare: 600), hooks: hooks) }
  try await Task.sleep(nanoseconds: 100_000_000)
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(Date().timeIntervalSince(cancelled) < 10)
  #expect(!FileManager.default.fileExists(atPath: output.path))
}

@Test(.timeLimit(.minutes(1)))
func aVideoThatDoesNotCloseFailsInBoundedTimeAndALateCloseLeavesNoFile() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("slow.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(await appendWhenReady(writer, solidImage(640, 360, red: 0.5, green: 0.5, blue: 0.5), at: 0))
  let closedLate = DispatchSemaphore(value: 0)
  writer.closeLimit = 0.2
  writer.startClosing = { real, done in
    nonisolated(unsafe) let real = real
    DispatchQueue(label: "dev.glance.tests.close").asyncAfter(deadline: .now() + 1) {
      real.finishWriting {
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))   // a close may leave the file again as it ends
        done()
        closedLate.signal()
      }
    }
  }

  let started = Date()
  await #expect(throws: VideoWriter.Failure.closeStalled) { try await writer.finish(at: 1) }
  #expect(Date().timeIntervalSince(started) < 1)   // before the close comes back
  #expect(!FileManager.default.fileExists(atPath: url.path))
  writer.cancel()   // what a caller does after a failed finish; a close in flight can't be cancelled

  #expect(try await reached(closedLate))
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test(.timeLimit(.minutes(1)))
func aCloseThatBlocksItsCallerStillHitsTheLimit() async throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("blocking.mp4")
  let writer = try VideoWriter(url: url, width: 640, height: 360, bitrate: 1_000_000, fps: 30, keyframeSeconds: 2, realtime: false)
  #expect(await appendWhenReady(writer, solidImage(640, 360, red: 0.5, green: 0.5, blue: 0.5), at: 0))
  let gate = SelfOpeningGate(opensAfter: 15)
  defer { gate.open() }
  writer.closeLimit = 0.2
  writer.startClosing = { _, _ in gate.wait() }

  let started = Date()
  await #expect(throws: VideoWriter.Failure.closeStalled) { try await writer.finish(at: 1) }
  #expect(Date().timeIntervalSince(started) < 10)   // well before the gate opens
}
