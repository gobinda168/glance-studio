import AppKit
import GlanceCore
import WebKit

final class GlanceWebView: WKWebView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Right-click on selected text: Ask Claude what to do with it.
  override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
    super.willOpenMenu(menu, with: event)
    AskClaudeMenu.addItem(to: menu, for: self)
  }
}

/// The reply renderer: a local page (markdown-it, highlight.js, mermaid) driven through `window.glance`.
@MainActor
final class ContentWeb: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
  let view: WKWebView
  /// Called when the page finished rendering the most recent `render` call.
  var onRendered: (() -> Void)?
  /// The page loaded and wants the current state and settings.
  var onReady: (() -> Void)?
  /// A panel button: `playPause`, `play`, `pause`, `close`, `layout` or `settingsWindow`.
  var onAction: ((String) -> Void)?
  /// The panel's settings changed (theme, speed, text size, diagrams, follow along).
  var onPrefs: ((PanelPrefs) -> Void)?
  /// A voice was picked: a `NarrationVoice.preference` value.
  var onVoice: ((String) -> Void)?
  /// "Read new answers aloud" was switched.
  var onAuto: ((Bool) -> Void)?
  /// A file mentioned in a reply was clicked (a path, maybe with `:line:col`). Setting this tells the page to offer
  /// file links; nil (the default) keeps them off, as in the overlay.
  var onOpenFile: ((String) -> Void)? {
    didSet { call("glance.fileLinks(\(onOpenFile != nil))") }
  }
  /// The editor chat: a message to send (`context`: include the file and selection), and the composer's other actions
  /// (`chatOpen`, `chatStop`, `chatNew`).
  var onChatSend: ((_ text: String, _ context: Bool) -> Void)?
  var onChatAction: ((String) -> Void)?
  /// The picker chose one of the project's chat sessions.
  var onChatSwitch: ((String) -> Void)?
  /// The Summary view (Web/summary.js): open, generate, close, sessions, or pick with a session id.
  var onSummary: ((_ action: String, _ id: String?) -> Void)?
  /// The height the page's content needs to show without scrolling (the floating card fits itself to it).
  var onContentHeight: ((CGFloat) -> Void)?
  private var ready = false
  private var queued: [String] = []
  private var renders = 0

  init(webDirectory: URL) {
    let configuration = WKWebViewConfiguration()
    let controller = WKUserContentController()
    configuration.userContentController = controller
    view = GlanceWebView(frame: .zero, configuration: configuration)
    super.init()
    controller.add(WeakMessageHandler(self), name: "glance")
    view.navigationDelegate = self
    view.setValue(false, forKey: "drawsBackground")
    view.underPageBackgroundColor = .clear
    view.loadFileURL(webDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: webDirectory)
  }

  /// `asked`: the question the blocks answer (the orb assistant's), shown muted above them.
  func render(_ blocks: [Block], asked: String? = nil) {
    renders += 1
    let json = (try? JSONEncoder().encode(blocks)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    let question = asked.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
    call("glance.render(\(json)\(question.map { ", " + $0 } ?? ""))")
  }

  func narrating(_ on: Bool) { call("glance.narrating(\(on))") }
  func speaking(block: Int) { call("glance.speaking(\(block))") }
  func reveal(block: Int, milliseconds: Int) { call("glance.reveal(\(block), \(milliseconds))") }
  func revealAll(milliseconds: Int) { call("glance.revealAll(\(milliseconds))") }

  func state(_ status: PanelStatus, playing: Bool, hasReply: Bool, notice: String?) {
    var payload: [String: Any] = ["mode": status.mode, "header": status.header, "title": status.title,
                                  "subtitle": status.subtitle, "playing": playing, "hasReply": hasReply]
    if let notice { payload["notice"] = notice }
    call("glance.state(\(Self.json(payload)))")
  }

  /// `voices`: the choices for the panel's voice control, and which one is chosen.
  func prefs(_ prefs: PanelPrefs, auto: Bool, voices: [(id: String, name: String, title: String?)], selected: String) {
    var payload = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(prefs))) as? [String: Any] ?? [:]
    payload["auto"] = auto
    payload["voices"] = [
      "options": voices.map { voice -> [String: Any] in
        var option: [String: Any] = ["id": voice.id, "name": voice.name]
        if let title = voice.title { option["title"] = title }
        return option
      },
      "selected": selected,
    ]
    call("glance.prefs(\(Self.json(payload)))")
  }

  /// The voice level (RMS) for the orb, called about 30 times a second while speaking.
  func level(_ value: Float) {
    guard ready else { return }
    view.evaluateJavaScript("void glance.level(\(String(format: "%.4f", value)))", completionHandler: nil)
  }

  func appear() { call("glance.appear()") }

  func chatComposer(_ composer: ChatComposer?) {
    call("glance.chatComposer(\(composer.map { Self.json($0.payload) } ?? "null"))")
  }

  func chatThread(_ thread: ChatThread) { call("glance.chatThread(\(Self.json(thread.payload)))") }

  // The session summary (spec 2026-10-11-humanize-summaries-design.md).
  func summary(_ payload: [String: Any]) { call("glance.summary(\(Self.json(payload)))") }
  func summaryAvailable(_ on: Bool) { call("glance.summaryAvailable(\(on))") }
  func summarySessions(_ list: [[String: Any]]) { call("glance.summarySessions(\(Self.json(list)))") }
  /// "terminal": the terminal in front runs no Claude session (the idle stage says so); "default" otherwise.
  func emptyKind(_ kind: String) { call("glance.emptyKind('\(kind == "terminal" ? "terminal" : "default")')") }

  /// Glance Studio's pane layout (`PaneLayout.Mode`): shows the header's pin, set to it.
  func layout(_ mode: PaneLayout.Mode) { call("glance.layout('\(mode.rawValue)')") }

  /// Glance Studio's floating card: no header row, its buttons as a hover strip. Off: the side bar's full chrome.
  func chrome(floating: Bool) { call("glance.chrome('\(floating ? "float" : "full")')") }

  private static func json(_ object: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
  }

  private func call(_ script: String) {
    guard ready else { queued.append(script); return }
    // `void` keeps WebKit from trying to bridge the returned promise.
    view.evaluateJavaScript("void (\(script))") { _, error in
      if let error { NSLog("Glance: \(script.prefix(40))… failed: \(error)") }
    }
  }

  nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    MainActor.assumeIsolated {
      guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
      switch type {
      case "ready":
        ready = true
        let pending = queued
        queued.removeAll()
        pending.forEach(call)
        onReady?()
      case "rendered":
        if body["generation"] as? Int == renders { onRendered?() }
      case "copy":
        if let text = body["text"] as? String {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      case "action":
        if let name = body["name"] as? String { onAction?(name) }
      case "prefs":
        if let object = body["prefs"], let data = try? JSONSerialization.data(withJSONObject: object),
          let prefs = try? JSONDecoder().decode(PanelPrefs.self, from: data) {
          onPrefs?(prefs.clamped())
        }
      case "voice":
        if let id = body["id"] as? String { onVoice?(id) }
      case "auto":
        if let on = body["on"] as? Bool { onAuto?(on) }
      case "openFile":
        if let path = body["path"] as? String, path.count < 1024 { onOpenFile?(path) }
      case "open":
        if let string = body["url"] as? String, let url = URL(string: string), ["http", "https"].contains(url.scheme) {
          NSWorkspace.shared.open(url)
        }
      case "chatSend":
        if let text = body["text"] as? String, !text.isEmpty, text.count < 100_000 {
          onChatSend?(text, body["context"] as? Bool ?? false)
        }
      case "chatOpen", "chatStop", "chatNew":
        onChatAction?(type)
      case "contentHeight":
        if let value = (body["value"] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 {
          onContentHeight?(CGFloat(min(value, 100_000)))
        }
      case "chatSwitch":
        if let id = body["id"] as? String, id.count < 100 { onChatSwitch?(id) }
      case "summary":
        if let action = body["action"] as? String, ["open", "generate", "close", "sessions", "pick"].contains(action) {
          let id = (body["id"] as? String).flatMap { $0.count < 100 ? $0 : nil }
          onSummary?(action, id)
        }
      default:
        break
      }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
    // Only the bundled page itself may load; links open in the browser via the "open" message.
    decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
  }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) { self.target = target }
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(controller, didReceive: message)
  }
}
