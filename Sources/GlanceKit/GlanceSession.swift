import AppKit
import GlanceCore

/// The Glance engine: Claude's turns in; the rendered reply, narration and the orb's state out. Shared by the overlay
/// and Glance Studio. It doesn't know how the panel gets on screen: the host places `view` and says whether the
/// panel is visible.
@MainActor
public final class GlanceSession {
  /// Glance's settings: voices, keys, dictation, the editor, what runs. Studio's Settings tab shows them.
  public let settings = SettingsModel()
  /// Opens Settings, on a section when given: the host's Settings tab.
  public var onShowSettings: ((SettingsSection?) -> Void)?

  /// Whether the panel is on screen. A new reply is read aloud only when it is.
  public var isPanelVisible: () -> Bool = { true }
  /// Whether something besides the panel shows the voice level (the overlay's editor orb).
  public var isLevelListenerVisible: () -> Bool = { false }
  /// The voice level, about 30 times a second while speaking, then 0.
  public var onLevel: ((Float) -> Void)?
  /// The orb's state changed.
  public var onStatus: ((PanelStatus) -> Void)?
  /// A reply is on the page. `significant`: it has a diagram or at least 2 spoken paragraphs, so the panel should
  /// come up; short acknowledgements update it quietly.
  public var onReply: ((_ markdown: String, _ significant: Bool) -> Void)?
  /// The panel's close button.
  public var onCloseRequested: (() -> Void)?
  /// Play while the panel is hidden: the host shows it, and narration starts right after.
  public var onShowRequested: (() -> Void)?
  /// The header's pin was clicked: the host moves to the next `PaneLayout.Mode` and calls `showLayout`.
  public var onLayoutCycle: (() -> Void)?
  /// The panel's theme setting changed.
  public var onTheme: ((PanelPrefs.Theme) -> Void)?
  /// The height the panel's content needs to show without scrolling, in points: the floating card fits itself to it.
  public var onContentHeight: ((CGFloat) -> Void)?
  /// The reply on the page was read to its end, or shown without being read (a short `tell` folds back after it).
  public var onReplyRead: (() -> Void)?
  /// A file named in a reply was clicked. Setting it turns the panel's file links on.
  public var onOpenFile: ((String) -> Void)? {
    didSet { web.onOpenFile = onOpenFile }
  }

  /// The editor chat (Razor Code tabs): the composer sent a message (`withContext`: include the file and selection),
  /// asked to stop, to start a new conversation, or was focused (the host picks the transcript to show).
  public var onChatSend: ((_ text: String, _ withContext: Bool) -> Void)?
  public var onChatStop: (() -> Void)?
  public var onChatNew: (() -> Void)?
  public var onChatOpen: (() -> Void)?
  public var onChatSwitch: ((_ sessionID: String) -> Void)?
  /// The Summary view asked for something (`open`, `generate`, `close`, `sessions`, `pick` + session id).
  public var onSummary: ((_ action: String, _ id: String?) -> Void)?

  private let model = PanelModel()
  private let narrator = Narrator()
  private let web: ContentWeb
  private var pausedForDictation = false
  private let audioCache = AudioCache()
  private var provider: SpeechProvider?
  /// "Alice (ElevenLabs)", or nil when the Mac voice is the only voice.
  private var cloudName: String?
  private var kokoroName = ""
  private var usage: Usage?
  private var usageFetched: Date?
  private let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
  private var segments: [Segment] = []
  private var diagramAnchors: [Int: [Int]] = [:]
  private var narrateWhenRendered = false
  /// Whether the reply being rendered should be read aloud once it's on the page.
  private var autoNarrate = true
  /// The reply being rendered is a `tell` the orb channel already cleared to speak: it's read even while the panel is
  /// hidden or "Read new answers aloud" is off.
  private var narrateRegardless = false
  /// Glance Studio's floating card chrome is on.
  private var floatingChrome = false
  private var thinkingTimeout: DispatchWorkItem?
  private var panelPrefs = Prefs.panel
  private var levelTimer: Timer?

  /// The panel page, for the host to put in its window.
  public var view: NSView { web.view }
  public var theme: PanelPrefs.Theme { panelPrefs.theme }
  public var isSpeaking: Bool { narrator.isSpeaking }
  public var isPaused: Bool { narrator.isPaused }
  public var muted: Bool { model.muted }
  public var voiceName: String { model.voiceName }

