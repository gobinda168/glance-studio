import AVFoundation
import CoreGraphics
import Foundation
import GlanceCore
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GlanceKit

// MARK: helpers

private let session = "aaaaaaaa-0000-0000-0000-000000000001"
private let home = "http://localhost:3000/"
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func jpeg(red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
  let ctx = CGContext(data: nil, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
  ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}

private let red = jpeg(red: 1, green: 0, blue: 0)
private let green = jpeg(red: 0, green: 1, blue: 0)
private let blue = jpeg(red: 0, green: 0, blue: 1)

private final class Clock: @unchecked Sendable {
  var now = epoch
  func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
  var seconds: Double { now.timeIntervalSince1970 }
}

/// Lets a fake call wait until the test opens the gate.
private final class Gate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var waiting: CheckedContinuation<Void, Never>?
  func wait() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if isOpen { lock.unlock(); continuation.resume() } else { waiting = continuation; lock.unlock() }
    }
  }
  func open() {
    lock.lock()
    isOpen = true
    let continuation = waiting
    waiting = nil
    lock.unlock()
    continuation?.resume()
  }
}

private final class FakeScreencast: ScreencastConnecting, @unchecked Sendable {
  var onEvent: ((ScreencastEvent) -> Void)?
  var onFrame: (@Sendable (String, Data, Double) -> Void)?
  var attachGate: Gate?
  /// The first `openFailures` calls to `open()` throw; with `closedFirst` they also report the socket closed first.
  var openFailures = 0
  var closedFirst = false
  private let lock = NSLock()
  private var log: [String: [String]] = [:]
  private let frames = DispatchQueue(label: "fake-screencast")

  func calls(_ name: String) -> [String] { lock.lock(); defer { lock.unlock() }; return log[name] ?? [] }
  private func record(_ name: String, _ target: String) { lock.lock(); log[name, default: []].append(target); lock.unlock() }

  func open() async throws {
    record("open", "")
    if calls("open").count <= openFailures {
      if closedFirst { DispatchQueue.main.async { self.onEvent?(.closed) } }
      throw ScreencastConnection.Failure(message: "refused")
    }
  }
  func attach(target: String) async throws {
    if let attachGate { await attachGate.wait() }
    record("attach", target)
  }
  func startScreencast(target: String) async throws { record("start", target) }
  func stopScreencast(target: String) async throws { record("stop", target) }
  func close() { record("close", "") }

  /// A frame from the browser, delivered off the main thread and in order, as the real connection does.
  func emit(_ target: String, _ data: Data, at seconds: Double) {
    let deliver = onFrame
    frames.sync { deliver?(target, data, seconds) }
  }
}

@MainActor
private struct Rig {
  let recorder: ClipRecorder
  let fake = FakeScreencast()
  let clock = Clock()
  let store: WorkStore
  let folder: URL
  let allowed = Flag()
  let resolved = Counter()

  final class Flag: @unchecked Sendable { var on = true }
  final class Counter: @unchecked Sendable { var count = 0 }

  init(resolves: Bool = true) throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("cliprecorder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    store = WorkStore(folder: folder)
    let clock = clock, fake = fake, allowed = allowed, resolved = resolved
    recorder = ClipRecorder(
      connect: { fake },
      store: store,
      resolve: { owner, url in
        resolved.count += 1
        guard resolves else { return nil }
        return ClipFiling(session: session, cwd: owner.cwd, worktree: "/repo", branch: "main", commonDir: "/repo/.git",
                          environment: "local")
      },
      now: { clock.now },
      allowed: { allowed.on })
  }

  func hello(client: Int = 1) {
    recorder.handle(client: client, .hello(wrapperPID: 10, claudePID: 99, session: "stale", cwd: "/repo"), at: clock.now)
  }
  func page(_ target: String = "T", adopted: Bool = false, client: Int = 1) {
    recorder.handle(client: client, .page(targetId: target, adopted: adopted), at: clock.now)
  }
  func tool(_ phase: BrowserSessionTable.Phase, client: Int = 1) {
    recorder.handle(client: client, .tool(name: "browser_navigate", phase: phase), at: clock.now)
  }
  func discovered(_ target: String = "T", url: String = home) { fake.onEvent?(.created(target: target, url: url)) }

