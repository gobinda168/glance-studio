import AppKit
import AVFoundation
import GlanceCore
import Observation

@MainActor
@Observable
public final class SettingsModel {
  public let elevenLabsKey = KeyFieldModel(provider: .elevenLabs)
  public let miniMaxKey = KeyFieldModel(provider: .miniMax)
  public private(set) var dictationEnabled = Prefs.dictationEnabled
  public private(set) var terminalsAlwaysShown = Prefs.terminalsAlwaysShown
  public private(set) var editorsEnabled = Prefs.editorsEnabled
  public private(set) var surfaces = Prefs.surfaces
  public private(set) var editorKind = Prefs.editorKind
  public private(set) var formatOnSave = Prefs.formatOnSave
  public private(set) var suggestions = Prefs.suggestions
  public private(set) var showHomeAtLaunch = Prefs.showHomeAtLaunch
  public private(set) var openClaudeAtLaunch = Prefs.openClaudeAtLaunch
  public private(set) var claudeLaunchFolder = Prefs.claudeLaunchFolder
  public private(set) var summaryMode = Prefs.summaryMode
  public private(set) var responseStyle = Prefs.responseStyle
  public private(set) var pullRequestsAutoClaude = Prefs.pullRequestsAutoClaude
  public private(set) var micStatus = AVAuthorizationStatus.notDetermined
  public private(set) var accessibilityGranted = false
  public private(set) var fnUsage = FnUsage.unknown
  @ObservationIgnored public var onDictationToggle: ((Bool) -> Void)?
  @ObservationIgnored public var onTerminalsToggle: ((Bool) -> Void)?
  @ObservationIgnored public var onEditorsToggle: ((Bool) -> Void)?
  /// The built-in terminal or overlay switch changed; the host applies it (and may put it back).
  @ObservationIgnored public var onSurfacesToggle: (() -> Void)?
  /// Characters billed by cloud voices since Glance started, for the pay-as-you-go usage line.
  public private(set) var sessionCharacters = 0
  /// Provider, key, voice, model or Mac voice changed: the app rebuilds its voice.
  @ObservationIgnored var onVoiceSettingsChanged: (() -> Void)?
  /// Posted with the model as its object when Settings changes the voice, so every session (Studio's, the overlay's)
  /// reads with the new one.
  public static let voiceDidChange = Notification.Name("dev.glance.settings.voiceDidChange")
  /// Posted when a terminal suggestions switch changes, so every connected shell gets the new `config`.
  public static let suggestionsDidChange = Notification.Name("dev.glance.settings.suggestionsDidChange")
  /// The summary mode changed: Always's pending updates stop.
  public static let summaryModeDidChange = Notification.Name("dev.glance.settings.summaryModeDidChange")

  func addSessionCharacters(_ characters: Int) {
    sessionCharacters += characters
  }

  /// Re-reads everything that can change outside Glance (Keychain, permissions, keyboard settings).
  public func refresh() {
    refreshVoice()
    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    accessibilityGranted = AXIsProcessTrusted()
    fnUsage = Prefs.fnUsage
    dictationEnabled = Prefs.dictationEnabled
    surfaces = Prefs.surfaces
    showHomeAtLaunch = Prefs.showHomeAtLaunch // the Home page has the same switch
  }


  public enum LoadState: Equatable { case idle, loading, failed(String) }

  public static let previewSentence = "Hi, I am the voice that will explain Claude replies to you."

  public private(set) var narration: NarrationVoice = Prefs.narrationVoice
  public private(set) var kokoroVoice = Prefs.kokoroVoice
  /// The cloud provider when one is chosen.
  public var voiceProvider: ProviderID? {
    if case .cloud(let id) = narration { id } else { nil }
  }
  public private(set) var voices: [VoiceOption] = []
  public private(set) var voicesState = LoadState.idle
  public private(set) var previewState = LoadState.idle
  public private(set) var selectedVoice = ProviderID.elevenLabs.defaultVoice
  public private(set) var selectedModel = ProviderID.elevenLabs.defaultModel
  public private(set) var usageText: String?
  public private(set) var macVoiceID: String?
  /// A voice sample or preview is playing: Settings' Voice preview animates its orb meanwhile.
  public private(set) var samplePlaying = false
  @ObservationIgnored private let samples = SamplePlayer()