  public init(webDirectory: URL) {
    web = ContentWeb(webDirectory: webDirectory)
    web.onRendered = { [weak self] in self?.rendered() }
    web.onReady = { [weak self] in
      guard let self else { return }
      self.pushPrefs()
      self.pushState()
      self.web.chrome(floating: self.floatingChrome)
    }
    web.onContentHeight = { [weak self] height in self?.onContentHeight?(height) }
    web.onAction = { [weak self] name in self?.panelAction(name) }
    web.onPrefs = { [weak self] prefs in self?.applyPanelPrefs(prefs) }
    web.onVoice = { [weak self] id in self?.pickVoice(id) }
    web.onAuto = { [weak self] on in self?.setMuted(!on) }
    web.onChatSend = { [weak self] text, context in self?.onChatSend?(text, context) }
    web.onChatSwitch = { [weak self] id in self?.onChatSwitch?(id) }
    web.onSummary = { [weak self] action, id in self?.onSummary?(action, id) }
    web.onChatAction = { [weak self] name in
      switch name {
      case "chatOpen": self?.onChatOpen?()
      case "chatStop": self?.onChatStop?()
      case "chatNew": self?.onChatNew?()
      default: break
      }
    }
    narrator.rate = Float(panelPrefs.speed)
    model.onChange = { [weak self] in self?.pushState() }

    // Replies are only drawn unless "Read new answers aloud" was switched on; play (⌥.) reads one on demand.
    model.muted = !defaults.bool(forKey: "readAloud")
    narrator.onVoiceChange = { [weak self] kind, failure in self?.voiceChanged(kind, failure) }
    narrator.onBilled = { [weak self] characters in self?.settings.addSessionCharacters(characters) }
    settings.onVoiceSettingsChanged = { [weak self] in self?.configureVoice() }
    // Another session's Settings changed the voice (Studio's tab, for the overlay's panel): read with it here too.
    NotificationCenter.default.addObserver(forName: SettingsModel.voiceDidChange, object: nil, queue: .main) {
      [weak self] notification in
      let changed = (notification.object as AnyObject?).map(ObjectIdentifier.init)
      MainActor.assumeIsolated {
        guard let self, changed != ObjectIdentifier(self.settings) else { return }
        self.settings.refreshVoice()
        self.configureVoice()
      }
    }
    configureVoice()
    narrator.onSegmentStart = { [weak self] segment, duration in self?.segmentStarted(segment, duration) }
    narrator.onFinish = { [weak self] in self?.narrationFinished() }
  }

  // MARK: - Claude Code turns

  /// Claude Code is working in `cwd`: the header shows its folder name.
  public func setProject(cwd: String) {
    model.project = URL(fileURLWithPath: cwd).lastPathComponent
  }

  /// A prompt was sent: the orb thinks until the reply arrives (or for 10 minutes).
  public func thinking() {
    stopNarration()
    model.state = .thinking
    armThinkingTimeout()
  }

  /// The turn ended without a reply Glance can show.
  public func idle() {
    model.state = .idle
  }

  /// Nothing to show for this folder: the page goes back to waiting for Claude.
  public func clear() {
    thinkingTimeout?.cancel()
    stopNarration()
    segments = []
    diagramAnchors = [:]
    narrateWhenRendered = false
    model.hasReply = false
    model.state = .idle
    web.render([])
  }

  /// Shows the reply in a transcript. The Stop hook can fire a moment before the last entry is flushed, so retry
  /// briefly. With narrate false it's shown without being read aloud (a reply from a folder that just got focus).
  public func loadReply(from path: String, narrate: Bool = true) async {
    for attempt in 0..<4 {
      if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
      let reply = await Task.detached(priority: .userInitiated) { Self.readReply(path) }.value
      if let reply {
        show(reply, narrate: narrate)
        return
      }
    }
    if model.state == .thinking { model.state = .idle }
  }

  /// Reads `markdown` aloud in the pane, the way a reply is read (the PR page's Read aloud): shown, then narrated in
  /// the chosen voice. Opens the pane when it's closed.
  public func readAloud(_ markdown: String) {
    if !isPanelVisible() { onShowRequested?() }
    show(markdown, narrate: true)
  }

  /// `tell` from the orb channel: shows `markdown` the way a reply is shown, opening the pane when it's closed, and
  /// reads it aloud when `narrate` (the channel's quiet rules already checked; the panel's own switch doesn't apply).
  /// `asked`: the question it answers (the orb assistant's), shown muted above it.
  public func tell(_ markdown: String, narrate: Bool, asked: String? = nil) {
    if !isPanelVisible() { onShowRequested?() }
    show(markdown, narrate: narrate, regardless: narrate, asked: asked)
  }