  /// A session with a page at `url`, and a tool call started on it: the clip is recording.
  func startClip(url: String = home) async {
    hello()
    await recorder.settle()
    discovered(url: url)
    page()
    tool(.start)
    await recorder.settle()
  }

  /// Tool end, then the idle seconds one tick at a time.
  func endClip(afterSeconds seconds: Double = 2) async {
    clock.advance(seconds)
    tool(.end)
    for _ in 0..<6 {
      clock.advance(1)
      recorder.tick()
    }
    await recorder.settle()
  }

  func captures() -> [ProofCapture] { store.record(session: session)?.captures ?? [] }
  func listing() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".tmp-clips").path)) ?? []
  }
  /// What is in the temp folder. AVFoundation clears its own scratch file (`x.mp4.sb-...`) a moment after a cancel, so
  /// this gives it up to two seconds.
  func leftovers() async -> [String] {
    var names: [String] = []
    for _ in 0..<40 {
      names = listing()
      if names.isEmpty { break }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return names
  }
}

private struct Playback { var frames = 0; var last: (r: Int, g: Int, b: Int) = (0, 0, 0) }

/// Decodes the clip: how many frames it has and the colour in the middle of the last one.
private func play(_ url: URL) async throws -> Playback {
  let asset = AVURLAsset(url: url)
  let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  reader.add(output)
  reader.startReading()
  return try await onOwnThread {
    var playback = Playback()
    while let sample = output.copyNextSampleBuffer() {
      guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      playback.frames += 1
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
      let row = CVPixelBufferGetBytesPerRow(buffer)
      let at = base + 360 * row + 640 * 4
      playback.last = (Int(at[2]), Int(at[1]), Int(at[0]))
      CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
    return playback
  }
}

private func ackFrame(_ number: Int, session cdp: String, timestamp: Double, data: Data) -> String {
  let message: JSONValue = [
    "method": "Page.screencastFrame",
    "params": ["data": .string(data.base64EncodedString()),
               "metadata": ["timestamp": .number(timestamp), "offsetTop": 0],
               "sessionId": .number(Double(number))],
    "sessionId": .string(cdp),
  ]
  return message.text
}

// MARK: tests

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ClipRecorderTests {
  @Test func aToolCallAndFiveIdleSecondsGiveOneClipWithTheURL() async throws {
    let rig = try Rig()
    await rig.startClip()
    #expect(rig.fake.calls("attach") == ["T"])
    #expect(rig.fake.calls("start") == ["T"])

    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    rig.fake.emit("T", green, at: rig.clock.seconds + 1.2)
    await rig.recorder.settle()
    await rig.endClip()

    let captures = rig.captures()
    #expect(captures.count == 1)
    let capture = try #require(captures.first)
    #expect(capture.kind == .clip)
    #expect(capture.url == home)
    #expect(capture.environment == "local")
    #expect(capture.caption == "Clip of localhost")
    #expect(capture.purpose == .test)
    #expect(capture.source == .glance)
    let file = rig.store.mediaFolder(session: session).appendingPathComponent(capture.file)
    #expect(try await play(file).frames == 2)
    #expect(await rig.leftovers().isEmpty)
    #expect(rig.fake.calls("stop") == ["T"])
  }

  @Test func aStaticPageWithOneFrameMakesAShortStillClip() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", green, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    await rig.endClip()

    let capture = try #require(rig.captures().first)
    let playback = try await play(rig.store.mediaFolder(session: session).appendingPathComponent(capture.file))
    #expect(playback.frames == 1)
    #expect(playback.last.g > 150 && playback.last.r < 100 && playback.last.b < 100)
  }

  @Test func throttlingKeepsTheNewestFrameAndWritesItAtTheEnd() async throws {
    let rig = try Rig()
    await rig.startClip()
    let base = rig.clock.seconds
    rig.fake.emit("T", red, at: base + 0.100)
    rig.fake.emit("T", green, at: base + 0.110)   // inside 50 ms of the red frame: held
    rig.fake.emit("T", blue, at: base + 0.120)    // replaces the held one
    await rig.recorder.settle()
    await rig.endClip()

    let capture = try #require(rig.captures().first)
    let playback = try await play(rig.store.mediaFolder(session: session).appendingPathComponent(capture.file))
    #expect(playback.frames == 2)
    #expect(playback.last.b > 150 && playback.last.r < 100 && playback.last.g < 100)
  }

  @Test func framesArrivingAfterTheThrottleWindowAreAllWritten() async throws {
    let rig = try Rig()
    await rig.startClip()
    let base = rig.clock.seconds
    for index in 0..<4 { rig.fake.emit("T", index.isMultiple(of: 2) ? red : green, at: base + 0.1 + Double(index) * 0.2) }
    await rig.recorder.settle()
    await rig.endClip()
    let capture = try #require(rig.captures().first)
    #expect(try await play(rig.store.mediaFolder(session: session).appendingPathComponent(capture.file)).frames == 4)
  }

  @Test func aSessionThatCannotBeResolvedGivesNoClipAndNoTempFile() async throws {
    let rig = try Rig(resolves: false)
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    await rig.endClip()

    #expect(rig.resolved.count == 1)
    #expect(rig.captures().isEmpty)
    #expect(await rig.leftovers().isEmpty)
  }

  @Test func aClipThatNeverPaintedIsDroppedWithoutResolving() async throws {
    let rig = try Rig()
    await rig.startClip()
    await rig.endClip()
    #expect(rig.captures().isEmpty)
    #expect(rig.resolved.count == 0)
    #expect(await rig.leftovers().isEmpty)
  }

  @Test func aPageTheUserOpenedAttachesNothing() async throws {
    let rig = try Rig()
    rig.hello()
    await rig.recorder.settle()
    rig.discovered()
    rig.page(adopted: true)
    rig.tool(.start)
    await rig.recorder.settle()
    #expect(rig.fake.calls("attach").isEmpty)
    #expect(rig.fake.calls("start").isEmpty)
    #expect(await rig.leftovers().isEmpty)
  }

  @Test func theURLIsLearnedAfterThePageIsAnnounced() async throws {
    let rig = try Rig()
    rig.hello()
    await rig.recorder.settle()
    rig.page()           // the wrapper's word comes first: no URL yet
    rig.tool(.start)
    await rig.recorder.settle()
    #expect(rig.fake.calls("attach").isEmpty)
    rig.discovered(url: home)   // then the browser's
    await rig.recorder.settle()
    #expect(rig.fake.calls("attach") == ["T"])
  }

  @Test func navigatingToAnotherPageMakesASecondClip() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.fake.onEvent?(.changed(target: "T", url: "http://localhost:3000/settings"))
    await rig.recorder.settle()
    rig.fake.emit("T", green, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    await rig.endClip()

    let captures = rig.captures()
    #expect(captures.map(\.url) == [home, "http://localhost:3000/settings"])
    #expect(rig.fake.calls("start") == ["T", "T"])
    #expect(await rig.leftovers().isEmpty)
  }

  @Test func aClipEndingWhileAttachIsStillInFlightIsCancelled() async throws {
    let rig = try Rig()
    let gate = Gate()
    rig.fake.attachGate = gate
    rig.hello()
    await rig.recorder.settle()   // the connection is open; no attach has been asked yet
    rig.discovered()
    rig.page()
    rig.tool(.start)
    rig.clock.advance(0.2)
    rig.recorder.handle(client: 1, .pageGone(targetId: "T"), at: rig.clock.now)
    gate.open()
    await rig.recorder.settle()

    #expect(rig.captures().isEmpty)
    #expect(await rig.leftovers().isEmpty)
    #expect(rig.fake.calls("attach") == ["T"])
    #expect(rig.fake.calls("start").isEmpty)   // nobody is recording any more: the screencast is never started
    #expect(rig.fake.calls("stop") == ["T"])
  }

  @Test func aRepeatedHelloEndsTheClipsWithTheFramesSoFar() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.hello()
    await rig.recorder.settle()
    #expect(rig.captures().count == 1)
  }

  @Test func aDroppedSocketEndsTheClips() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.recorder.dropped(client: 1, at: rig.clock.now)
    await rig.recorder.settle()
    #expect(rig.captures().count == 1)
  }

  @Test func theBrowserGoingAwayFinishesWithTheFramesSoFar() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.fake.onEvent?(.closed)
    await rig.recorder.settle()
    #expect(rig.captures().count == 1)
  }

  @Test func nothingAttachesWhenRecordingIsNotAllowed() async throws {
    let rig = try Rig()
    rig.allowed.on = false
    await rig.startClip()
    #expect(rig.fake.calls("attach").isEmpty)
    #expect(await rig.leftovers().isEmpty)
  }

  @Test func turningRecordingOffFinishesTheOpenClips() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.allowed.on = false
    rig.recorder.refresh()
    await rig.recorder.settle()
    #expect(rig.captures().count == 1)
    #expect(rig.fake.calls("close") == [""])
  }

  @Test func leftoverClipsAreSweptButAnotherRunningStudiosAreKept() async throws {
    let rig = try Rig()
    let temp = rig.folder.appendingPathComponent(".tmp-clips")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: temp.appendingPathComponent("old.mp4"))
    try Data("x".utf8).write(to: temp.appendingPathComponent("2147483000-dead.mp4"))
    try Data("x".utf8).write(to: temp.appendingPathComponent("\(getppid())-alive.mp4"))
    rig.recorder.sweepTemporaryClips()
    #expect(rig.listing() == ["\(getppid())-alive.mp4"])
  }

  // MARK: fix round

  /// A clip from a tool call that starts and ends, so the next tool start has something to start from.
  private func oneClip(_ rig: Rig, color: Data = red) async {
    rig.fake.emit("T", color, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    await rig.endClip()
  }

  @Test func aDroppedConnectionIsReopenedByTheNextToolStart() async throws {
    let rig = try Rig()
    rig.recorder.retryDelay = { _ in 3600 }   // only the tool start may bring it back
    await rig.startClip()
    await oneClip(rig)
    #expect(rig.captures().count == 1)

    rig.fake.onEvent?(.closed)
    await rig.recorder.settle()
    rig.clock.advance(1)
    rig.tool(.start)
    await rig.recorder.settle()
    #expect(rig.fake.calls("open").count == 2)
    #expect(rig.fake.calls("start").count == 2)
    await oneClip(rig, color: green)
    #expect(rig.captures().count == 2)
  }

  @Test func recordingKeepsRetryingAfterMoreThanFiveFailures() async throws {
    let rig = try Rig()
    rig.recorder.retryDelay = { _ in 0.01 }
    rig.fake.openFailures = 8
    rig.hello()
    for _ in 0..<400 where rig.fake.calls("open").count < 9 { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(rig.fake.calls("open").count == 9)
    await rig.recorder.settle()
    rig.discovered()
    rig.page()
    rig.tool(.start)
    await rig.recorder.settle()
    #expect(rig.fake.calls("start") == ["T"])
  }

  @Test func aSocketThatClosesBeforeTheFailedOpenReturnsStillRetriesOnce() async throws {
    let rig = try Rig()
    rig.recorder.retryDelay = { _ in 0.01 }
    rig.fake.openFailures = 1
    rig.fake.closedFirst = true
    rig.hello()
    for _ in 0..<400 where rig.fake.calls("open").count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(rig.fake.calls("open").count == 2)
    #expect(rig.fake.calls("close") == [""])   // the failed attempt was closed, nothing else
  }

  @Test func theNextVisitIsRecordedAfterRecordingWasTurnedOffAndOn() async throws {
    let rig = try Rig()
    await rig.startClip()
    await oneClip(rig)
    rig.tool(.start)                       // a second visit, cut short by the switch
    await rig.recorder.settle()
    rig.fake.emit("T", green, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.allowed.on = false
    rig.recorder.refresh()
    await rig.recorder.settle()
    #expect(rig.captures().count == 2)

    rig.allowed.on = true
    rig.recorder.refresh()
    rig.tool(.end)
    rig.clock.advance(1)
    rig.tool(.start)
    await rig.recorder.settle()
    rig.fake.emit("T", blue, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    await rig.endClip()
    #expect(rig.captures().count == 3)
  }

  @Test func aStartThatBailedDoesNotLeaveTheRulesRecording() async throws {
    let rig = try Rig()
    rig.hello()
    await rig.recorder.settle()
    rig.discovered()
    rig.page()
    rig.allowed.on = false                 // switched off, and the recorder hasn't heard yet
    rig.tool(.start)                       // the rules say "start"; the recorder refuses
    await rig.recorder.settle()
    #expect(rig.fake.calls("attach").isEmpty)
    rig.allowed.on = true
    rig.tool(.end)
    rig.clock.advance(1)
    rig.tool(.start)                       // a fresh visit must start a fresh clip
    await rig.recorder.settle()
    #expect(rig.fake.calls("start") == ["T"])
  }

  @Test func theConnectionClosesWhenTheLastSessionGoes() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    await rig.recorder.settle()
    rig.clock.advance(2)
    rig.recorder.dropped(client: 1, at: rig.clock.now)
    await rig.recorder.settle()
    #expect(rig.fake.calls("close") == [""])
    #expect(rig.captures().count == 1)
  }

  @Test func theConnectionStaysWhileAnotherSessionIsHere() async throws {
    let rig = try Rig()
    rig.hello(client: 1)
    rig.hello(client: 2)
    await rig.recorder.settle()
    rig.recorder.dropped(client: 1, at: rig.clock.now)
    await rig.recorder.settle()
    #expect(rig.fake.calls("close").isEmpty)
  }

  @Test func aClipEndingBeforeTheLastFrameStillCloses() async throws {
    let rig = try Rig()
    await rig.startClip()
    rig.fake.emit("T", red, at: rig.clock.seconds + 0.1)
    rig.fake.emit("T", green, at: rig.clock.seconds + 60)   // later than the clip's own end (about 7 s)
    await rig.recorder.settle()
    await rig.endClip()
    let capture = try #require(rig.captures().first)
    #expect(try await play(rig.store.mediaFolder(session: session).appendingPathComponent(capture.file)).frames == 2)
  }

  @Test func theTempFolderIsNotASession() {
    #expect(!WorkStore.isSessionID(".tmp-clips"))
  }
}

// MARK: the connection

@Suite struct ScreencastConnectionTests {
  private func connection() -> (ScreencastConnection, Sent) {
    let sent = Sent()
    let connection = ScreencastConnection(port: 0)
    connection.outgoing = { sent.add($0) }
    connection.adopt(target: "T", session: "CDP")
    return (connection, sent)
  }

  final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return lines.compactMap(JSONValue.parse) }
    /// The nth command sent, once it has been.
    func next(_ index: Int) async throws -> JSONValue {
      for _ in 0..<400 {
        let sent = all
        if sent.count > index { return sent[index] }
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      throw CancellationError()
    }
  }

  @Test func everyFrameIsAckedWithItsNumberUnderTheCDPSession() throws {
    let (connection, sent) = connection()
    final class Got: @unchecked Sendable { var frames: [(String, Int, Double)] = [] }
    let got = Got()
    connection.onFrame = { target, data, at in got.frames.append((target, data.count, at)) }
    connection.handle(text: ackFrame(7, session: "CDP", timestamp: 1000.5, data: red))

    let ack = try #require(sent.all.first)
    #expect(ack["method"]?.string == "Page.screencastFrameAck")
    #expect(ack["params"]?["sessionId"]?.int == 7)
    #expect(ack["sessionId"]?.string == "CDP")
    #expect(got.frames.count == 1)
    #expect(got.frames.first?.0 == "T")
    #expect(got.frames.first?.1 == red.count)
    #expect(got.frames.first?.2 == 1000.5)
  }

  @Test func framesNobodyWantsAreStillAcked() throws {
    let (connection, sent) = connection()
    connection.onFrame = nil
    connection.handle(text: ackFrame(8, session: "CDP", timestamp: 1, data: red))
    connection.handle(text: ackFrame(9, session: "OTHER", timestamp: 2, data: red))   // a session we never mapped
    let numbers = sent.all.compactMap { $0["params"]?["sessionId"]?.int }
    #expect(numbers == [8, 9])
    #expect(sent.all.map { $0["sessionId"]?.string } == ["CDP", "OTHER"])
  }

  @Test func targetEventsBecomeScreencastEvents() throws {
    let (connection, _) = connection()
    final class Seen: @unchecked Sendable { var events: [ScreencastEvent] = [] }
    let seen = Seen()
    connection.deliverEvent = { seen.events.append($0) }
    connection.handle(text: """
      {"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"A","type":"page","url":"http://x/"}}}
      """)
    connection.handle(text: """
      {"method":"Target.targetInfoChanged","params":{"targetInfo":{"targetId":"A","type":"page","url":"http://x/y"}}}
      """)
    connection.handle(text: """
      {"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"W","type":"service_worker","url":"http://x/sw.js"}}}
      """)
    connection.handle(text: #"{"method":"Target.targetDestroyed","params":{"targetId":"A"}}"#)
    #expect(seen.events == [.created(target: "A", url: "http://x/"), .changed(target: "A", url: "http://x/y"),
                            .destroyed(target: "A")])
  }
}

