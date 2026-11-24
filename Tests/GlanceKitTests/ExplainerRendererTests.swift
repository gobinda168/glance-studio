import AVFoundation
import CoreGraphics
import Foundation
import GlanceCore
import ImageIO
import Network
import UniformTypeIdentifiers
import Testing
@testable import GlanceKit

// These tests run a real WKWebView, and some of them hang it on purpose. Run them under the perl alarm guard:
//   perl -e 'alarm 300; exec @ARGV' scripts/build.sh test --filter ExplainerRendererTests
// `.timeLimit` only counts whole minutes and can't interrupt a blocked main thread, so the tests assert elapsed time.

// MARK: helpers

private func tempFolder() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent("explainer-render-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private let page = """
  <!doctype html><meta charset="utf-8"><style>
  html,body{margin:0;width:1280px;height:720px;overflow:hidden;background:#000}
  section{position:absolute;left:0;top:0;width:1280px;height:720px}
  </style>
  """

private func voiceNobodyCalls(_ say: String, _ voice: String?) async throws -> (data: Data, ms: Int) {
  Issue.record("the frames-only render must not ask for a voice")
  return (Data(), 0)
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  /// Counts one and says how many that makes.
  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Measures, from a thread of its own, the longest the main thread took to answer. Stops at `stop`.
private final class MainHeartbeat: @unchecked Sendable {
  private let lock = NSLock()
  private var running = true
  private var longest = 0.0

  init() {
    Thread.detachNewThread { [self] in
      while isRunning {
        let answered = DispatchSemaphore(value: 0), asked = Date()
        DispatchQueue.main.async { answered.signal() }
        while isRunning, answered.wait(timeout: .now() + 0.05) == .timedOut { note(Date().timeIntervalSince(asked)) }
        note(Date().timeIntervalSince(asked))
        usleep(20_000)
      }
    }
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  private func note(_ gap: Double) {
    lock.lock()
    longest = max(longest, gap)
    lock.unlock()
  }

  /// The longest wait, in seconds.
  func stop() -> Double {
    lock.lock()
    defer { lock.unlock() }
    running = false
    return longest
  }
}

@MainActor private func makeRenderer() -> ExplainerRenderer { ExplainerRenderer(voice: voiceNobodyCalls) }

@MainActor private func write(_ html: String, in folder: URL) throws {
  try html.write(to: folder.appendingPathComponent("scenes.html"), atomically: true, encoding: .utf8)
}

/// `narration.json` into a scene folder.
private func writeNarration(_ json: String, in folder: URL) throws {
  try json.write(to: folder.appendingPathComponent("narration.json"), atomically: true, encoding: .utf8)
}

/// A voice that answers with a tone of a set length per spoken text, and keeps what it was asked.
private final class StubVoice: @unchecked Sendable {
  struct Call: Equatable { let say: String; let voice: String? }
  struct Down: LocalizedError { var errorDescription: String? { "no voice today" } }
  private let seconds: [String: Double]
  private let failing: String?
  private let lock = NSLock()
  private var recorded: [Call] = []
  var onCall: (@Sendable (String) async -> Void)?
  var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
  private func record(_ call: Call) { lock.lock(); recorded.append(call); lock.unlock() }
  init(seconds: [String: Double], failing: String? = nil) { self.seconds = seconds; self.failing = failing }

  func call(_ say: String, _ voice: String?) async throws -> (data: Data, ms: Int) {
    record(Call(say: say, voice: voice))
    await onCall?(say)
    if say == failing { throw Down() }
    let length = seconds[say] ?? 0.5
    let count = Int(length * 24_000)
    var pcm = Data()
    for i in 0..<count {
      let value = Int16(sin(2 * .pi * 440 * Double(i) / 24_000) * 8000)
      withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
    }
    return (PCM.wav(int16LE: pcm, sampleRate: 24_000), Int(length * 1000))
  }
}

private func slots(_ list: [(String, Int)]) -> [ExplainerTimeline.Slot] {
  var start = 0
  return list.map { id, duration in
    defer { start += duration }
    return ExplainerTimeline.Slot(id: id, startMs: start, durationMs: duration)
  }
}

/// Pixels of an image as RGBA bytes, rows from the top.
private struct Pixels {
  let width: Int, height: Int
  var bytes: [UInt8]
  init(_ image: CGImage) {
    width = image.width
    height = image.height
    bytes = [UInt8](repeating: 0, count: width * height * 4)
    let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let i = (y * width + x) * 4
    return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
  }
  /// The leftmost x on row `y` that is white-ish, or nil.
  func firstWhite(row y: Int) -> Int? {
    (0..<width).first { let p = rgb($0, y); return p.r > 200 && p.g > 200 && p.b > 200 }
  }
}

private func frame(of video: URL, at seconds: Double) async throws -> Pixels {
  let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
  generator.requestedTimeToleranceBefore = .zero
  generator.requestedTimeToleranceAfter = .zero
  let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 90_000)).image
  return Pixels(image)
}

private func videoFacts(_ video: URL) async throws -> (duration: Double, frames: Int, size: CGSize) {
  let asset = AVURLAsset(url: video)
  let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
  reader.add(output)
  reader.startReading()
  let frames = try await onOwnThread {
    var frames = 0
    while let sample = output.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }   // a buffer may hold several
    return frames
  }
  return (try await asset.load(.duration).seconds, frames, try await track.load(.naturalSize))
}


private func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 200 && p.r < 80 && p.b < 80 }

/// A folder beside `folder` (not inside it) holding a green page, a green picture and a text file saying SECRET.
private func makeSentinels(in directory: URL) throws {
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try #"<!doctype html><body style="margin:0;background:#0f0"><section data-scene="a" style="position:absolute;inset:0;background:#0f0"></section>"#
    .write(to: directory.appendingPathComponent("secret.html"), atomically: true, encoding: .utf8)
  try "SECRET".write(to: directory.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
  let ctx = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
  let png = NSMutableData()
  let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  try (png as Data).write(to: directory.appendingPathComponent("secret.png"))
}

/// A page that reads `base`/secret.* four ways and turns a 200x200 square green for each way that worked.
private func readerPage(base: String) -> String {
  page + """
    <section data-scene="a" style="background:#202020">
    <iframe src="\(base)/secret.html" style="position:absolute;left:0;top:0;width:200px;height:200px;border:0"></iframe>
    <img src="\(base)/secret.png" style="position:absolute;left:250px;top:0;width:200px;height:200px">
    <div id="f" style="position:absolute;left:500px;top:0;width:200px;height:200px"></div>
    <div id="x" style="position:absolute;left:750px;top:0;width:200px;height:200px"></div>
    </section>
    <script>
    fetch("\(base)/secret.txt").then(r => r.text()).then(t => { if (t.includes("SECRET")) document.getElementById("f").style.background = "#0f0"; }).catch(() => {});
    const x = new XMLHttpRequest(); x.open("GET", "\(base)/secret.txt");
    x.onload = () => { if (x.responseText.includes("SECRET")) document.getElementById("x").style.background = "#0f0"; };
    x.send();
    window.__seek = ms => { let n = 0; for (let i = 0; i < 3e6; i++) n += i; };   // real time for the reads to land
    </script>
    """
}

/// Which of the four reads (iframe, img, fetch, XHR) show green in the last frame.
private func greens(_ video: URL, seconds: Double) async throws -> [Bool] {
  let last = try await frame(of: video, at: seconds)
  return [100, 350, 600, 850].map { isGreen(last.rgb($0, 100)) }
}

/// A server on 127.0.0.1 that counts what reaches it.
private final class Loopback: @unchecked Sendable {
  private let lock = NSLock()
  private var paths: [String] = []
  let listener: NWListener
  private(set) var port: UInt16 = 0

  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        self?.add(line.split(separator: " ").dropFirst().first.map(String.init) ?? line)
        connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: .global())
    ready.wait()
    port = listener.port!.rawValue
  }
  private func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
  var hits: [String] { lock.lock(); defer { lock.unlock() }; return paths }
  func stop() { listener.cancel() }
}

/// Whether `pid` is gone (or only a zombie), by asking ps.
private func processIsGone(_ pid: Int32) -> Bool {
  let ps = Process()
  ps.executableURL = URL(fileURLWithPath: "/bin/ps")
  ps.arguments = ["-o", "stat=", "-p", "\(pid)"]
  let out = Pipe()
  ps.standardOutput = out
  try? ps.run()
  ps.waitUntilExit()
  let stat = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  return stat.isEmpty || stat.hasPrefix("Z")
}

/// The CPU percentage ps reports for `pid`.
private func cpu(of pid: Int32) -> Double {
  let ps = Process()
  ps.executableURL = URL(fileURLWithPath: "/bin/ps")
  ps.arguments = ["-o", "%cpu=", "-p", "\(pid)"]
  let out = Pipe()
  ps.standardOutput = out
  try? ps.run()
  ps.waitUntilExit()
  return Double(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

@MainActor private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
  return condition()
}

// MARK: tests

@Suite(.serialized) @MainActor struct ExplainerRendererTests {
  @Test func twoScenesGiveAVideoOfThePlannedLengthAndTheFramesChangeWithTheScene() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#e02020"></section>
      <section data-scene="b" style="background:#2020e0"></section>
      """, in: folder)
    var progress: [Double] = []
    let url = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000), ("b", 1000)])) { progress.append($0) }

    #expect(url == folder.appendingPathComponent("video.mp4"))
    let facts = try await videoFacts(url)
    #expect(abs(facts.duration - 2.0) < 0.1)
    #expect(facts.frames == 60)
    #expect(facts.size == CGSize(width: 1280, height: 720))
    let first = try await frame(of: url, at: 0.5).rgb(640, 360)
    let second = try await frame(of: url, at: 1.5).rgb(640, 360)
    #expect(first.r > 180 && first.b < 80, "scene a is red, got \(first)")
    #expect(second.b > 180 && second.r < 80, "scene b is blue, got \(second)")
    #expect(progress.last == 1.0)
    #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
  }

  @Test func animationsRunOnTheSceneOwnTimeAndRestartWhenTheSceneStarts() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let box = #"<div style="position:absolute;top:300px;left:0;width:60px;height:60px;background:#fff;animation:mv 1s linear forwards"></div>"#
    try write(page + """
      <style>@keyframes mv{from{transform:translateX(0)}to{transform:translateX(1000px)}}</style>
      <section data-scene="m1">\(box)</section>
      <section data-scene="m2">\(box)</section>
      """, in: folder)
    let url = try await makeRenderer().renderFrames(folder: folder, slots: slots([("m1", 1000), ("m2", 1000)])) { _ in }
    // Frame k shows k/30 s; the second scene's animation starts over at its own start.
    for (frameNumber, expectedX) in [(9, 300), (21, 700), (39, 300), (51, 700)] {
      let x = try #require(try await frame(of: url, at: Double(frameNumber) / 30).firstWhite(row: 330), "no box at frame \(frameNumber)")
      #expect(abs(x - expectedX) < 40, "frame \(frameNumber): box at \(x), expected about \(expectedX)")
    }
  }

  @Test func theSceneEventAndTheSeekHookGetTheSceneAndItsLocalTime() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // Red grows with the scene's local time; blue is lit only if the event said scene "a" lasts 1000 ms.
    try write(page + """
      <section data-scene="a" id="a"></section><section data-scene="b" id="b"></section>
      <script>
      let blue = 0, current = null;
      document.addEventListener("glance:scene", e => { current = e.detail.id; blue = e.detail.id === "a" && e.detail.durationMs === 1000 ? 200 : 0; });
      window.__seek = ms => { document.getElementById(current).style.background = "rgb(" + Math.round(ms / 1000 * 200) + ",0," + blue + ")"; };
      </script>
      """, in: folder)
    let url = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000), ("b", 1000)])) { _ in }
    let midA = try await frame(of: url, at: 15.0 / 30).rgb(640, 360)     // local 500 ms in a
    let midB = try await frame(of: url, at: 45.0 / 30).rgb(640, 360)     // local 500 ms in b
    #expect(abs(midA.r - 100) < 30 && midA.b > 150, "a: \(midA)")
    #expect(abs(midB.r - 100) < 30 && midB.b < 60, "b: \(midB)")
  }

  @Test func aLoopInAnEvaluateFailsWithTheFrameAndKillsTheWebProcess() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#222"></section>
      <script>window.__seek = ms => { if (ms >= 100) { while (true) {} } };</script>
      """, in: folder)
    let renderer = makeRenderer()
    let started = ContinuousClock.now
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
      Issue.record("a hung page must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .rendering)
      #expect(failure.message.contains("frame 4 of 30"), "got: \(failure.message)")
      #expect(failure.message.contains("'a'"), "names the scene: \(failure.message)")
    }
    #expect(ContinuousClock.now - started < .seconds(12), "10 s watchdog plus a quick teardown, not the 3 s wait for a termination that already came")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
    try await expectWebProcessGone(renderer)
  }

  @Test func aLoopInThePageItselfFailsTheLoadAndKillsTheWebProcess() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a"></section><script>while (true) {}</script>"#, in: folder)
    let renderer = makeRenderer()
    let started = ContinuousClock.now
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
      Issue.record("a page that never loads must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .rendering)
      #expect(failure.message.contains("load"), "got: \(failure.message)")
    }
    #expect(ContinuousClock.now - started < .seconds(30))
    try await expectWebProcessGone(renderer)
  }

  @Test func cancelStopsAStuckRenderAtOnce() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#222"></section>
      <script>window.__seek = ms => { if (ms >= 100) { while (true) {} } };</script>
      """, in: folder)
    let renderer = makeRenderer()
    let started = ContinuousClock.now
    let task = Task { @MainActor in try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in } }
    try await Task.sleep(nanoseconds: 3_000_000_000)   // well into the hung frame, well before the watchdog
    renderer.cancel()
    do {
      _ = try await task.value
      Issue.record("a cancelled render must not finish")
    } catch is CancellationError {
    } catch {
      Issue.record("a cancelled render throws CancellationError, got \(error)")
    }
    #expect(ContinuousClock.now - started < .seconds(8))
    try await expectWebProcessGone(renderer)
  }

  @Test func cancelWithAnAppendStuckInTheEncoderLeavesTheMainActorFreeAndTheRenderEnds() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let video = folder.appendingPathComponent("video.mp4")
    let gate = SelfOpeningGate(opensAfter: 20)
    defer { gate.open() }
    let appends = Counter(), stuck = DispatchSemaphore(value: 0)
    let renderer = makeRenderer()
    renderer.teardownLimit = 1
    renderer.encodeHooks.beforeAppend = {   // real frames go into the real H.264 writer, then one append sticks
      if appends.next() == 4 { stuck.signal(); gate.wait() }
    }
    let task = Task { @MainActor in try await renderer.renderFrames(folder: folder, slots: slots([("a", 20_000)])) { _ in } }
    #expect(try await reached(stuck))

    let beat = MainHeartbeat()
    let cancelled = ContinuousClock.now
    renderer.cancel()
    #expect(ContinuousClock.now - cancelled < .seconds(1))
    await expectCancelled(task)
    #expect(ContinuousClock.now - cancelled < .seconds(10), "the render ends well before the gate opens")
    #expect(beat.stop() < 3, "the main actor was blocked")
    #expect(!FileManager.default.fileExists(atPath: video.path))

    gate.open()   // the append comes back; the cancel that was queued behind it runs and nothing comes back to life
    #expect(await waitUntil(seconds: 5) { !FileManager.default.fileExists(atPath: video.path) })
  }

  @Test func cancelWritingRunsOffTheMainActorWithFramesInFlightAndTheRenderEnds() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let video = folder.appendingPathComponent("video.mp4")
    let gate = SelfOpeningGate(opensAfter: 20)
    defer { gate.open() }
    let onMain = Counter(), reachedCancel = DispatchSemaphore(value: 0)
    let renderer = makeRenderer()
    renderer.teardownLimit = 1
    renderer.encodeHooks.beforeCancel = {
      if Thread.isMainThread { _ = onMain.next() }
      reachedCancel.signal()
      gate.wait()
    }
    var progress = 0.0
    let task = Task { @MainActor in
      try await renderer.renderFrames(folder: folder, slots: slots([("a", 20_000)])) { progress = $0 }
    }
    #expect(await waitUntil(seconds: 30) { progress >= 0.02 })   // frames are in the real H.264 writer

    let beat = MainHeartbeat()
    let cancelled = ContinuousClock.now
    renderer.cancel()
    #expect(ContinuousClock.now - cancelled < .seconds(1))
    await expectCancelled(task)
    #expect(ContinuousClock.now - cancelled < .seconds(10), "the render ends well before the gate opens")
    #expect(beat.stop() < 3, "the main actor was blocked")
    #expect(try await reached(reachedCancel))
    #expect(onMain.value == 0)
    #expect(!FileManager.default.fileExists(atPath: video.path))

    gate.open()
    #expect(await waitUntil(seconds: 5) { !FileManager.default.fileExists(atPath: video.path) })
  }

  @Test func cancelBetweenFramesStopsTheRenderAndLeavesNoVideo() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    var last = 0.0
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 20_000)])) { value in
        last = value
        if value >= 0.05 { renderer.cancel() }
      }
      Issue.record("a cancelled render must not finish")
    } catch is CancellationError {
    }
    #expect(last < 0.5, "stopped soon after the cancel, reached \(last)")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func theOverallLimitFailsWithTheFrameReached() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    #expect(renderer.overallLimitSeconds == 15 * 60)
    renderer.overallLimitSeconds = 0.3
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 30_000)])) { _ in }
      Issue.record("900 frames can't render in 0.3 s")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .rendering)
      #expect(failure.message.contains("of 900"), "got: \(failure.message)")
      #expect(failure.message.contains("frame"), "got: \(failure.message)")
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func theWatchdogDefaultsToTenSeconds() {
    #expect(makeRenderer().watchdogSeconds == 10)
  }

  @Test func aMissingPageFailsWithAMessage() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
      _ = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
      Issue.record("no scenes.html must fail")
    } catch let failure as ExplainerFailure {
      #expect(failure.message.contains("scenes.html"), "got: \(failure.message)")
    }
  }

  @Test func aSceneWithoutASectionFailsWithItsId() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    do {
      _ = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 500), ("ghost", 500)])) { _ in }
      Issue.record("a scene with no section must fail")
    } catch let failure as ExplainerFailure {
      #expect(failure.message.contains("ghost"), "got: \(failure.message)")
    }
  }

  @Test func aRuleListThatWontCompileFailsTheRender() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    renderer.networkRules = #"[{"trigger":{"url-filter":"^(https?|wss?)://"},"action":{"type":"block"}}]"#   // disjunctions don't compile
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }
      Issue.record("without its network block the render must not run")
    } catch let failure as ExplainerFailure {
      #expect(failure.message.contains("network"), "got: \(failure.message)")
    }
  }

  // MARK: the network

  private func networkPage(port: UInt16) -> String {
    let base = "http://127.0.0.1:\(port)"
    return page + """
      <section data-scene="a" style="background:#222">
      <img src="\(base)/img"><link rel="stylesheet" href="\(base)/css"><script src="\(base)/js"></script>
      </section>
      <script>
      fetch("\(base)/fetch").catch(() => {});
      fetch("\(base)/nocors", {mode: "no-cors"}).catch(() => {});
      navigator.sendBeacon("\(base)/beacon");
      try { new WebSocket("ws://127.0.0.1:\(port)/ws").onerror = () => {}; } catch (e) {}
      location.href = "\(base)/nav";
      </script>
      """
  }

  @Test func theNetworkRulesKeepEveryKindOfRequestFromLeavingThePage() async throws {
    let server = try Loopback()
    defer { server.stop() }
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(networkPage(port: server.port), in: folder)
    _ = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(server.hits.isEmpty, "reached the server: \(server.hits)")
  }

  @Test func theSamePageReachesTheServerWhenNoRulesAreApplied() async throws {
    let server = try Loopback()
    defer { server.stop() }
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(networkPage(port: server.port), in: folder)
    let renderer = makeRenderer()
    renderer.networkRules = nil   // the control: the test above proves something only if this page can get out
    _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    try await Task.sleep(nanoseconds: 1_000_000_000)
    for kind in ["/img", "/css", "/js", "/fetch", "/nocors", "/beacon", "/ws"] {
      #expect(server.hits.contains(kind), "\(kind) never arrived: \(server.hits)")
    }
    // The navigation delegate is a second wall: even with no rules, the page can't leave for the network.
    #expect(!server.hits.contains("/nav"), "the page navigated away: \(server.hits)")
  }


  // MARK: confinement

  @Test func theFolderPredicateResolvesSymlinksAndDotDot() throws {
    let root = try tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("scene")
    let outside = root.appendingPathComponent("scene-evil")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try makeSentinels(in: outside)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: outside)
    #expect(ExplainerRenderer.isInside(folder.appendingPathComponent("scenes.html"), folder: folder))
    #expect(ExplainerRenderer.isInside(folder.appendingPathComponent("sub/../scenes.html"), folder: folder))
    #expect(!ExplainerRenderer.isInside(folder.appendingPathComponent("../scene-evil/secret.txt"), folder: folder), "a sibling that starts with the same name")
    #expect(!ExplainerRenderer.isInside(outside.appendingPathComponent("secret.txt"), folder: folder))
    #expect(!ExplainerRenderer.isInside(folder.appendingPathComponent("link/secret.txt"), folder: folder), "a symlink out of the folder")
    #expect(!ExplainerRenderer.isInside(URL(fileURLWithPath: "/etc/hosts"), folder: folder))
  }

  @Test func aPageReadsItsOwnFolderButNothingOutsideIt() async throws {
    let root = try tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    let slotList = slots([("a", 2000)])
    // The control: the same four reads, aimed inside the folder, show up.
    let own = root.appendingPathComponent("own")
    try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    try makeSentinels(in: own.appendingPathComponent("inside"))
    try write(readerPage(base: "inside"), in: own)
    let ownVideo = try await makeRenderer().renderFrames(folder: own, slots: slotList) { _ in }
    let ownGreens = try await greens(ownVideo, seconds: 1.9)
    #expect(ownGreens[0] && ownGreens[1], "iframe and img of the folder's own files should show: \(ownGreens)")
    // Aimed outside: a sibling folder, by path and through a symlink inside the folder.
    for (name, base) in [("path", "../elsewhere"), ("symlink", "link")] {
      let folder = root.appendingPathComponent("confined-\(name)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try makeSentinels(in: root.appendingPathComponent("elsewhere"))
      try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("elsewhere"))
      try write(readerPage(base: base), in: folder)
      let video = try await makeRenderer().renderFrames(folder: folder, slots: slotList) { _ in }
      let reached = try await greens(video, seconds: 1.9)
      #expect(reached == [false, false, false, false], "\(name): the outside file reached the frame: \(reached)")
    }
  }

  /// WebKit's read access is one wall; ours is the second. With WebKit's widened to the parent folder, only ours is left,
  /// and it must still keep an iframe and `location=` from reaching a page outside the scene folder.
  @Test func ourOwnCheckHoldsWhenWebKitsReadAccessIsWidened() async throws {
    let root = try tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeSentinels(in: root.appendingPathComponent("elsewhere"))
    let folder = root.appendingPathComponent("scene")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try write(page + """
      <section data-scene="a" style="background:#202020"><iframe src="../elsewhere/secret.html" style="position:absolute;left:0;top:0;width:300px;height:300px;border:0"></iframe></section>
      <script>let went = false; window.__seek = ms => { if (ms > 100 && !went) { went = true; location.href = "../elsewhere/secret.html"; } };</script>
      """, in: folder)
    let renderer = makeRenderer()
    renderer.readAccessOverride = root
    let video = try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    let last = try await frame(of: video, at: 29.0 / 30)
    #expect(!isGreen(last.rgb(150, 150)), "the iframe showed a page outside the folder: \(last.rgb(150, 150))")
    #expect(!isGreen(last.rgb(640, 360)), "the page navigated to one outside the folder: \(last.rgb(640, 360))")
  }

  @Test func aPageCantNavigateOutsideItsFolder() async throws {
    let root = try tempFolder()
    defer { try? FileManager.default.removeItem(at: root) }
    try makeSentinels(in: root.appendingPathComponent("elsewhere"))
    let folder = root.appendingPathComponent("scene")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try write(page + """
      <section data-scene="a" style="background:#202020"></section>
      <script>let went = false; window.__seek = ms => { if (ms > 100 && !went) { went = true; location.href = "../elsewhere/secret.html"; } };</script>
      """, in: folder)
    let video = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    let last = try await frame(of: video, at: 29.0 / 30).rgb(640, 360)
    #expect(!isGreen(last), "the page left its folder: \(last)")
  }

  // MARK: the host the page talks to

  @Test func theHostRefusesWhatThePageAsksOfIt() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#222"></section>
      <script>
      alert("a"); confirm("c"); prompt("p");
      window.__opened = window.open("about:blank");
      if (navigator.mediaDevices) navigator.mediaDevices.getUserMedia({audio: true, video: true}).catch(() => {});
      </script>
      """, in: folder)
    let renderer = makeRenderer()
    let started = ContinuousClock.now
    _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }
    #expect(ContinuousClock.now - started < .seconds(20))
    for event in ["alert", "confirm", "prompt", "open"] {
      #expect(renderer.uiEvents.contains(event), "the host never saw \(event): \(renderer.uiEvents)")
    }
  }

  @Test func webRTCIsOffAndFramesGetTheFakeClockToo() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let probe = """
      <script>
      var good = Date.now() < 1.7001e12 && performance.now() < 1000;
      try { new RTCPeerConnection(); good = false; } catch (e) {}
      try { new webkitRTCPeerConnection(); good = false; } catch (e) {}
      try { new RTCDataChannel(); good = false; } catch (e) {}
      """
    try (##"<!doctype html><body style="margin:0;background:#f00">"## + probe + ##"document.body.style.background = good ? "#0f0" : "#f00";</script>"##)
      .write(to: folder.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
    try write(page + """
      <section data-scene="a" id="s" style="background:#f00">
      <iframe src="frame.html" style="position:absolute;left:0;top:0;width:300px;height:300px;border:0"></iframe></section>
      \(probe) document.getElementById("s").style.background = good ? "#0f0" : "#f00"; </script>
      """, in: folder)
    let video = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    let last = try await frame(of: video, at: 29.0 / 30)
    #expect(isGreen(last.rgb(900, 500)), "the page: WebRTC should throw and the clock be fake, got \(last.rgb(900, 500))")
    #expect(isGreen(last.rgb(150, 150)), "the iframe: same, got \(last.rgb(150, 150))")
  }

  @Test func resourceHintLinksAreStrippedWhetherParsedOrAddedLater() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // dns-prefetch / preconnect / prefetch look names up (or connect) outside the content rules. Green = none left.
    try write(page + """
      <link rel="dns-prefetch" href="//hint-one.invalid"><link rel="preconnect" href="https://hint-two.invalid">
      <link rel="prefetch" href="https://hint-three.invalid/x"><link rel="stylesheet" href="none.css">
      <section data-scene="a" id="s" style="background:#f00"></section>
      <script>
      const late = document.createElement("link"); late.rel = "dns-prefetch"; late.href = "//hint-four.invalid"; document.head.appendChild(late);
      window.__seek = ms => {
        const left = document.querySelectorAll('link[rel~="dns-prefetch"], link[rel~="preconnect"], link[rel~="prefetch"]').length;
        const kept = document.querySelectorAll('link[rel="stylesheet"]').length === 1;
        document.getElementById("s").style.background = left === 0 && kept ? "#0f0" : "#f00";
      };
      </script>
      """, in: folder)
    let video = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }
    let last = try await frame(of: video, at: 14.0 / 30).rgb(640, 360)
    #expect(isGreen(last), "a resource hint is still in the page (or the stylesheet link went too): \(last)")
  }

  @Test func aSceneListenerCanPaintOnTheSceneFirstFrame() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" id="a" style="background:#000"></section><section data-scene="b" id="b" style="background:#000"></section>
      <script>
      document.addEventListener("glance:scene", e => requestAnimationFrame(() => { document.getElementById(e.detail.id).style.background = "#0f0"; }));
      </script>
      """, in: folder)
    let video = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 1000), ("b", 1000)])) { _ in }
    #expect(isGreen(try await frame(of: video, at: 0).rgb(640, 360)), "first frame of a")
    #expect(isGreen(try await frame(of: video, at: 1.0).rgb(640, 360)), "first frame of b")
  }

  // MARK: the process always ends

  @Test func aSpinningWorkerDoesntSurviveTheRender() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#222"></section>
      <script>new Worker(URL.createObjectURL(new Blob(["while (true) {}"])));</script>
      """, in: folder)
    let renderer = makeRenderer()
    var spunDuringRender = false
    let started = ContinuousClock.now
    _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 5000)])) { value in
      if value > 0.5, !spunDuringRender, let pid = renderer.webProcessIdentifier { spunDuringRender = cpu(of: pid) > 50 }
    }
    #expect(spunDuringRender, "the worker should have been burning a core, or this test proves nothing")
    #expect(ContinuousClock.now - started < .seconds(20))
    let pid = try #require(renderer.lastKilledProcessID, "a finished render still ends the web process")
    #expect(await waitUntil(seconds: 5) { processIsGone(pid) }, "web process \(pid) is still alive")
  }

  @Test func aProcessThatDiesBetweenFramesFailsTheRenderAtOnce() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    let started = ContinuousClock.now
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 20_000)])) { value in
        if value >= 0.05, let pid = renderer.webProcessIdentifier { kill(pid, SIGKILL) }   // a crash, not our kill
      }
      Issue.record("a dead web process must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.message.contains("process"), "got: \(failure.message)")
    }
    #expect(ContinuousClock.now - started < .seconds(5), "not after the 10 s watchdog")
  }

  // MARK: cancel and reuse

  @Test func aCancelAtTheLastFrameCantReturnAVideo() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 1000)])) { value in
        if value == 1.0 { renderer.cancel() }
      }
      Issue.record("cancel() before the render returned must throw")
    } catch is CancellationError {
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func aSecondRenderOnOneInstanceIsRefusedAndTheFirstIsUnharmed() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    let first = Task { @MainActor in try await renderer.renderFrames(folder: folder, slots: slots([("a", 2000)])) { _ in } }
    await Task.yield()
    do {
      _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }
      Issue.record("a second render on a busy instance must be refused")
    } catch let failure as ExplainerFailure {
      #expect(failure.message.contains("already"), "got: \(failure.message)")
    }
    let url = try await first.value
    #expect(abs(try await videoFacts(url).duration - 2.0) < 0.1)
    // And the instance is reusable afterwards.
    _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }
  }

  @Test func aFailedStartLeavesNoOldVideoBehind() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Data("old".utf8).write(to: folder.appendingPathComponent("video.mp4"))
    do {
      _ = try await makeRenderer().renderFrames(folder: folder, slots: slots([("a", 500)])) { _ in }   // no scenes.html
      Issue.record("no scenes.html must fail")
    } catch is ExplainerFailure {
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func theSnapshotIsAskedForAtThePointSizeThatGives1280Pixels() async throws {
    #expect(ExplainerRenderer.pointWidth(forPixels: 1280, got: 1280, asked: 1280) == 1280)
    #expect(ExplainerRenderer.pointWidth(forPixels: 1280, got: 2560, asked: 1280) == 640)
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let renderer = makeRenderer()
    _ = try await renderer.renderFrames(folder: folder, slots: slots([("a", 200)])) { _ in }
    #expect(renderer.lastSnapshotWidth == 1280)
  }

  // MARK: narration and the finished video

  @Test func aRenderGivesVideoAndAACOfThePlannedLengthAndTheAudioSitsInItsScene() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#e02020"></section>
      <section data-scene="b" style="background:#2020e0"></section>
      """, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"first","minMs":0},{"id":"b","say":"second","minMs":0}]}"#, in: folder)
    let voice = StubVoice(seconds: ["first": 1.0, "second": 0.5])
    var steps: [ExplainerStep] = []
    var last: (ExplainerStep, Double) = (.writing, -1)
    let url = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { step, fraction in
      if steps.last != step { steps.append(step) }
      last = (step, fraction)
    }

    #expect(url == folder.appendingPathComponent("explainer.mp4"))
    // a: 1000 + 400 ms, b: 500 + 400 ms.
    let facts = try await videoFacts(url)
    #expect(abs(facts.duration - 2.3) < 0.1)
    let asset = AVURLAsset(url: url)
    let audioTrack = try #require(try await asset.loadTracks(withMediaType: .audio).first)
    let format = try #require(try await audioTrack.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
    #expect(steps == [.narrating, .rendering, .muxing])
    #expect(last.0 == .muxing && last.1 == 1.0)
    #expect(voice.calls.map(\.say) == ["first", "second"])
    #expect(voice.calls.allSatisfy { $0.voice == Prefs.kokoroVoice.id }, "Glance Voice, with the user's chosen Kokoro voice")
    // The intermediate files are gone; only the finished video is left.
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func aSceneWithNoWordsNeverAsksForTheVoice() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + """
      <section data-scene="a" style="background:#222"></section><section data-scene="b" style="background:#444"></section>
      """, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"","minMs":500},{"id":"b","say":"  \n ","minMs":500}]}"#, in: folder)
    let voice = StubVoice(seconds: [:])
    let url = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { _, _ in }
    #expect(voice.calls.isEmpty)
    #expect(abs(try await videoFacts(url).duration - 1.0) < 0.1)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.loadTracks(withMediaType: .audio).count == 1, "silent narration still gives an audio track")
  }

  @Test func aVoiceFailureFailsTheNarratingStepAndLeavesNoVideo() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a"></section><section data-scene="b"></section>"#, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"one"},{"id":"b","say":"two"}]}"#, in: folder)
    try Data("old".utf8).write(to: folder.appendingPathComponent("explainer.mp4"))
    let voice = StubVoice(seconds: ["one": 0.5], failing: "two")
    do {
      _ = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { _, _ in }
      Issue.record("a voice failure must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .narrating)
      #expect(failure.message.contains("'b'"), "names the scene: \(failure.message)")
      #expect(failure.message.contains("no voice today"), "carries the reason: \(failure.message)")
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("explainer.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path))
  }

  @Test func aMissingSectionFailsBeforeAnyNarration() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a"></section>"#, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"one"},{"id":"gone","say":"two"}]}"#, in: folder)
    let voice = StubVoice(seconds: ["one": 0.5, "two": 0.5])
    do {
      _ = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { _, _ in }
      Issue.record("a scene without a section must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .writing)
      #expect(failure.message.contains("gone"), "names the scene: \(failure.message)")
    }
    #expect(voice.calls.isEmpty, "no narration is paid for when the page can't be drawn")
  }

  @Test func aMissingOrBrokenScriptFailsTheWritingStepBeforeAnyNarration() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let voice = StubVoice(seconds: [:])
    for (narration, html) in [(nil, page + #"<section data-scene="a"></section>"#), (#"{"title":"T","scenes":[]}"#, page), ("nope", page)] as [(String?, String)] {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent("narration.json"))
      try write(html, in: folder)
      if let narration { try writeNarration(narration, in: folder) }
      do {
        _ = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { _, _ in }
        Issue.record("\(narration ?? "no narration.json") must fail the render")
      } catch let failure as ExplainerFailure {
        #expect(failure.step == .writing, "\(narration ?? "none"): \(failure.message)")
      }
    }
    #expect(voice.calls.isEmpty)
    try? FileManager.default.removeItem(at: folder.appendingPathComponent("scenes.html"))
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"x"}]}"#, in: folder)
    do {
      _ = try await ExplainerRenderer(voice: voice.call).render(folder: folder) { _, _ in }
      Issue.record("no scenes.html must fail the render")
    } catch let failure as ExplainerFailure {
      #expect(failure.step == .writing)
    }
    #expect(voice.calls.isEmpty)
  }

  @Test func cancellingDuringNarrationStopsBeforeTheNextSceneAndThrowsCancellation() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a"></section><section data-scene="b"></section>"#, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"one"},{"id":"b","say":"two"}]}"#, in: folder)
    let voice = StubVoice(seconds: ["one": 0.5, "two": 0.5])
    let renderer = ExplainerRenderer(voice: voice.call)
    voice.onCall = { _ in await MainActor.run { renderer.cancel() } }
    do {
      _ = try await renderer.render(folder: folder) { _, _ in }
      Issue.record("a cancelled render must not finish")
    } catch is CancellationError {
    }
    #expect(voice.calls.map(\.say) == ["one"])
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("explainer.mp4").path))
  }

  @Test func aCancelAfterTheMuxCantReturnTheVideo() async throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    try writeNarration(#"{"title":"T","scenes":[{"id":"a","say":"one","minMs":0}]}"#, in: folder)
    let renderer = ExplainerRenderer(voice: StubVoice(seconds: ["one": 0.3]).call)
    do {
      _ = try await renderer.render(folder: folder) { step, fraction in
        if step == .muxing, fraction == 1 { renderer.cancel() }   // the mux is done; the video is on disk
      }
      Issue.record("a cancel before render returned must throw")
    } catch is CancellationError {
    }
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("explainer.mp4").path))
  }

  @Test func narrationIsJoinedAtItsSlotsAndCutAtTheSlotsEnd() {
    let rate = ExplainerVoice.sampleRate
    let one = [Float](repeating: 0.5, count: rate)            // 1000 ms
    let long = [Float](repeating: -0.5, count: rate * 4)       // 4000 ms, into a 1000 ms slot (the 300 s cap cut it)
    let joined = ExplainerRenderer.joinNarration([
      .init(startMs: 500, durationMs: 2000, samples: one),
      .init(startMs: 2500, durationMs: 1000, samples: long),
    ], totalMs: 3500)
    #expect(joined.count == rate * 35 / 10)
    #expect(joined[0] == 0 && joined[rate * 5 / 10 - 1] == 0, "silence before the first scene")
    #expect(joined[rate * 5 / 10] == 0.5 && joined[rate * 15 / 10 - 1] == 0.5)
    #expect(joined[rate * 15 / 10] == 0 && joined[rate * 25 / 10 - 1] == 0, "the gap to the next slot")
    #expect(joined[rate * 25 / 10] == -0.5 && joined[joined.count - 1] == -0.5)
    #expect(joined.count == rate * 35 / 10, "nothing past the video's end")
  }

  @Test func theLastSlotCutByTheCapEndsTheMuxedFileAtTheVideosEnd() async throws {
    // The 300 s cap cuts the slot that crosses it. A narration longer than that slot must not stretch the file.
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try write(page + #"<section data-scene="a" style="background:#222"></section>"#, in: folder)
    let video = try await ExplainerRenderer(voice: voiceNobodyCalls).renderFrames(folder: folder, slots: slots([("a", 1000)])) { _ in }
    let wav = folder.appendingPathComponent("long.wav")
    try ExplainerRenderer.writeNarration(ExplainerRenderer.joinNarration(
      [.init(startMs: 0, durationMs: 5000, samples: [Float](repeating: 0.2, count: ExplainerVoice.sampleRate * 5))], totalMs: 5000), to: wav)
    let output = folder.appendingPathComponent("explainer.mp4")
    try await VideoMux.addAudio(video: video, audio: wav, to: output)
    let duration = try await videoFacts(output).duration
    #expect(abs(duration - 1.0) < 0.1, "the file ends with the video, got \(duration)")
  }

  @Test func narrationInAnotherRateAndChannelCountComesOutAt24kMono() throws {
    let rate = 48_000.0
    let frames = AVAudioFrameCount(rate)   // 1 s of stereo
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 2, interleaved: true)!
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stereo-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
      let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      for i in 0..<Int(frames) * 2 { buffer.int16ChannelData![0][i] = 8000 }
      try file.write(from: buffer)
    }
    let samples = try ExplainerVoice.samples(fromWAV: Data(contentsOf: url))
    #expect(abs(samples.count - ExplainerVoice.sampleRate) < 100)
    #expect(abs(samples[samples.count / 2] - 8000.0 / 32768) < 0.02)
    #expect(ExplainerVoice.milliseconds(of: samples) == 1000)
  }

  // MARK: shared check

  /// The web process the renderer had to kill is gone, and the web view told its delegate.
  private func expectCancelled(_ task: Task<URL, Error>) async {
    do {
      _ = try await task.value
      Issue.record("a cancelled render must not finish")
    } catch is CancellationError {
    } catch {
      Issue.record("a cancelled render throws CancellationError, got \(error)")
    }
  }

  private func expectWebProcessGone(_ renderer: ExplainerRenderer) async throws {
    let pid = try #require(renderer.lastKilledProcessID, "the renderer should have killed the stuck web process")
    #expect(await waitUntil(seconds: 5) { renderer.webProcessTerminations > 0 }, "webViewWebContentProcessDidTerminate never fired")
    #expect(await waitUntil(seconds: 5) { processIsGone(pid) }, "web process \(pid) is still alive")
  }
}