  public init() {
    elevenLabsKey.onChange = { [weak self] in self?.voiceSettingsChanged() }
    miniMaxKey.onChange = { [weak self] in self?.voiceSettingsChanged() }
    samples.onPlayingChange = { [weak self] playing in self?.samplePlaying = playing }
  }

  /// Re-reads the choice, keys, voices, model and Mac voice, then reloads the provider's voices and usage.
  public func refreshVoice() {
    elevenLabsKey.refresh()
    miniMaxKey.refresh()
    narration = Prefs.narrationVoice
    kokoroVoice = Prefs.kokoroVoice
    macVoiceID = Prefs.macVoice ?? MacVoices.best(preferred: nil)?.identifier
    switch narration {
    case .cloud(let id):
      selectedVoice = Prefs.voice(for: id)
      selectedModel = Prefs.model(for: id)
      loadVoices(id)
    case .kokoro:
      voices = KokoroVoices.all
      voicesState = .idle
      usageText = nil
      selectedVoice = kokoroVoice
    case .mac:
      voices = []
      voicesState = .idle
      usageText = nil
    }
  }

  /// `preference` is a `NarrationVoice.preference` value from the segmented control.
  public func setNarration(_ preference: String) {
    Prefs.voiceProviderPreference = preference
    samples.stop()
    previewState = .idle
    voiceSettingsChanged()
  }

  public func selectVoice(_ voice: VoiceOption) {
    switch narration {
    case .cloud(let id): Prefs.setVoice(voice, for: id)
    case .kokoro:
      Prefs.kokoroVoice = voice
      kokoroVoice = voice
    case .mac: return
    }
    selectedVoice = voice
    announceVoiceChange()
  }

  /// The FALLBACK menu under a cloud voice.
  public func selectKokoroFallback(_ id: String) {
    let voice = KokoroVoices.option(id: id)
    Prefs.kokoroVoice = voice
    kokoroVoice = voice
    announceVoiceChange()
  }

  public func selectModel(_ model: String) {
    guard let id = voiceProvider else { return }
    Prefs.setModel(model, for: id)
    selectedModel = model
    announceVoiceChange()
  }

  public func selectMacVoice(_ identifier: String) {
    Prefs.macVoice = identifier
    macVoiceID = identifier
    announceVoiceChange()
  }

  /// ▶ on a row: Kokoro speaks locally; a cloud voice plays its free hosted sample when there is one, otherwise a
  /// short synthesized preview.
  public func playSample(_ voice: VoiceOption) {
    if narration == .kokoro {
      previewKokoro(voice)
    } else if let url = voice.sampleURL {
      samples.play(url: url)
    } else {
      preview(voice: voice)
    }
  }

  /// Kokoro reads the preview sentence on this Mac. The first preview also loads the model.
  public func previewKokoro(_ voice: VoiceOption) {
    samples.stop()
    previewState = .loading
    Task {
      do {
        samples.play(wav: try await KokoroVoice.shared.wav(for: Self.previewSentence, voice: voice.id))
        previewState = .idle
      } catch {
        previewState = .failed((error as? TTSFailure)?.message(provider: "Glance Voice") ?? error.localizedDescription)
      }
    }
  }

  /// Preview button: the chosen voice and model on a fixed sentence (about 60 characters).
  public func preview() {
    preview(voice: selectedVoice)
  }

  public func previewMacVoice() {
    samples.speak(Self.previewSentence, voice: macVoiceID)
  }

  private func voiceSettingsChanged() {
    refreshVoice()
    announceVoiceChange()
  }

  private func announceVoiceChange() {
    onVoiceSettingsChanged?()
    NotificationCenter.default.post(name: Self.voiceDidChange, object: self)
  }

  private func preview(voice: VoiceOption) {
    guard let id = voiceProvider, let key = SpeechProviders.key(for: id) else { return }
    previewState = .loading
    let model = selectedModel
    Task {
      do {
        let audio = try await SpeechProviders.make(id, key: key)
          .synthesize(Self.previewSentence, voice: voice.id, model: model, previous: nil, next: nil)
        addSessionCharacters(audio.charactersBilled)
        samples.play(audio: audio)
        previewState = .idle
        loadUsage(id)
      } catch {
        previewState = .failed((error as? TTSFailure)?.message(provider: id.displayName) ?? error.localizedDescription)
      }
    }
  }