extension ScreencastConnectionTests {
  @Test func aSessionThatIsGoneIsForgottenSoTheNextClipAttachesAgain() async throws {
    let (connection, sent) = connection()
    let start = Task { try? await connection.startScreencast(target: "T") }
    let first = try await sent.next(0)
    #expect(first["method"]?.string == "Page.startScreencast")
    connection.deliver(text: #"{"id":\#(first["id"]!.int!),"error":{"message":"Session with given id not found."}}"#)
    await start.value

    let attach = Task { try? await connection.attach(target: "T") }
    let second = try await sent.next(1)
    #expect(second["method"]?.string == "Target.attachToTarget")
    connection.deliver(text: #"{"id":\#(second["id"]!.int!),"result":{"sessionId":"NEW"}}"#)
    await attach.value
  }

  @Test func anotherFailureKeepsTheAttachment() async throws {
    let (connection, sent) = connection()
    let start = Task { try? await connection.startScreencast(target: "T") }
    let first = try await sent.next(0)
    connection.deliver(text: #"{"id":\#(first["id"]!.int!),"error":{"message":"Internal error"}}"#)
    await start.value
    try await connection.attach(target: "T")   // cached: nothing is sent
    #expect(sent.all.count == 1)
  }
}

@Suite struct ClipSinkTests {
  @Test func aDecoderThatFallsBehindTakesOnlySoManyFrames() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clipsink-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let queue = DispatchQueue(label: "test-decode")
    let owner = ClipOwner(client: 1, claudePID: 1, session: nil, cwd: nil)
    let sink = try ClipSink(target: "T", url: home, file: folder.appendingPathComponent("a.mp4"), owner: owner, queue: queue)
    queue.suspend()
    for index in 0..<(ClipSink.deepest + 4) { sink.offer(red, at: 100 + Double(index) * 0.2) }   // never blocks
    // What the bound admits, counted before the encoder is involved: a realtime encoder that isn't ready drops frames
    // it was given (VideoWriter.append returns false), so the frames the video ends up with are not the count to check.
    #expect(sink.pending == ClipSink.deepest)
    queue.resume()
    let written = await sink.flush()
    #expect(written <= ClipSink.deepest)   // never more than were admitted, however many the encoder keeps
    await sink.cancel()
  }
}