  /// Reads only the transcript's tail: long sessions grow to many megabytes, the last turn sits at the end.
  nonisolated static func readReply(_ path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let window: UInt64 = 4 << 20
    try? handle.seek(toOffset: size > window ? size - window : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    var text = String(decoding: data, as: UTF8.self)
    if size > window, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
    return Transcript.lastReply(jsonl: text)
  }

  private func show(_ reply: String, narrate: Bool = true, regardless: Bool = false, asked: String? = nil) {
    thinkingTimeout?.cancel()
    stopNarration()
    narrator.budget.newReply()
    model.voiceNotice = nil
    model.voiceName = chosenVoiceName
    refreshUsage()
    let blocks = Blocks.split(reply)
    segments = blocks.enumerated().compactMap { index, block in
      Speech.text(for: block).map { Segment(block: index, text: $0) }
    }
    diagramAnchors = Narration.diagramAnchors(blocks: blocks, spokenBlocks: segments.map(\.block))
    model.hasReply = true
    model.state = .reading
    narrateWhenRendered = true
    autoNarrate = narrate
    narrateRegardless = regardless
    web.render(blocks, asked: asked)
    onReply?(reply, blocks.contains(where: { $0.kind == .mermaid }) || segments.count >= 2)
  }

  private func rendered() {
    guard narrateWhenRendered else { return }
    narrateWhenRendered = false
    if autoNarrate, narrateRegardless || (isPanelVisible() && !model.muted), !segments.isEmpty {
      startNarration()
    } else {
      if model.state == .reading { model.state = .idle }
      web.revealAll(milliseconds: 1800)
      onReplyRead?()
    }
  }

  // MARK: - Narration

  /// The voice pauses while you dictate so the mic doesn't hear it, and picks up again afterwards.
  public func dictationHold(_ holding: Bool) {
    if holding {
      guard narrator.isSpeaking, !narrator.isPaused else { return }
      narrator.togglePause()
      model.state = .paused
      pausedForDictation = true
    } else if pausedForDictation {
      pausedForDictation = false
      guard narrator.isSpeaking, narrator.isPaused else { return }
      narrator.togglePause()
      model.state = .speaking
      startLevelPump()
    }
  }

  private func startNarration() {
    guard !segments.isEmpty else { web.revealAll(milliseconds: 1800); return }
    web.narrating(true)
    for diagram in diagramAnchors[-1] ?? [] { web.reveal(block: diagram, milliseconds: 1800) }
    narrator.speak(segments)
  }

  private func segmentStarted(_ segment: Segment, _ duration: TimeInterval) {
    model.state = narrator.isPaused ? .paused : .speaking
    startLevelPump()
    web.speaking(block: segment.block)
    for diagram in diagramAnchors[segment.block] ?? [] {
      web.reveal(block: diagram, milliseconds: max(1400, Int(duration * 900)))
    }
  }

  private func narrationFinished() {
    model.state = .idle
    web.narrating(false)
    web.revealAll(milliseconds: 1200)
    onReplyRead?()
  }

  /// Stops the voice; the reply stays on the page.
  public func stop() {
    stopNarration()
  }

  private func stopNarration() {
    narrator.stop()
    web.narrating(false)
    if model.state == .speaking || model.state == .paused || model.state == .reading { model.state = .idle }
  }

  public func playPause() {
    if narrator.isSpeaking {
      narrator.togglePause()
      model.state = narrator.isPaused ? .paused : .speaking
      if !narrator.isPaused { startLevelPump() }
    } else if model.hasReply {
      if !isPanelVisible() { onShowRequested?() }
      startNarration()
    }
  }

  public func toggleMute() { setMuted(!model.muted) }

  /// Muted is the panel's "Read new answers aloud" switched off.
  private func setMuted(_ muted: Bool) {
    model.muted = muted
    defaults.set(!muted, forKey: "readAloud")
    if muted, narrator.isSpeaking {
      stopNarration()
      web.revealAll(milliseconds: 1200)
    }
    pushPrefs()
  }

  /// Shows the header's pin, set to `mode`. Only Glance Studio has layouts.
  public func showLayout(_ mode: PaneLayout.Mode) {
    web.layout(mode)
  }

  /// Glance Studio's floating card: the header row goes and its buttons become a hover strip at the card's top right.
  public func setFloatingChrome(_ on: Bool) {
    guard on != floatingChrome else { return }
    floatingChrome = on
    web.chrome(floating: on)
  }

  /// The panel is about to come on screen: the page plays its entrance.
  public func appear() {
    web.appear()
  }

  /// Shows the composer (nil hides it and leaves chat mode).
  public func chatComposer(_ composer: ChatComposer?) { web.chatComposer(composer) }

  /// The conversation chat mode shows.
  public func chatThread(_ thread: ChatThread) { web.chatThread(thread) }

  public func summary(_ payload: [String: Any]) { web.summary(payload) }
  public func summaryAvailable(_ on: Bool) { web.summaryAvailable(on) }
  public func summarySessions(_ list: [[String: Any]]) { web.summarySessions(list) }
  public func emptyKind(_ kind: String) { web.emptyKind(kind) }

  // MARK: - The page

  private func pushState() {
    let status = PanelStatus(state: model.state, hasReply: model.hasReply)
    web.state(status, playing: model.state == .speaking, hasReply: model.hasReply, notice: model.voiceNotice)
    onStatus?(status)
  }

  private func pushPrefs() {
    let choice = Prefs.narrationVoice
    let cloud: ProviderID = if case .cloud(let id) = choice { id }
      else { !SpeechProviders.hasKey(.elevenLabs) && SpeechProviders.hasKey(.miniMax) ? .miniMax : .elevenLabs }
    let cloudTitle = !SpeechProviders.hasKey(cloud) ? "Add a \(cloud.displayName) key in Glance Settings" : nil
    web.prefs(panelPrefs, auto: !model.muted,
              voices: [("kokoro", "Glance Voice", "Runs on this Mac"), (cloud.rawValue, cloud.displayName, cloudTitle),
                       ("system", "Mac", "The macOS system voice")],
              selected: choice.preference)
  }

  private func panelAction(_ name: String) {
    switch name {
    case "playPause": playPause()
    case "play": if !narrator.isSpeaking || narrator.isPaused { playPause() }
    case "pause": if narrator.isSpeaking, !narrator.isPaused { playPause() }
    case "close": onCloseRequested?()
    case "layout": onLayoutCycle?()
    case "settingsWindow": showSettings(.voice)
    default: break
    }
  }

  /// Shows Settings (the host's tab), on `section` when given.
  public func showSettings(_ section: SettingsSection? = nil) {
    onShowSettings?(section)
  }

  private func applyPanelPrefs(_ prefs: PanelPrefs) {
    panelPrefs = prefs
    Prefs.panel = prefs
    narrator.rate = Float(prefs.speed)
    onTheme?(prefs.theme)
  }

  /// A cloud voice without its key opens Settings instead, and the panel goes back to the voice in use.
  private func pickVoice(_ preference: String) {
    if let id = ProviderID(rawValue: preference), !SpeechProviders.hasKey(id) {
      showSettings(.voice)
      pushPrefs()
      return
    }
    Prefs.voiceProviderPreference = preference
    settings.refreshVoice()
    configureVoice()
  }

  /// Feeds the voice level to the panel (and the host's level listener) while the voice is on.
  private func startLevelPump() {
    guard levelTimer == nil else { return }
    levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.model.state == .speaking, self.isPanelVisible() || self.isLevelListenerVisible() else {
          self?.levelTimer?.invalidate()
          self?.levelTimer = nil
          self?.web.level(0)
          self?.onLevel?(0)
          return
        }
        let level = self.narrator.level.value
        if self.isPanelVisible() { self.web.level(level) }
        self.onLevel?(level)
      }
    }
  }

  private func armThinkingTimeout() {
    thinkingTimeout?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { if self?.model.state == .thinking { self?.model.state = .idle } }
    }
    thinkingTimeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: work)
  }

  // MARK: - Voice

  /// Rebuilds the cloud voice from Settings: provider, its key, voice and model. Without one, the Mac voice reads.
  /// A change mid-reply applies from the next paragraph fetched.
  private func configureVoice() {
    let chosen = narrator.useChosenVoice(cache: audioCache)
    kokoroName = "\(Prefs.kokoroVoice.name) (Glance Voice)"
    provider = chosen?.provider
    cloudName = chosen?.name
    usage = nil
    usageFetched = nil
    model.voiceNotice = nil
    model.voiceName = chosenVoiceName
    refreshUsage()
    pushPrefs()
  }

  private var macVoiceName: String { "\(narrator.system.voice?.name ?? "none") (Mac)" }

  /// The name of the voice that reads when nothing fails.
  private var chosenVoiceName: String { cloudName ?? (narrator.kokoro != nil ? kokoroName : macVoiceName) }

  /// Fetches what's left of the quota when there's a cloud voice and the last fetch is older than 5 minutes.
  /// Never blocks narration: until it returns, the budget treats the remaining characters as unknown.
  private func refreshUsage() {
    guard let provider, usageFetched.map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
    usageFetched = Date()
    Task {
      let usage = await provider.usage()
      guard provider.id == self.provider?.id else { return }
      self.usage = usage
      narrator.budget.setRemaining(usage?.remaining)
    }
  }

  private func voiceChanged(_ tier: VoiceTier, _ failure: TTSFailure?) {
    let reason = failure?.message(provider: provider?.id.displayName ?? "Cloud voice", resetsAt: usage?.resetsAt)
    switch tier {
    case .cloud:
      model.voiceNotice = nil
      model.voiceName = cloudName ?? macVoiceName
    case .kokoro:
      model.voiceName = kokoroName
      model.voiceNotice = reason.map { "Glance Voice · " + $0 }
    case .mac:
      model.voiceName = macVoiceName
      model.voiceNotice = reason.map { "Mac voice · " + $0 }
    }
  }
}
