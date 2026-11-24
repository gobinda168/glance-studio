import AVFoundation
import Foundation
import GlanceCore
import Network
import Testing
import WebKit
@testable import GlanceKit

// A real WKWebView with the sandbox the app uses. Run under the perl alarm guard:
//   perl -e 'alarm 300; exec @ARGV' scripts/build.sh test --filter ExplainerPageWebTests

private final class Listener: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  var messages: [[String: Any]] = []
  var leaks: [String] = []
  var loaded = false
  var navigationsRefused = 0

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    if message.name == "leak" { leaks.append("\(message.body)") } else if let body = message.body as? [String: Any] { messages.append(body) }
  }

  @MainActor func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    let allowed = ExplainerPageWeb.allows(navigation: action, loaded: loaded)
    if !allowed { navigationsRefused += 1 }
    loaded = true
    return allowed ? .allow : .cancel
  }
}

/// Counts every request that reaches it.
private final class Server: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  let listener: NWListener
  private(set) var port: UInt16 = 0

  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      self?.lock.lock(); self?.count += 1; self?.lock.unlock()
      connection.cancel()
    }
    listener.start(queue: .global())
    ready.wait()
    port = listener.port!.rawValue
  }
  var hits: Int { lock.lock(); defer { lock.unlock() }; return count }
  func stop() { listener.cancel() }
}

@MainActor
private func open(_ fragment: String, dark: Bool = true) async throws -> (WKWebView, Listener) {
  let listener = Listener()
  let configuration = try await ExplainerPageWeb.configuration(handler: listener)
  // A handler in the page's own world: it stands for anything a page script could reach.
  configuration.userContentController.add(listener, name: "leak")
  let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 660, height: 800), configuration: configuration)
  view.navigationDelegate = listener
  view.loadHTMLString(ExplainerPage.wrap(fragment: fragment, css: try ExplainerPageWeb.css(), dark: dark), baseURL: nil)
  try await Task.sleep(nanoseconds: 1_500_000_000)
  return (view, listener)
}

@MainActor
private func inWorld(_ view: WKWebView, _ script: String) async throws -> Any? {
  try await view.evaluateJavaScript(script, in: nil, contentWorld: ExplainerPageWeb.world)
}

