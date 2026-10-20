import AppKit
import Carbon
import GlanceCore
import GlanceKit

/// The overlay: docks the Glance panel over the terminal in front (an orb with a popover over code editors), feeds
/// Claude Code's hook events to its own session, and owns the menu-bar item and hot keys. A host (Glance Studio, or
/// the Glance executable) starts and stops it.
@MainActor
public final class OverlayController: NSObject {
  /// What the overlay needs from the app hosting it.
  public struct Host {
    /// Opens Settings, on a section when given (the panel's voice link opens Voice).
    public var showSettings: (SettingsSection?) -> Void
    public var checkForUpdates: () -> Void
    public var updateItem: () -> UpdateMenuItem
    /// Is another surface of this product in front, so ⌥Space and ⌥. belong to it?
    public var isStudioFront: () -> Bool
    public var toggleStudioPane: () -> Void
    public var playPauseStudio: () -> Void
    /// A hook event for this folder belongs to Studio's own terminals.
    public var ownsFolder: (String) -> Bool
    /// Whether the app's own windows (Settings) count as a terminal being in front.
    public var treatsOwnAppAsFront: () -> Bool
    /// The latest reply and working folder, for dictation.
    public var onReply: (String) -> Void
    public var onCwd: (String) -> Void

    public init(showSettings: @escaping (SettingsSection?) -> Void, checkForUpdates: @escaping () -> Void,
                updateItem: @escaping () -> UpdateMenuItem, isStudioFront: @escaping () -> Bool,
                toggleStudioPane: @escaping () -> Void, playPauseStudio: @escaping () -> Void,
                ownsFolder: @escaping (String) -> Bool, treatsOwnAppAsFront: @escaping () -> Bool,
                onReply: @escaping (String) -> Void, onCwd: @escaping (String) -> Void) {
      self.showSettings = showSettings
      self.checkForUpdates = checkForUpdates
      self.updateItem = updateItem
      self.isStudioFront = isStudioFront
      self.toggleStudioPane = toggleStudioPane
      self.playPauseStudio = playPauseStudio
      self.ownsFolder = ownsFolder
      self.treatsOwnAppAsFront = treatsOwnAppAsFront
      self.onReply = onReply
      self.onCwd = onCwd
    }
  }

  private let host: Host
  /// The overlay's own session (its panel); made by the first `start()`, kept across stop and start.
  public private(set) var session: GlanceSession?
  private let docker = Docker()
  private var panel: GlancePanel!
  /// Over code editors: the orb that opens the panel as a popover.
  private var orb: OrbWindow!
  private var statusItem: NSStatusItem?
  private var running = false

  /// A reply is on screen and hasn't been dismissed.
  private var wantsVisible = false
  /// Shown with ⌥Space while another app was frontmost; cleared on the next app switch.
  private var forcedByHotkey = false
  /// Closed since the last reply: "Show Glance over terminals" leaves it hidden until the next one.
  private var dismissed = false

  public init(host: Host) {
    self.host = host
    super.init()
  }

  // MARK: - Lifecycle

  public func start() {
    guard !running else { return }
    running = true
    if session == nil { build() }
    docker.includesEditors = Prefs.editorsEnabled
    docker.start()
    registerHotKeys()
    buildStatusItem()
  }

  /// Switches everything off: panel and orb hidden, narration stopped, no docking, hook events ignored, no hot keys,
  /// no menu-bar item. `start()` brings it back.
  public func stop() {
    guard running else { return }
    running = false
    session?.stop()
    wantsVisible = false
    forcedByHotkey = false
    dismissed = false
    panel?.orderOut(nil)
    orb?.orderOut(nil)
    docker.stop()
    HotKeys.shared.unregisterAll()
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }

