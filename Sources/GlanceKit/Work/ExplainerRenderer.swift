import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import GlanceCore
import WebKit

/// Why a render stopped, in words for the user: `step` is where Make explainer was, `message` says what happened and
/// where (the frame and scene, or the load).
public struct ExplainerFailure: Error, Sendable, LocalizedError {
  public let step: ExplainerStep
  public let message: String
  public init(step: ExplainerStep, message: String) { self.step = step; self.message = message }
  public var errorDescription: String? { message }
}

/// Command Center's Make explainer (spec 2026-11-01-command-center-design.md §4.3): draws Claude's `scenes.html`, a frame
/// at a time, into a silent video.
///
/// The page is untrusted code that Claude wrote from the user's work. So:
/// - it runs in a web view in no window, with a throwaway data store and no message handlers, and can read only its own
///   folder (WebKit's read access, and our navigation check as a second wall); the host answers every prompt, window
///   and camera request with no;
/// - nothing leaves the page: two content rules block `http(s)` and `ws(s)` (a render without them fails), and the
///   navigation delegate refuses anything but a `file` inside the folder (symlinks resolved) or a blank frame;
/// - its time is a fake clock (explainer/clock.js), so a frame looks the same however long it takes, and one harness
///   call (explainer/harness.js) shows the scene and seeks the animations;
/// - a page can hang the web process, and nothing in WebKit unsticks a running script. Every call that waits on the page
///   (the load, the assets wait, each frame's script and snapshot) has a watchdog; on a timeout the web process is
///   killed outright (`_webProcessIdentifier` + SIGKILL, measured in the preflight, F7) and the render fails naming the
///   frame. Studio isn't on the App Store, so the SPI is acceptable; if it ever goes away the failure says so.
///
/// Frames are taken on the main actor and encoded on a serial queue with a small, bounded backlog, so a slow encoder
/// slows the render down and never grows memory or stalls Studio's UI for long.
@MainActor public final class ExplainerRenderer {
  /// What `render` asks for each scene's narration: the words and a Kokoro voice id; the WAV and its length.
  public typealias Voice = (_ say: String, _ voice: String?) async throws -> (data: Data, ms: Int)

  static let width = 1280
  static let height = 720
  static let fps = 30
  static let bitrate = 4_000_000
  /// Frames waiting for the encoder at most.
  static let encoderBacklog = 3
  /// The longest the fonts and images wait may take; after it the render goes on with what has loaded.
  static let assetsCapSeconds = 5.0