private let plain = #"""
<p class="answer">Short.</p>
<section data-beat="a"><h2>First</h2><p class="say">One sentence. Two sentences.</p>
<div class="viz"><div class="node in" style="--d:3s" data-detail="More words.">x</div></div></section>
<section data-beat="b"><h2>Second</h2><p class="say">Three.</p></section>
"""#

@Suite(.serialized) @MainActor struct ExplainerPageWebTests {
  @Test func aHostilePageDoesNothing() async throws {
    let server = try Server()
    defer { server.stop() }
    let base = "http://127.0.0.1:\(server.port)"
    let hostile = plain + """
      <script>window.__hostile = "inline"; webkit.messageHandlers.leak.postMessage("inline script");</script>
      <script src="\(base)/js"></script>
      <img src="\(base)/img" onerror="window.__hostile='onerror';webkit.messageHandlers.leak.postMessage('onerror')">
      <svg onload="window.__hostile='onload';webkit.messageHandlers.leak.postMessage('onload')"></svg>
      <link rel="stylesheet" href="\(base)/css">
      <style>@import url("\(base)/import"); body { background-image: url("\(base)/bg"); } </style>
      <iframe src="\(base)/frame"></iframe>
      <iframe srcdoc="<script>parent.__hostile='srcdoc'</script>"></iframe>
      <form action="\(base)/form"><input type="image" src="\(base)/input"></form>
      <meta http-equiv="refresh" content="0;url=\(base)/refresh">
      <a id="go" href="javascript:window.__hostile='link'">go</a>
      <base href="\(base)/">
      """
    let (view, listener) = try await open(hostile)
    defer { view.stopLoading() }
    #expect(listener.leaks.isEmpty, "a page script ran: \(listener.leaks)")
    let flag = try await view.evaluateJavaScript("String(window.__hostile)")
    #expect(flag as? String == "undefined")
    #expect(server.hits == 0, "the network was reached")
    #expect(view.url?.scheme != "http", "the page navigated away")
    #expect(listener.navigationsRefused == 0 || view.url?.absoluteString.hasPrefix("http") == false)
  }

  /// The control: the test above proves something only if the same script runs when the CSP isn't there.
  @Test func withoutTheCSPAPageScriptWouldRun() async throws {
    let listener = Listener()
    let configuration = try await ExplainerPageWeb.configuration(handler: listener)
    configuration.userContentController.add(listener, name: "leak")
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 660, height: 800), configuration: configuration)
    view.navigationDelegate = listener
    let page = ExplainerPage.wrap(fragment: plain + #"<script>webkit.messageHandlers.leak.postMessage("ran")</script>"#, css: "", dark: true)
      .replacingOccurrences(of: ExplainerPage.contentSecurityPolicy, with: "default-src * 'unsafe-inline'")
    view.loadHTMLString(page, baseURL: nil)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(listener.leaks == ["ran"])
  }

  @Test func thePageCantReachTheBridge() async throws {
    let (view, listener) = try await open(plain)
    defer { view.stopLoading() }
    #expect(listener.messages.contains { $0["type"] as? String == "ready" }, "Glance's own script ran")
    let reachable = try await view.evaluateJavaScript("typeof window.webkit?.messageHandlers?.explainer")
    #expect(reachable as? String == "undefined", "the bridge exists only in Glance's world")
    let api = try await view.evaluateJavaScript("typeof window.__explainer")
    #expect(api as? String == "undefined")
  }

  @Test func glancesScriptWorksUnderTheCSP() async throws {
    let (view, listener) = try await open(plain)
    defer { view.stopLoading() }
    #expect(listener.messages.contains { $0["type"] as? String == "height" && ($0["h"] as? NSNumber)?.doubleValue ?? 0 > 100 })
    #expect(try await inWorld(view, "document.querySelectorAll('.listen').length") as? Int == 2)
    #expect(try await inWorld(view, "document.querySelectorAll('.ask').length") as? Int == 2)
    #expect(try await inWorld(view, "document.querySelectorAll('[data-beat=a] .say span').length") as? Int == 2)
    // A beat at rest shows its finished state, whatever its animation's delay.
    #expect(try await inWorld(view, "getComputedStyle(document.querySelector('.node')).opacity") as? String == "1")
    _ = try await inWorld(view, "window.__explainer.time(0, 0.1, 5); 0")
    #expect(try await inWorld(view, "document.body.classList.contains('narrating')") as? Bool == true)
    #expect(listener.messages.contains { $0["type"] as? String == "beat" })
    #expect(try await inWorld(view, "Number(getComputedStyle(document.querySelector('.node')).opacity) < 1") as? Bool == true, "held back until its words")
    _ = try await inWorld(view, "window.__explainer.stop(); 0")
    #expect(try await inWorld(view, "document.body.classList.contains('narrating')") as? Bool == false)
    #expect(try await inWorld(view, "getComputedStyle(document.querySelector('.node')).opacity") as? String == "1")
  }

  @Test func clicksReachTheBridgeAsMessages() async throws {
    let (view, listener) = try await open(plain + #"<section data-beat="c"><h2>Third</h2><p class="say">Four.</p><div class="node" data-file="src/a.swift">f</div></section>"#)
    defer { view.stopLoading() }
    _ = try await inWorld(view, "document.querySelector('[data-beat=b] .listen').click(); document.querySelector('[data-beat=a] .ask').click(); document.querySelector('[data-file]').click(); 0")
    try await Task.sleep(nanoseconds: 100_000_000)
    let parsed = listener.messages.compactMap { ExplainerBridge.parse($0) }
    #expect(parsed.contains(.play(index: 1)))
    #expect(parsed.contains(.ask(title: "First")))
    #expect(parsed.contains(.open(path: "src/a.swift")))
    _ = try await inWorld(view, "document.querySelector('[data-detail]').click(); 0")
    #expect(try await inWorld(view, "document.querySelector('.detail').textContent") as? String == "More words.")
  }

  @Test func theFontsLoadAndTheThemeSwitches() async throws {
    let (view, _) = try await open(plain, dark: false)
    defer { view.stopLoading() }
    #expect(try await inWorld(view, "document.fonts.check('15px \"DM Sans\"')") as? Bool == true)
    let light = try await inWorld(view, "getComputedStyle(document.querySelector('.answer')).color") as? String
    _ = try await inWorld(view, "window.__explainer.theme('dark'); 0")
    let dark = try await inWorld(view, "getComputedStyle(document.querySelector('.answer')).color") as? String
    #expect(light == "rgb(28, 26, 23)")
    #expect(dark == "rgb(241, 237, 228)")
  }

  @Test func onlyTheFirstLoadIsAllowed() async throws {
    let (view, listener) = try await open(plain)
    defer { view.stopLoading() }
    #expect(listener.loaded)
    _ = try? await view.evaluateJavaScript("location.href = 'about:blank#next'; 0")
    view.load(URLRequest(url: URL(string: "http://127.0.0.1:1/x")!))
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(listener.navigationsRefused >= 1)
    #expect(view.url?.scheme != "http")
  }
}

@MainActor @Test func theRunIsLockedDown() {
  let arguments = ExplainerPageRun.arguments(systemPrompt: "/s.md")
  #expect(arguments.contains("--no-session-persistence"))
  #expect(arguments.contains("--strict-mcp-config"))
  #expect(arguments.contains("--disable-slash-commands"))
  #expect(arguments[arguments.firstIndex(of: "--tools")! + 1] == "")
  #expect(arguments[arguments.firstIndex(of: "--setting-sources")! + 1] == "")
  #expect(arguments[arguments.firstIndex(of: "--model")! + 1] == "claude-sonnet-5-5")
  #expect(arguments[arguments.firstIndex(of: "--settings")! + 1].contains("disableAllHooks"))
}

@MainActor @Test func theRunStreamsTheAnswerThenChecksThePage() async {
  let page = #"<p class="answer">Done.</p><section data-beat="a"><h2>t</h2><p class="say">s</p></section>"#
  let runner: ExplainerPageRun.Runner = { _, _, folder, _, onEvent in
    #expect(FileManager.default.fileExists(atPath: folder), "an empty folder of its own")
    onEvent(.text(#"<p class="answer">Do"#))
    onEvent(.text(#"ne.</p><sec"#))
    onEvent(.done(page))
    return ClaudeOneShot.Run()
  }
  var events: [ExplainerPageRun.Event] = []
  ExplainerPageRun(runner: runner).start(prompt: "p") { events.append($0) }
  #expect(events.count == 2)
  #expect(events.first == .answer("Done."))
  if case .page(let got) = events.last { #expect(got.beats.count == 1) } else { Issue.record("no page") }
}

@MainActor @Test func aRefusedPageIsAFailure() {
  let runner: ExplainerPageRun.Runner = { _, _, _, _, onEvent in
    onEvent(.done("Sorry, I can't do that."))
    return ClaudeOneShot.Run()
  }
  var events: [ExplainerPageRun.Event] = []
  ExplainerPageRun(runner: runner).start(prompt: "p") { events.append($0) }
  if case .failed(let message)? = events.last { #expect(message.contains("checks")) } else { Issue.record("no failure") }
}

@MainActor @Test func aCancelledRunSaysNothing() {
  var send: (@MainActor (ClaudeRunner.Event) -> Void)?
  let runner: ExplainerPageRun.Runner = { _, _, _, _, onEvent in
    send = onEvent
    return ClaudeOneShot.Run()
  }
  var events: [ExplainerPageRun.Event] = []
  let run = ExplainerPageRun(runner: runner)
  run.start(prompt: "p") { events.append($0) }
  run.cancel()
  send?(.failed("late"))
  #expect(events.isEmpty)
}

// MARK: The voice

/// Half a second of silence as a WAV, so these tests never make a sound.
private func silence(seconds: Double = 0.4) throws -> Data {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID().uuidString).wav")
  defer { try? FileManager.default.removeItem(at: url) }
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
  let frames = AVAudioFrameCount(24_000 * seconds)
  let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
  buffer.frameLength = frames
  do {
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
  }
  return try Data(contentsOf: url)
}

private func tempFiles(_ names: [String]) -> (URL, [URL]) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("explainer-voice-\(UUID().uuidString)", isDirectory: true)
  return (folder, names.map { folder.appendingPathComponent("\($0).wav") })
}

@Suite(.serialized) @MainActor struct ExplainerVoicePlayerTests {
  @Test func itPlaysEachBeatOnceAndSavesIt() async throws {
    let wav = try silence()
    var said: [String] = []
    let player = ExplainerVoicePlayer(voice: { text, _ in
      said.append(text)
      return (wav, 400)
    })
    let (folder, files) = tempFiles(["a", "b"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let beats = [ExplainerVoicePlayer.Beat(say: "one", file: files[0]), .init(say: "two", file: files[1])]
    player.toggleMute()
    var positions: [(Int, Double, Double)] = [], stopped: [String] = []
    player.onPosition = { _, beat, time, duration in positions.append((beat, time, duration)) }
    player.onStop = { stopped.append($0) }
    player.prepare(beats: beats)
    player.play(page: "p", beats: beats, from: 0)
    #expect(player.isPlaying)
    for _ in 0..<60 where player.current != nil { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(player.current == nil, "it ends by itself")
    #expect(stopped == ["p"])
    #expect(said.sorted() == ["one", "two"], "each beat made once, though two things asked")
    #expect(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(positions.contains { $0.0 == 0 }, "position reports for the first beat")
    #expect(positions.contains { $0.0 == 1 }, "and the second")
    #expect(positions.allSatisfy { $0.1 >= 0 && abs($0.2 - 0.4) < 0.05 })
  }

  @Test func aSavedBeatCostsNothing() async throws {
    let wav = try silence()
    var said = 0
    let player = ExplainerVoicePlayer(voice: { _, _ in
      said += 1
      return (wav, 400)
    })
    let (folder, files) = tempFiles(["a"])
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try wav.write(to: files[0])
    player.toggleMute()
    player.play(page: "p", beats: [.init(say: "one", file: files[0])])
    for _ in 0..<30 where player.current != nil { try await Task.sleep(nanoseconds: 100_000_000) }
    #expect(said == 0)
  }

  @Test func aVoiceThatFailsLeavesThePageAndSaysSo() async throws {
    struct Refused: Error {}
    let player = ExplainerVoicePlayer(voice: { _, _ in throw Refused() })
    let (folder, files) = tempFiles(["a"])
    defer { try? FileManager.default.removeItem(at: folder) }
    player.play(page: "p", beats: [.init(say: "one", file: files[0])])
    for _ in 0..<30 where player.current != nil { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(player.current == nil)
    #expect(player.unavailablePage == "p")
  }

  @Test func pauseHoldsAndStopEnds() async throws {
    let wav = try silence(seconds: 2)
    let player = ExplainerVoicePlayer(voice: { _, _ in (wav, 2000) })
    let (folder, files) = tempFiles(["a"])
    defer { try? FileManager.default.removeItem(at: folder) }
    player.toggleMute()
    player.play(page: "p", beats: [.init(say: "one", file: files[0])])
    try await Task.sleep(nanoseconds: 300_000_000)
    player.playPause()
    #expect(player.current?.playing == false)
    #expect(!player.isPlaying)
    player.playPause()
    #expect(player.isPlaying)
    player.stop(page: "other")
    #expect(player.current != nil, "another page's stop leaves this one")
    player.stop(page: "p")
    #expect(player.current == nil)
  }
}

@MainActor @Test func listenSaysTheProseNotTheCode() {
  let segments = ReplyVoice.segments("Fixed **it**.\n\n```swift\nlet a = 1\n```\n\n- one\n- two")
  #expect(segments.map(\.text).joined(separator: " ").contains("Fixed it"))
  #expect(!segments.map(\.text).joined().contains("let a"))
  #expect(ReplyVoice.segments("```\nonly code\n```").isEmpty)
}