  /// The one-time construction: the session, panel and orb, and what they report back.
  private func build() {
    let session = GlanceSession(webDirectory: Resources.web)
    self.session = session
    panel = GlancePanel(content: session.view)
    panel.setTheme(session.theme)
    orb = OrbWindow(webDirectory: Resources.web)
    orb.onClick = { [weak self] in self?.orbClicked() }
    orb.onDrag = { [weak self] center in self?.orbMoved(to: center, dropped: false) }
    orb.onDrop = { [weak self] center in self?.orbMoved(to: center, dropped: true) }

    session.isPanelVisible = { [weak self] in self?.panel.isVisible ?? false }
    session.isLevelListenerVisible = { [weak self] in self?.orb.isVisible ?? false }
    session.onLevel = { [weak self] level in self?.orb.level(level) }
    session.onStatus = { [weak self] status in self?.orb.setMode(status.mode) }
    session.onReply = { [weak self] reply, significant in
      guard let self else { return }
      self.host.onReply(reply)
      if significant {
        self.wantsVisible = true
        self.dismissed = false
      }
      self.updateVisibility()
    }
    session.onCloseRequested = { [weak self] in self?.hide() }
    session.onShowSettings = { [weak self] section in self?.host.showSettings(section) }
    session.onShowRequested = { [weak self] in
      guard let self else { return }
      self.wantsVisible = true
      self.dismissed = false
      self.forcedByHotkey = !self.docker.isTerminalFront
      self.updateVisibility()
    }
    session.onTheme = { [weak self] theme in self?.panel.setTheme(theme) }

    docker.ownAppCountsAsFront = { [weak self] in self?.host.treatsOwnAppAsFront() ?? true }
    docker.onFrame = { [weak self] _ in self?.followWindow() }
    docker.onTerminalFront = { [weak self] _ in
      self?.forcedByHotkey = false
      self?.updateVisibility()
    }
  }

  private func registerHotKeys() {
    HotKeys.shared.register(keyCode: kVK_Space, modifiers: optionKey) { [weak self] in
      guard let self else { return }
      if self.host.isStudioFront() { self.host.toggleStudioPane() } else { self.toggle() }
    }
    HotKeys.shared.register(keyCode: kVK_ANSI_Period, modifiers: optionKey) { [weak self] in
      guard let self else { return }
      if self.host.isStudioFront() { self.host.playPauseStudio() } else { self.session?.playPause() }
    }
  }

  // MARK: - Host calls

  /// Reopened: the panel over the terminal in front, or placed as ⌥Space places it.
  public func showPanel() {
    wantsVisible = true
    forcedByHotkey = !docker.isTerminalFront
    updateVisibility()
  }

  /// The docked terminal's window, so dictation's pill sits above its input; nil unless a terminal is in front.
  public var dictationAnchor: NSRect? { docker.isTerminalFront ? docker.terminalWindowFrame() : nil }

  /// "Show Glance over code editors" changed in Settings.
  public func editorsSettingChanged() {
    docker.includesEditors = Prefs.editorsEnabled
    docker.refresh()
    updateVisibility()
  }

  /// "Show Glance over terminals" changed in Settings.
  public func terminalsSettingChanged() {
    dismissed = false
    updateVisibility()
  }

  // MARK: - Claude Code events

  /// A Claude Code hook event from the host's `EventServer`; ignored while the overlay is off.
  public func receive(_ event: HookEvent) {
    guard running else { return }
    if let cwd = event.cwd {
      guard !host.ownsFolder(cwd) else { return } // Studio's terminals narrate their own sessions
      session?.setProject(cwd: cwd)
      host.onCwd(cwd)
    }
    switch event.name {
    case "UserPromptSubmit":
      session?.thinking()
    case "Stop":
      guard event.isTranscriptPathAllowed(home: NSHomeDirectory()), let path = event.transcriptPath else {
        session?.idle()
        return
      }
      Task { await session?.loadReply(from: path) }
    default:
      break
    }
  }

  // MARK: - Visibility

  private func toggle() {
    if panel.isVisible {
      hide()
    } else {
      wantsVisible = true
      dismissed = false
      forcedByHotkey = !docker.isTerminalFront
      updateVisibility()
    }
  }

  private func hide() {
    wantsVisible = false
    dismissed = true
    session?.stop()
    updateVisibility()
  }

  private func updateVisibility() {
    guard running else { return }
    let editor = editorWindow
    if let editor, docker.isTerminalFront {
      orb.appear(at: orbCenter(in: editor))
    } else {
      orb.disappear()
    }
    let shows = OverlayVisibility.showsPanel(
      wantsVisible: wantsVisible, terminalFront: docker.isTerminalFront, forcedByHotkey: forcedByHotkey,
      overEditor: docker.isEditor, alwaysOverTerminals: Prefs.terminalsAlwaysShown, dismissed: dismissed)
    if shows {
      if !panel.isVisible { session?.appear() }
      panel.fadeIn(to: panelFrame(), from: editor == nil ? CGVector(dx: 28, dy: 0) : CGVector(dx: 0, dy: -14))
    } else {
      panel.fadeOut(to: editor == nil ? CGVector(dx: 18, dy: 0) : CGVector(dx: 0, dy: -10))
    }
    orb.setOpen(wantsVisible)
  }