  /// Blocks everything that could leave the page. Two rules: WebKit's rule compiler rejects a single regex with `|`.
  static let blockNetworkRules = #"""
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
    """#

  let voice: Voice

  /// The content rule list's JSON. Tests change it; nil applies none.
  var networkRules: String? = ExplainerRenderer.blockNetworkRules
  /// How long one call that waits on the page may take before the web process is killed.
  var watchdogSeconds = 10.0
  /// How long the whole render may take (the fake clock makes a slow scene slow, not wrong).
  var overallLimitSeconds = 15.0 * 60
  private(set) var lastKilledProcessID: Int32?
  private(set) var webProcessTerminations = 0
  /// What the page asked of the host and was refused or dismissed ("alert", "confirm", "prompt", "open", "media", ...).
  private(set) var uiEvents: [String] = []
  /// The pixel width of the last snapshot taken.
  private(set) var lastSnapshotWidth = 0
  /// The page's web process, if this WebKit lets us find it.
  var webProcessIdentifier: Int32? {
    let key = "_webProcessIdentifier"
    guard let web, web.responds(to: NSSelectorFromString(key)),
          let pid = (web.value(forKey: key) as? NSNumber)?.int32Value, pid > 1, pid != getpid() else { return nil }
    return pid
  }

  /// Tests only: the folder WebKit is told it may read from, in place of the scene folder. Our own check still applies.
  var readAccessOverride: URL?

  /// Whether a file URL is inside `folder` once symlinks and `..` are resolved. A sibling that merely starts with the
  /// folder's name is outside.
  static func isInside(_ url: URL, folder: URL) -> Bool {
    guard url.isFileURL else { return false }
    func resolved(_ url: URL) -> String { URL(fileURLWithPath: url.path).resolvingSymlinksInPath().standardizedFileURL.path }
    let root = resolved(folder)
    let path = resolved(url)
    return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }

  /// The point width to ask a snapshot for so that it comes out `pixels` wide, given a first try that came out `got` wide
  /// (a Retina Mac turns points into twice the pixels).
  static func pointWidth(forPixels pixels: Int, got: Int, asked: Double) -> Double {
    guard got > 0 else { return asked }
    return asked * Double(pixels) / Double(got)
  }

  private var web: WKWebView?
  private var delegate: PageDelegate?
  private var cancelled = false
  /// A render is running on this instance; `generation` tells which one, so a late cancel hop can't reach the next.
  private var rendering = false
  private var generation = 0
  /// The scene folder: the only place a `file:` navigation may go.
  private var sceneFolder: URL?
  /// The web process has ended (killed by us or crashed), so the next call fails at once instead of waiting it out.
  private var webProcessEnded = false
  private var killSent = false
  /// The point width the snapshot is asked for; learned from the first picture so the result is 1280 px wide.
  private var snapshotPoints = Double(ExplainerRenderer.width)
  /// Ends the call being waited on, with the error given. Nil between calls.
  private var inFlight: ((Error) -> Void)?
  /// Where the render is, for failure messages: "frame 4 of 30 (scene 'a')".
  private var context = ""
  private var loadWaiter: ((Result<Void, Error>) -> Void)?
  private var loadNavigation: WKNavigation?
  /// A whole `render` is running (narration, frames, mux).
  private var making = false
  private var muxTask: Task<Void, Error>?

  /// Run before an append and before the writer is cancelled, so a test can make those calls stick.
  struct EncodeHooks: Sendable {
    var beforeAppend: (@Sendable () -> Void)?
    var beforeCancel: (@Sendable () -> Void)?
  }
  var encodeHooks = EncodeHooks()
  /// How long a failed or cancelled render waits for the encoder to stop before it ends anyway.
  var teardownLimit = VideoMux.Limits().cleanup

  public init(voice: @escaping Voice = ExplainerVoice.wav) { self.voice = voice }

  /// Draws `<folder>/scenes.html` into `<folder>/video.mp4`, 1280x720 at 30 fps, for the slots given. Silent: the
  /// narration is added afterwards. `progress` gets 0...1 after each frame.
  /// Throws `ExplainerFailure` (a hung or broken page, no network block, the time limit) or `CancellationError`.
  public func renderFrames(folder: URL, slots: [ExplainerTimeline.Slot], progress: @escaping (Double) -> Void) async throws -> URL {
    guard !rendering else {
      throw ExplainerFailure(step: .rendering, message: "a render is already running; wait for it or cancel it first")
    }
    rendering = true
    generation += 1
    let mine = generation
    defer { rendering = false }
    cancelled = false
    lastKilledProcessID = nil
    uiEvents = []
    context = ""
    return try await withTaskCancellationHandler {
      try await render(folder: folder, slots: slots, progress: progress)
    } onCancel: {
      Task { @MainActor [weak self] in
        if let self, self.rendering, self.generation == mine { self.cancel() }
      }
    }
  }

  /// Stops the render: between frames at the next one, and at once if it is waiting on the page, whose web process is
  /// killed. The render throws `CancellationError` and leaves no video.
  public func cancel() {
    cancelled = true
    muxTask?.cancel()
    guard let abort = inFlight else { return }
    killWebProcess()
    abort(CancellationError())
  }

  // MARK: the finished video

  /// Everything Make explainer does after Claude has written the folder: reads `narration.json` and `scenes.html`,
  /// narrates each scene with Glance Voice, plans the film, draws it and adds the narration. Returns
  /// `<folder>/explainer.mp4`; the silent `video.mp4` is not left behind. Throws `ExplainerFailure` (the step says
  /// where) or `CancellationError`, and a failed or cancelled run leaves no `explainer.mp4`.
  public func render(folder: URL, progress: @escaping (ExplainerStep, Double) -> Void) async throws -> URL {
    guard !making else {
      throw ExplainerFailure(step: .rendering, message: "a render is already running; wait for it or cancel it first")
    }
    making = true
    defer { making = false; muxTask = nil }
    cancelled = false
    let output = folder.appendingPathComponent("explainer.mp4")
    let silent = folder.appendingPathComponent("video.mp4")
    try? FileManager.default.removeItem(at: output)
    try? FileManager.default.removeItem(at: silent)

    let script = try Self.readScript(in: folder)
    let ids = script.scenes.map(\.id)
    var narrationMs: [String: Int] = [:]
    var clips: [String: [Float]] = [:]
    let voiceID = Prefs.kokoroVoice.id   // Kokoro always, even when a cloud voice is selected for Glance's own speech
    for (index, scene) in script.scenes.enumerated() {
      if cancelled || Task.isCancelled { throw CancellationError() }
      progress(.narrating, Double(index) / Double(ids.count))
      if scene.say.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }   // nothing to say, nothing to ask for
      do {
        let spoken = try await voice(scene.say, voiceID)
        clips[scene.id] = try ExplainerVoice.samples(fromWAV: spoken.data)
        narrationMs[scene.id] = spoken.ms
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        if cancelled { throw CancellationError() }
        throw ExplainerFailure(step: .narrating, message: "couldn't narrate scene '\(scene.id)': \(error.localizedDescription)")
      }
    }
    progress(.narrating, 1)

    let slots = ExplainerTimeline.plan(script: script, narrationMs: narrationMs)
    guard let last = slots.last else { throw ExplainerFailure(step: .rendering, message: "there are no scenes to render") }
    let totalMs = last.startMs + last.durationMs
    let joined = Self.joinNarration(slots.map { slot in
      NarrationClip(startMs: slot.startMs, durationMs: slot.durationMs, samples: clips[slot.id] ?? [])
    }, totalMs: totalMs)
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("explainer-narration-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    do {
      try Self.writeNarration(joined, to: wav)
    } catch {
      throw ExplainerFailure(step: .narrating, message: "couldn't save the narration (\(error.localizedDescription))")
    }

    if cancelled || Task.isCancelled { throw CancellationError() }   // renderFrames starts afresh and would forget a cancel
    progress(.rendering, 0)
    let video = try await renderFrames(folder: folder, slots: slots) { progress(.rendering, $0) }
    defer { try? FileManager.default.removeItem(at: video) }

    if cancelled || Task.isCancelled { throw CancellationError() }
    progress(.muxing, 0)
    let mux = Task { try await VideoMux.addAudio(video: video, audio: wav, to: output) }
    muxTask = mux
    do {
      try await withTaskCancellationHandler { try await mux.value } onCancel: { mux.cancel() }
    } catch {
      try? FileManager.default.removeItem(at: output)
      if cancelled || error is CancellationError { throw CancellationError() }
      throw ExplainerFailure(step: .muxing, message: "couldn't add the narration to the video (\(error.localizedDescription))")
    }
    progress(.muxing, 1)
    if cancelled || Task.isCancelled {   // a cancel that came with the last step can't return the video
      try? FileManager.default.removeItem(at: output)
      throw CancellationError()
    }
    return output
  }

  /// `narration.json`, checked against `scenes.html`: everything that can be wrong with what Claude wrote, found before
  /// any narration is paid for. These fail the writing step.
  static func readScript(in folder: URL) throws -> ExplainerScript {
    func fail(_ message: String) -> ExplainerFailure { ExplainerFailure(step: .writing, message: message) }
    guard let json = try? Data(contentsOf: folder.appendingPathComponent("narration.json")) else {
      throw fail("narration.json isn't in the folder")
    }
    guard let html = try? String(contentsOf: folder.appendingPathComponent("scenes.html"), encoding: .utf8) else {
      throw fail("scenes.html isn't in the folder")
    }
    switch ExplainerScript.parse(json) {
    case .failure(let problem): throw fail(describe(problem))
    case .success(let script):
      if let problem = script.validate(html: html) { throw fail(describe(problem)) }
      return script
    }
  }

  private static func describe(_ problem: ExplainerScript.Problem) -> String {
    switch problem {
    case .unreadable(let detail): return "narration.json isn't usable (\(detail))"
    case .noScenes: return "narration.json has no scenes"
    case .duplicateId(let id): return "narration.json has the scene '\(id)' twice"
    case .tooLong(let id): return "the narration of scene '\(id)' is over \(ExplainerScript.maxSayCharacters) characters"
    case .tooManyScenes(let count): return "narration.json has \(count) scenes; the most is \(ExplainerScript.maxScenes)"
    case .missingSection(let id): return "scenes.html has no <section data-scene=\"\(id)\"> for the scene in narration.json"
    }
  }

  /// One scene's narration and the slot it must fit.
  struct NarrationClip {
    let startMs: Int
    let durationMs: Int
    let samples: [Float]
  }

  /// All the clips on one 24 kHz timeline of `totalMs`, silence between. A clip longer than its slot is cut at the
  /// slot's end (the 300 s cap cuts the last one), and nothing goes past `totalMs`.
  static func joinNarration(_ clips: [NarrationClip], totalMs: Int) -> [Float] {
    let rate = ExplainerVoice.sampleRate
    let total = max(0, totalMs) * rate / 1000
    var timeline = [Float](repeating: 0, count: total)
    for clip in clips {
      let start = min(max(0, clip.startMs) * rate / 1000, total)
      let end = min(start + max(0, clip.durationMs) * rate / 1000, total)
      let count = min(clip.samples.count, end - start)
      if count > 0 { timeline.replaceSubrange(start..<(start + count), with: clip.samples[0..<count]) }
    }
    return timeline
  }

  /// A mono 16-bit 24 kHz WAV file.
  static func writeNarration(_ samples: [Float], to url: URL) throws {
    let rate = Double(ExplainerVoice.sampleRate)
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ])
    for buffer in AudioBuffers.make(floats: samples, sampleRate: rate) { try file.write(from: buffer) }
  }

  // MARK: the render

  private func render(folder: URL, slots: [ExplainerTimeline.Slot], progress: @escaping (Double) -> Void) async throws -> URL {
    let videoURL = folder.appendingPathComponent("video.mp4")
    try? FileManager.default.removeItem(at: videoURL)   // no render, failed or not, leaves the last one's video behind
    guard let last = slots.last else { throw failure("there are no scenes to render") }
    let totalMs = last.startMs + last.durationMs
    guard totalMs > 0 else { throw failure("the scenes have no length") }
    let frameCount = max(1, Int((Double(totalMs) * Double(Self.fps) / 1000).rounded()))
    let page = folder.appendingPathComponent("scenes.html")
    guard FileManager.default.fileExists(atPath: page.path) else { throw failure("scenes.html isn't in the folder") }

    var sink: FrameSink?
    do {
      try await openWebView()
      context = "loading scenes.html"
      try await load(page, readAccess: folder)
      try await waitForAssets()
      let writer = try VideoWriter(url: videoURL, width: Self.width, height: Self.height, bitrate: Self.bitrate,
                                   fps: Self.fps, keyframeSeconds: 2, realtime: false)
      let frames = FrameSink(writer: writer, depth: Self.encoderBacklog, hooks: encodeHooks)
      sink = frames

      let started = ProcessInfo.processInfo.systemUptime
      var shown: ExplainerTimeline.Slot?
      for i in 0..<frameCount {
        if cancelled { throw CancellationError() }
        let ms = Double(i) * 1000 / Double(Self.fps)
        let slot = ExplainerTimeline.slot(at: Int(ms), in: slots)?.slot ?? shown ?? slots[0]
        context = "frame \(i + 1) of \(frameCount) (scene '\(slot.id)')"
        if ProcessInfo.processInfo.systemUptime - started > overallLimitSeconds {
          throw failure("took longer than \(Self.describe(overallLimitSeconds)), so it was stopped")
        }
        try await frames.waitForRoom { self.cancelled }
        if cancelled { throw CancellationError() }
        if let problem = frames.problem { throw failure(problem) }

        let changed = slot.startMs != shown?.startMs || slot.id != shown?.id
        shown = slot
        let found = try await evaluate(Self.frameScript(ms: ms, slot: slot, sceneChanged: changed))
        if changed, (found as? Bool) == false {
          throw failure("the page has no <section data-scene=\"\(slot.id)\">")
        }
        let image = try await snapshot()
        frames.submit(image, at: Double(i) / Double(Self.fps))
        progress(Double(i + 1) / Double(frameCount))
      }
      context = "finishing the video"
      try await frames.drain { self.cancelled }
      if cancelled { throw CancellationError() }   // a cancel during the last frames can't come back as a video
      if let problem = frames.problem { throw failure(problem) }
      try? await Task.sleep(nanoseconds: 50_000_000)   // a termination report that is still on its way
      if pageProcessIsGone() { throw failure("the page's process ended") }   // the last picture may be blank
      try await frames.writer.finish(at: Double(totalMs) / 1000)
      await closeWebView()
      return videoURL
    } catch {
      sink?.stop()
      await closeWebView()
      await sink?.cancelWriter(limit: teardownLimit)
      try? FileManager.default.removeItem(at: videoURL)
      if cancelled || error is CancellationError { throw CancellationError() }
      throw error
    }
  }

  /// The one script run per frame: the clock to the frame's time, the scene if it just started, the seek in the scene's
  /// own time. Returns false when the scene has no section.
  static func frameScript(ms: Double, slot: ExplainerTimeline.Slot, sceneChanged: Bool) -> String {
    // After the scene starts, one animation-frame round at the same time, so a glance:scene listener's rAF has painted.
    let scene = sceneChanged ? "ok=__glanceScene(\(jsString(slot.id)),\(slot.durationMs));__clock.flushFrame();" : ""
    return "(function(){__clock.advanceTo(\(ms));var ok=true;\(scene)__glanceSeek(\(ms - Double(slot.startMs)));return ok;})()"
  }

  private static func jsString(_ text: String) -> String {
    (try? String(data: JSONEncoder().encode(text), encoding: .utf8)) ?? "\"\""
  }

  private static func describe(_ seconds: Double) -> String {
    seconds >= 120 ? "\(Int(seconds / 60)) minutes" : seconds >= 10 ? "\(Int(seconds)) s" : String(format: "%.1f s", seconds)
  }

  private func failure(_ message: String) -> ExplainerFailure {
    ExplainerFailure(step: .rendering, message: context.isEmpty ? message : "\(context): \(message)")
  }

  // MARK: the web view

  private func openWebView() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    for name in ["clock", "harness"] {
      guard let source = try? String(contentsOf: Resources.explainerScript(name), encoding: .utf8) else {
        throw failure("the render script \(name).js is missing from this build")
      }
      configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))   // iframes get the same fake clock and WebRTC block
    }
    if let rules = networkRules {
      let list: WKContentRuleList?
      do {
        list = try await WKContentRuleListStore.default()?.compileContentRuleList(
          forIdentifier: "dev.glance.explainer.no-network", encodedContentRuleList: rules)
      } catch {
        throw failure("couldn't set up the network block (\(error.localizedDescription)); not rendering without it")
      }
      guard let list else { throw failure("couldn't set up the network block; not rendering without it") }
      configuration.userContentController.add(list)
    }
    let pageDelegate = PageDelegate(renderer: self)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), configuration: configuration)
    view.navigationDelegate = pageDelegate
    view.uiDelegate = pageDelegate
    delegate = pageDelegate
    webProcessEnded = false
    killSent = false
    pageProcessID = nil
    snapshotPoints = Double(Self.width)
    web = view
  }

  /// Lets go of the web view, and always ends its web process first: a worker's `while(true){}` never trips the
  /// watchdog and would outlive the render. Waits (briefly) for WebKit to report the process gone, unless it already has.
  private func closeWebView() async {
    if web != nil, !webProcessEnded, killWebProcess() {
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while !webProcessEnded, ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    web?.navigationDelegate = nil
    web?.uiDelegate = nil
    web = nil
    delegate = nil
    loadWaiter = nil
    loadNavigation = nil
    sceneFolder = nil
  }

  private func load(_ page: URL, readAccess folder: URL) async throws {
    guard let web else { throw failure("the page isn't open") }
    try await watched(seconds: watchdogSeconds) { (finish: @escaping (Result<Void, Error>) -> Void) in
      loadWaiter = finish
      sceneFolder = folder
      loadNavigation = web.loadFileURL(page, allowingReadAccessTo: readAccessOverride ?? folder)
    }
    loadWaiter = nil
  }

  /// The fonts and images, with the cap kept natively: the page's own timers are the fake clock's. After the cap the
  /// render goes on with what has loaded, but a page that is stuck instead of slow is told apart by a ping under the
  /// watchdog.
  private func waitForAssets() async throws {
    guard let web else { throw failure("the page isn't open") }
    context = "waiting for fonts and images"
    let finished: Bool = try await pageCall(seconds: Self.assetsCapSeconds, onTimeout: { false }) { (finish: @escaping (Result<Bool, Error>) -> Void) in
      web.callAsyncJavaScript(
        "await document.fonts.ready; await Promise.all(Array.from(document.images, i => i.decode().catch(() => {}))); return true;",
        arguments: [:], in: nil, in: .page) { result in
          switch result {
          case .success: finish(.success(true))
          case .failure(let error): finish(.failure(PageCallError(underlying: error, text: Self.message(for: error))))
          }
        }
    }
    if !finished { _ = try await evaluate("1") }
  }

  private func evaluate(_ script: String) async throws -> Any? {
    guard let web else { throw failure("the page isn't open") }
    noteProcessID()
    return try await pageCall(seconds: watchdogSeconds) { (finish: @escaping (Result<Any?, Error>) -> Void) in
      web.evaluateJavaScript(script) { value, error in
        if let error { finish(.failure(PageCallError(underlying: error, text: Self.message(for: error)))) } else { finish(.success(value)) }
      }
    }
  }

  private func snapshot() async throws -> CGImage {
    guard let web else { throw failure("the page isn't open") }
    for attempt in 0..<2 {
      let asked = snapshotPoints
      let configuration = WKSnapshotConfiguration()
      configuration.rect = CGRect(x: 0, y: 0, width: Self.width, height: Self.height)
      configuration.snapshotWidth = NSNumber(value: asked)
      configuration.afterScreenUpdates = true
      noteProcessID()
      let image = try await pageCall(seconds: watchdogSeconds) { (finish: @escaping (Result<CGImage, Error>) -> Void) in
        web.takeSnapshot(with: configuration) { image, error in
          if let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            finish(.success(cg))
          } else {
            finish(.failure(PageCallError(underlying: error, text: "couldn't take the picture of the page\(error.map { " (\($0.localizedDescription))" } ?? "")")))
          }
        }
      }
      // A picture taken as the process died can be blank: it counts only if the process is still there.
      if pageProcessIsGone() { throw failure("the page's process ended") }
      lastSnapshotWidth = image.width
      if image.width == Self.width || attempt == 1 { return image }
      // A 2x display makes points into twice the pixels: ask for the point width that gives 1280, and keep it.
      snapshotPoints = Self.pointWidth(forPixels: Self.width, got: image.width, asked: asked)
    }
    throw failure("couldn't take the picture of the page")
  }

  private static func message(for error: Error) -> String {
    let info = (error as NSError).userInfo
    if let text = info["WKJavaScriptExceptionMessage"] as? String { return "the page's script failed: \(text)" }
    return error.localizedDescription
  }

  // MARK: the page's process

  /// WebKit's answer to a call that failed, kept raw until `pageCall` can tell whether the process is gone.
  private struct PageCallError: Error {
    let underlying: Error?
    let text: String
  }

  /// `watched`, for a call to the page. A failure that WebKit reports as the page's process dying is reported as that
  /// (its completion can come before `webViewWebContentProcessDidTerminate`, and says only "unsupported type" or a bare
  /// picture error), whichever of the two arrives first.
  private func pageCall<T>(seconds: Double, onTimeout: (() -> T)? = nil,
                           _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    do {
      return try await watched(seconds: seconds, onTimeout: onTimeout, start)
    } catch let call as PageCallError {
      throw await pageFailure(call)
    }
  }

  private func pageFailure(_ call: PageCallError) async -> ExplainerFailure {
    if pageProcessIsGone() { return failure("the page's process ended") }
    // An error that only a dead process explains (or a failed picture, which says nothing): give the termination report
    // a moment to arrive. A page's own script error is exactly what it says and isn't waited on.
    var code: WKError.Code?
    if let nsError = call.underlying as NSError?, nsError.domain == WKError.errorDomain { code = WKError.Code(rawValue: nsError.code) }
    let mayBeDeath = call.underlying == nil || code == .webContentProcessTerminated || code == .javaScriptResultTypeIsUnsupported
    if mayBeDeath {
      let deadline = ProcessInfo.processInfo.systemUptime + 1.0
      while ProcessInfo.processInfo.systemUptime < deadline {
        if code == .webContentProcessTerminated || pageProcessIsGone() { webProcessEnded = true; return failure("the page's process ended") }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
    }
    return failure(call.text)
  }

  /// The pid of the web process, remembered while it lives so its death can be seen later.
  private var pageProcessID: Int32?

  private func noteProcessID() {
    if let pid = webProcessIdentifier { pageProcessID = pid }
  }

  /// Whether the web process has ended: WebKit said so, or its pid is gone.
  private func pageProcessIsGone() -> Bool {
    if webProcessEnded { return true }
    guard let pid = pageProcessID else { return false }
    return kill(pid, 0) == -1 && errno == ESRCH
  }

  // MARK: the watchdog

  /// Starts a call that answers through `finish`, and waits for it. Exactly one of these ends the wait, and the rest are
  /// ignored: the answer, the watchdog, `cancel()`, or the web process ending. On the watchdog the web process is killed
  /// and the wait throws; with `onTimeout`, the wait returns that value instead and the page is left alone.
  private func watched<T>(seconds: Double, onTimeout: (() -> T)? = nil,
                          _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
    if webProcessEnded { throw failure("the page's process ended") }
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
      let call = WatchedCall()
      let finish: (Result<T, Error>) -> Void = { [weak self] result in
        guard !call.done else { return }
        call.done = true
        call.timer?.cancel()
        self?.inFlight = nil
        continuation.resume(with: result)
      }
      inFlight = { finish(.failure($0)) }
      call.timer = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        guard let self, !call.done, !Task.isCancelled else { return }
        if let onTimeout {
          finish(.success(onTimeout()))
        } else {
          let killed = self.killWebProcess()
          finish(.failure(self.failure(
            "the page didn't answer within \(Self.describe(seconds))" + (killed
              ? " and was stopped"
              : " and couldn't be stopped (this macOS has no _webProcessIdentifier); quit and reopen Glance Studio"))))
        }
      }
      start(finish)
    }
  }

  private final class WatchedCall {
    var done = false
    var timer: Task<Void, Never>?
  }

  /// SIGKILLs the page's web process: nothing else stops a running script. False when this WebKit has no way to find it.
  @discardableResult
  private func killWebProcess() -> Bool {
    if killSent { return true }   // once per web view: its pid could be reused by now
    // No fallback: `_killWebContentProcess` was measured ineffective (F7), so without the pid nothing was stopped.
    guard let pid = webProcessIdentifier else { return false }
    killSent = true
    lastKilledProcessID = pid
    kill(pid, SIGKILL)
    return true
  }

  // MARK: the delegate

  fileprivate func didFinish(_ navigation: WKNavigation?) {
    guard navigation != nil, navigation === loadNavigation else { return }
    loadWaiter?(.success(()))
  }

  fileprivate func didFail(_ navigation: WKNavigation?, _ error: Error) {
    guard navigation != nil, navigation === loadNavigation else { return }   // the page tried to leave and was refused
    loadWaiter?(.failure(failure("couldn't load scenes.html (\(error.localizedDescription))")))
  }

  fileprivate func processEnded() {
    webProcessTerminations += 1
    webProcessEnded = true
    inFlight?(failure("the page's process ended"))
  }

  fileprivate func noted(_ event: String) { uiEvents.append(event) }

  fileprivate func mayNavigate(to url: URL?) -> Bool {
    guard let url else { return false }
    switch url.scheme?.lowercased() {
    case "about": return true   // blank and srcdoc frames; the content rules keep them off the network
    case "file": return sceneFolder.map { Self.isInside(url, folder: $0) } ?? false
    default: return false
    }
  }

  private final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var renderer: ExplainerRenderer?
    init(renderer: ExplainerRenderer) { self.renderer = renderer }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      // The page may be on a file inside its folder, or a blank frame. Everything else (a file outside, http, ws, data,
      // blob, ...) stays where it is.
      decisionHandler(renderer?.mayNavigate(to: navigationAction.request.url) == true ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { renderer?.didFinish(navigation) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { renderer?.didFail(navigation, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      renderer?.didFail(navigation, error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { renderer?.processEnded() }

    // The page asks the host for things; the host says no, at once, and never shows a panel.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
      renderer?.noted("media")
      decisionHandler(.deny)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
      renderer?.noted("open")
      return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
      renderer?.noted("alert")
      completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
      renderer?.noted("confirm")
      completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
      renderer?.noted("prompt")
      completionHandler(nil)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
      renderer?.noted("filePicker")
      completionHandler(nil)
    }
  }
}

/// Hands frames to a serial queue that waits for the encoder and appends them. At most `depth` are waiting, so the
/// render loop (on the main actor) slows to the encoder's pace instead of piling pictures up.
private final class FrameSink: @unchecked Sendable {
  let writer: VideoWriter
  private let depth: Int
  private let queue = DispatchQueue(label: "dev.glance.explainer.encode")
  private let lock = NSLock()
  private var waiting = 0
  private var stopped = false
  private var failed: String?

  private let hooks: ExplainerRenderer.EncodeHooks

  init(writer: VideoWriter, depth: Int, hooks: ExplainerRenderer.EncodeHooks) { self.writer = writer; self.depth = depth; self.hooks = hooks }

  /// What went wrong on the queue, if anything: the encoder stalled or refused a frame.
  var problem: String? { lock.lock(); defer { lock.unlock() }; return failed }

  /// Gives up on the frames still waiting. Doesn't wait for the queue.
  func stop() {
    lock.lock(); stopped = true; lock.unlock()
  }

  /// Stops the writer and removes its partial file, on the queue, so nothing is appending meanwhile (the writer is touched
  /// from one context at a time). `append` and `cancelWriting` can block, and this runs on the main actor, so it waits for
  /// the queue without blocking and for at most `limit`. A queue that takes longer gets to the cancel when it comes back.
  @MainActor func cancelWriter(limit: TimeInterval) async {
    let (queue, writer, hooks) = (queue, writer, hooks)
    _ = await VideoLimit.called(within: limit) { done in
      queue.async {
        hooks.beforeCancel?()
        writer.cancel()
        done()
      }
    } whenLate: {}
  }

  func submit(_ image: CGImage, at seconds: Double) {
    lock.lock(); waiting += 1; lock.unlock()
    queue.async { [self] in
      defer { lock.lock(); waiting -= 1; lock.unlock() }
      lock.lock(); let skip = stopped || failed != nil; lock.unlock()
      if skip { return }
      let deadline = ProcessInfo.processInfo.systemUptime + 10
      while !writer.isReady {
        lock.lock(); let quit = stopped; lock.unlock()
        if quit { return }
        if ProcessInfo.processInfo.systemUptime > deadline { fail("the video encoder stopped taking frames"); return }
        usleep(1_000)
      }
      hooks.beforeAppend?()
      if !writer.append(image, at: seconds) { fail("the video encoder refused the frame at \(String(format: "%.2f", seconds)) s") }
    }
  }

  private func fail(_ message: String) { lock.lock(); if failed == nil { failed = message }; lock.unlock() }

  private var pending: Int { lock.lock(); defer { lock.unlock() }; return waiting }

  /// Returns when there's room for another frame (or something went wrong, or `isCancelled`).
  func waitForRoom(isCancelled: () -> Bool) async throws {
    while pending >= depth, problem == nil, !isCancelled() { try await Task.sleep(nanoseconds: 1_000_000) }
  }

  /// Returns when every submitted frame has been appended or given up on.
  func drain(isCancelled: () -> Bool) async throws {
    while pending > 0, !isCancelled() { try await Task.sleep(nanoseconds: 2_000_000) }
  }
}