  private func loadVoices(_ id: ProviderID) {
    guard let key = SpeechProviders.key(for: id) else {
      voices = [Prefs.voice(for: id)]
      voicesState = .failed("Add your \(id.displayName) key to load its voices.")
      usageText = nil
      return
    }
    voicesState = .loading
    let provider = SpeechProviders.make(id, key: key)
    Task {
      do {
        let list = try await provider.voices()
        guard voiceProvider == id else { return }
        voices = list
        voicesState = .idle
      } catch {
        guard voiceProvider == id else { return }
        // Keep the saved voice selectable; say why the list is missing.
        voices = [Prefs.voice(for: id)]
        voicesState = .failed((error as? TTSFailure)?.message(provider: id.displayName) ?? error.localizedDescription)
      }
    }
    loadUsage(id)
  }

  private func loadUsage(_ id: ProviderID) {
    guard let key = SpeechProviders.key(for: id) else { return }
    let provider = SpeechProviders.make(id, key: key)
    Task {
      let usage = await provider.usage()
      guard voiceProvider == id else { return }
      usageText = UsageLine.text(usage, sessionCharacters: sessionCharacters)
    }
  }

  public func setEditorKind(_ kind: EditorKind) {
    editorKind = kind
    Prefs.editorKind = kind
  }

  public func setFormatOnSave(_ on: Bool) {
    formatOnSave = on
    Prefs.formatOnSave = on
  }

  public func setSuggestion(_ feature: SuggestionFeature, _ on: Bool) {
    suggestions.set(feature, on)
    Prefs.suggestions = suggestions
    NotificationCenter.default.post(name: Self.suggestionsDidChange, object: self)
  }

  public func setRecordHistory(_ on: Bool) {
    suggestions.recordHistory = on
    Prefs.suggestions = suggestions
    NotificationCenter.default.post(name: Self.suggestionsDidChange, object: self)
  }

  public func setShowHomeAtLaunch(_ on: Bool) {
    showHomeAtLaunch = on
    Prefs.showHomeAtLaunch = on
  }

  public func setOpenClaudeAtLaunch(_ on: Bool) {
    openClaudeAtLaunch = on
    Prefs.openClaudeAtLaunch = on
  }

  /// nil goes back to the home folder.
  public func setClaudeLaunchFolder(_ folder: String?) {
    claudeLaunchFolder = folder
    Prefs.claudeLaunchFolder = folder
  }

  public func setSummaryMode(_ mode: SummaryMode) {
    summaryMode = mode
    Prefs.summaryMode = mode
    NotificationCenter.default.post(name: Self.summaryModeDidChange, object: self)
  }

  /// New Claude sessions pick it up; running ones keep the style they started with.
  public func setResponseStyle(_ style: ResponseStyle) {
    responseStyle = style
    Prefs.responseStyle = style
  }

  public func setPullRequestsAutoClaude(_ on: Bool) {
    pullRequestsAutoClaude = on
    Prefs.pullRequestsAutoClaude = on
  }

  public func setTerminalsAlwaysShown(_ shown: Bool) {
    terminalsAlwaysShown = shown
    Prefs.terminalsAlwaysShown = shown
    onTerminalsToggle?(shown)
  }

  public func setTerminalEnabled(_ enabled: Bool) {
    var stored = Prefs.surfaces
    stored.terminal = enabled
    Prefs.surfaces = stored
    surfaces = stored
    onSurfacesToggle?()
  }

  public func setOverlayEnabled(_ enabled: Bool) {
    var stored = Prefs.surfaces
    stored.overlay = enabled
    Prefs.surfaces = stored
    surfaces = stored
    onSurfacesToggle?()
  }

  public func setEditorsEnabled(_ enabled: Bool) {
    editorsEnabled = enabled
    Prefs.editorsEnabled = enabled
    onEditorsToggle?(enabled)
  }

  public func setDictationEnabled(_ enabled: Bool) {
    dictationEnabled = enabled
    Prefs.dictationEnabled = enabled
    onDictationToggle?(enabled)
  }
}