  // MARK: - Code editors: the orb and its popover

  /// The front window of the code editor Glance is attached to; nil for a terminal (or without Accessibility).
  private var editorWindow: NSRect? {
    docker.isEditor ? docker.terminalWindowFrame() : nil
  }

  private func orbCenter(in window: NSRect) -> CGPoint {
    DockGeometry.orbCenter(window: window, offset: Prefs.orbOffset)
  }

  /// Docked over the right of a terminal; above the orb in an editor.
  private func panelFrame() -> NSRect {
    guard let window = editorWindow else { return docker.frame() }
    return DockGeometry.popoverFrame(window: window, orbCenter: orbCenter(in: window))
  }

  /// The terminal's or editor's window moved or resized: bring the orb and the panel along.
  private func followWindow() {
    guard running else { return }
    if orb.isVisible, let window = editorWindow { orb.place(center: orbCenter(in: window)) }
    if panel.isVisible { panel.setFrame(panelFrame(), display: true) }
  }

  /// Opens or closes the popover. Closing it leaves the voice reading; the orb keeps pulsing with it.
  private func orbClicked() {
    wantsVisible = !panel.isVisible
    forcedByHotkey = false
    updateVisibility()
  }

  /// The popover follows the orb as it's dragged; on drop the orb settles inside the window and keeps that place.
  private func orbMoved(to center: CGPoint, dropped: Bool) {
    guard let window = editorWindow else { return }
    if dropped {
      let offset = DockGeometry.orbOffset(center: center, window: window)
      Prefs.orbOffset = offset
      orb.place(center: DockGeometry.orbCenter(window: window, offset: offset), animated: true)
    }
    if panel.isVisible {
      let anchor = dropped ? orbCenter(in: window) : center
      panel.setFrame(DockGeometry.popoverFrame(window: window, orbCenter: anchor), display: true)
    }
  }

  // MARK: - Menu bar

  private func buildStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    statusItem = item
    refreshStatusIcon()
    let menu = NSMenu()
    menu.delegate = self
    item.menu = menu
  }

  /// The icon wears a badge while an update is waiting.
  public func refreshStatusIcon() {
    let badge = host.updateItem().showsBadge
    statusItem?.button?.image = NSImage(systemSymbolName: badge ? "arrow.down.circle.fill" : "waveform.circle",
                                        accessibilityDescription: badge ? "Glance, update available" : "Glance")
  }

  @objc private func menuToggle() { toggle() }
  @objc private func menuPlayPause() { session?.playPause() }
  @objc private func menuMute() { session?.toggleMute() }
  @objc private func menuDictation() { session?.settings.setDictationEnabled(!Prefs.dictationEnabled) }
  @objc private func menuSettings() { host.showSettings(nil) }
  @objc private func menuCheckForUpdates() { host.checkForUpdates() }
  @objc private func menuAccessibility() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
  }
}

extension OverlayController: NSMenuDelegate {
  public func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    @discardableResult
    func item(_ title: String, _ action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.keyEquivalentModifierMask = modifiers
      item.target = self
      menu.addItem(item)
      return item
    }
    item(panel.isVisible ? "Hide Panel" : "Show Panel", #selector(menuToggle), key: " ", modifiers: .option)
    item(session?.isSpeaking == true && session?.isPaused == false ? "Pause Voice" : "Play Voice",
         #selector(menuPlayPause), key: ".", modifiers: .option)
    item("Read New Answers Aloud", #selector(menuMute)).state = session?.muted == true ? .off : .on
    item("Dictation (hold fn)", #selector(menuDictation)).state = Prefs.dictationEnabled ? .on : .off
    menu.addItem(.separator())
    let voiceName = session?.voiceName ?? ""
    item("Voice: \(voiceName.isEmpty ? "none" : voiceName)", nil).isEnabled = false
    if !docker.isTrusted {
      item("Allow Accessibility to dock to your terminal…", #selector(menuAccessibility))
    }
    menu.addItem(.separator())
    item("Glance \(AppVersion.current.short)", nil).isEnabled = false
    let update = host.updateItem()
    item(update.title, update.isEnabled ? #selector(menuCheckForUpdates) : nil).isEnabled = update.isEnabled
    item("Settings…", #selector(menuSettings), key: ",", modifiers: .command)
    menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
  }
}
