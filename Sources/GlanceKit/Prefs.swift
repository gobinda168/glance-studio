import CoreGraphics
import Foundation
import GlanceCore

/// Glance's preferences (`defaults write dev.glance.Glance <key> <value>`).
public enum Prefs {
  /// UserDefaults is thread-safe (Apple's docs), so one shared instance is fine from any isolation.
  nonisolated(unsafe) static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard

  /// The panel's theme, voice speed, text size and diagram settings.
  static var panel: PanelPrefs {
    get {
      guard let data = defaults.data(forKey: "panel") else { return PanelPrefs() }
      return ((try? JSONDecoder().decode(PanelPrefs.self, from: data)) ?? PanelPrefs()).clamped()
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "panel") }
  }

  /// Which editor Glance Studio's editor tabs open: Razor Code (built in, the default) or GS Code.
  public static var editorKind: EditorKind {
    get { EditorKind(stored: defaults.string(forKey: "editorKind")) }
    set { defaults.set(newValue.rawValue, forKey: "editorKind") }
  }

  /// Razor Code formats a file (Format Document) each time it saves it.
  public static var formatOnSave: Bool {
    get { defaults.bool(forKey: "formatOnSave") }
    set { defaults.set(newValue, forKey: "formatOnSave") }
  }

  /// The terminal suggestions' switches (Settings → Suggestions): all on until switched off.
  public static var suggestions: SuggestionSettings {
    get {
      guard let data = defaults.data(forKey: "suggestions") else { return SuggestionSettings() }
      return (try? JSONDecoder().decode(SuggestionSettings.self, from: data)) ?? SuggestionSettings()
    }
    set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "suggestions") }
  }

  /// The editor chat's headless Claude Code sessions, by project root: the next start resumes the active one.
  public static func chatBook(root: String) -> ChatSessionBook {
    ChatSessionBook(stored: (defaults.dictionary(forKey: "chatSessions") ?? [:])[root])
  }

  public static func setChatBook(_ book: ChatSessionBook, root: String) {
    var all = defaults.dictionary(forKey: "chatSessions") ?? [:]
    all[root] = book.stored
    defaults.set(all, forKey: "chatSessions")
  }

  /// The panel stays docked over the terminal in front, not only when a reply arrives. Closing it hides it until the
  /// next reply.
  public static var terminalsAlwaysShown: Bool {
    get { defaults.object(forKey: "terminalsAlwaysShown") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "terminalsAlwaysShown") }
  }

  /// Glance shows over code editors (VS Code, Cursor…) as an orb with a popover. Off leaves editors to the VS Code
  /// extension: no orb, no panel, nothing read aloud while one is in front.
  public static var editorsEnabled: Bool {
    get { defaults.object(forKey: "editorsEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "editorsEnabled") }
  }

  /// What the one app runs: the terminal on, the overlay on other apps off until the user turns it on. The Settings
  /// "APP" card flips these.
  public static var surfaces: AppSurfaces {
    get {
      AppSurfaces(terminal: defaults.object(forKey: "terminalEnabled") as? Bool ?? true,
                  overlay: defaults.object(forKey: "overlayEnabled") as? Bool ?? false)
    }
    set {
      defaults.set(newValue.terminal, forKey: "terminalEnabled")
      defaults.set(newValue.overlay, forKey: "overlayEnabled")
    }
  }

  /// The First Light onboarding last finished or skipped (`OnboardingFlow.version`); 0 before the first launch.
  public static var onboardingVersion: Int {
    get { defaults.integer(forKey: "onboardingVersion") }
    set { defaults.set(newValue, forKey: "onboardingVersion") }
  }

  /// First Light is still to show: until then Glance doesn't ask for Accessibility or the calendar at launch, since
  /// onboarding asks with its reasons.
  public static var onboardingPending: Bool {
    OnboardingFlow.isPending(completedVersion: onboardingVersion)
  }

  /// While First Light is up (or still to show), nothing pops up over it: no notification cards, ticket cards or
  /// meeting nudges. What arrives meanwhile still lands in the inbox.
  public static var holdsPopups: Bool { onboardingPending }

  /// Glance Studio opens its Home tab at launch.
  public static var showHomeAtLaunch: Bool {
    get { defaults.object(forKey: "showHomeAtLaunch") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "showHomeAtLaunch") }
  }

  /// Glance Studio's first terminal tab at launch runs `claude` in its shell (a restored session keeps its own tabs).
  public static var openClaudeAtLaunch: Bool {
    get { defaults.bool(forKey: "openClaudeAtLaunch") }
    set { defaults.set(newValue, forKey: "openClaudeAtLaunch") }
  }

  /// Claude reads each pull request opened, without being asked (reply drafts only ever come when the user asks).
  /// Off by default (spec 2026-10-08-pr-ask-lists-design.md, "Stage 1").
  public static var pullRequestsAutoClaude: Bool {
    get { defaults.bool(forKey: "pullRequestsAutoClaude") }
    set { defaults.set(newValue, forKey: "pullRequestsAutoClaude") }
  }

  /// The folder that launch tab starts in; nil is the home folder.
  public static var claudeLaunchFolder: String? {
    get { defaults.string(forKey: "claudeLaunchFolder").flatMap { $0.isEmpty ? nil : $0 } }
    set { defaults.set(newValue, forKey: "claudeLaunchFolder") }
  }

  /// Whether this build has Summaries (`Feature.summaries`): Studio sets it from its feature switches. Off, the two
  /// prefs below read as their defaults whatever was saved.
  nonisolated(unsafe) public static var summariesOn = false

  /// When Studio summarizes a Claude Code session (Settings → General → Claude).
  public static var summaryMode: SummaryMode {
    get { summariesOn ? SummaryMode(stored: defaults.string(forKey: "summaryMode")) : .defaultMode }
    set { defaults.set(newValue.rawValue, forKey: "summaryMode") }
  }

  /// How Claude talks in Studio's terminals and chats (Settings → General → Claude).
  public static var responseStyle: ResponseStyle {
    get { summariesOn ? ResponseStyle(stored: defaults.string(forKey: "responseStyle")) : .defaultStyle }
    set { defaults.set(newValue.rawValue, forKey: "responseStyle") }
  }

  /// The projects worked in lately, for Home's Recent list. The first read starts it from the projects Razor Code
  /// kept a session for (`editorSession:<root>`), dated by when their git index or folder last changed.
  public static var recentProjects: RecentProjects {
    get {
      if let data = defaults.data(forKey: "recentProjects") { return RecentProjects(data: data) }
      let prefix = "editorSession:"
      let roots = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
      let seeded = RecentProjects.seeded(paths: roots, lastActive: lastModified)
      defaults.set(seeded.encoded(), forKey: "recentProjects")
      return seeded
    }
    set { defaults.set(newValue.encoded(), forKey: "recentProjects") }
  }

  /// The repository the Pull requests side bar shows ("owner/name"), picked in its picker, for every window and across
  /// launches; nil until one is picked (spec 2026-10-08-pr-repositories-design.md).
  public static var pullRequestsRepository: String? {
    get { defaults.string(forKey: "pullRequestsRepository") }
    set { defaults.set(newValue, forKey: "pullRequestsRepository") }
  }

  /// The Pull requests side bar's tab (To review, Yours or Merged), for every window and across launches.
  public static var pullRequestsTab: PullRequests.List {
    get { defaults.string(forKey: "pullRequestsTab").flatMap(PullRequests.List.init(rawValue:)) ?? .waitingOnYou }
    set { defaults.set(newValue.rawValue, forKey: "pullRequestsTab") }
  }

  /// The picker's RECENT, newest first.
  public static var pullRequestsRecent: [String] {
    get { defaults.stringArray(forKey: "pullRequestsRecent") ?? [] }
    set { defaults.set(newValue, forKey: "pullRequestsRecent") }
  }

  /// Which folder on this Mac holds each GitHub repository: lowercased "owner/name" → folder.
  public static var repositoryFolders: [String: String] {
    get { defaults.dictionary(forKey: "repositoryFolders") as? [String: String] ?? [:] }
    set { defaults.set(newValue, forKey: "repositoryFolders") }
  }

  /// Where Clone… put a repository last; nil until it has.
  public static var cloneFolder: String? {
    get { defaults.string(forKey: "cloneFolder") }
    set { defaults.set(newValue, forKey: "cloneFolder") }
  }

  private static func lastModified(_ root: String) -> Date? {
    [root + "/.git/index", root].lazy
      .compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.first
  }

  /// Where the editor orb was dragged: its centre from the editor window's bottom-right corner. Nil for the default.
  public static var orbOffset: CGVector? {
    get {
      guard let pair = defaults.array(forKey: "orbOffset") as? [Double], pair.count == 2 else { return nil }
      return CGVector(dx: pair[0], dy: pair[1])
    }
    set {
      if let newValue { defaults.set([Double(newValue.dx), Double(newValue.dy)], forKey: "orbOffset") }
      else { defaults.removeObject(forKey: "orbOffset") }
    }
  }

  public static var dictationEnabled: Bool {
    get { defaults.object(forKey: "dictationEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "dictationEnabled") }
  }

  /// Ask Scribe not to retain audio. Turned off automatically if the account doesn't allow it.
  static var scribeZeroRetention: Bool {
    get { defaults.object(forKey: "scribeZeroRetention") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "scribeZeroRetention") }
  }

  static var fnNoticeShown: Bool {
    get { defaults.bool(forKey: "fnNoticeShown") }
    set { defaults.set(newValue, forKey: "fnNoticeShown") }
  }

  /// `type` (synthetic keystrokes, default) or `paste` (clipboard + ⌘V, restored afterwards).
  static var insertMode: String { defaults.string(forKey: "insertMode") ?? "type" }

  static var fnUsage: FnUsage {
    FnUsage(rawValue: UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int)
  }

  /// `elevenlabs`, `minimax`, `kokoro` or `system` (Mac voice only). Unset: ElevenLabs once its key is saved, else
  /// Kokoro.
  static var voiceProviderPreference: String? {
    get { defaults.string(forKey: "voiceProvider") }
    set { defaults.set(newValue, forKey: "voiceProvider") }
  }

  static var narrationVoice: NarrationVoice {
    NarrationVoice.resolve(preference: voiceProviderPreference,
                           hasElevenLabsKey: KeychainStore.provider(.elevenLabs).exists())
  }

  /// The cloud provider narrating replies, or nil when Kokoro or the Mac voice is chosen.
  static var activeProvider: ProviderID? {
    if case .cloud(let id) = narrationVoice { id } else { nil }
  }

  static func voice(for id: ProviderID) -> VoiceOption {
    guard let voiceID = defaults.string(forKey: "voice.\(id.rawValue)") else { return id.defaultVoice }
    return VoiceOption(id: voiceID, name: defaults.string(forKey: "voiceName.\(id.rawValue)") ?? voiceID, detail: "")
  }

  static func setVoice(_ voice: VoiceOption, for id: ProviderID) {
    defaults.set(voice.id, forKey: "voice.\(id.rawValue)")
    defaults.set(voice.name, forKey: "voiceName.\(id.rawValue)")
  }

  static func model(for id: ProviderID) -> String {
    defaults.string(forKey: "model.\(id.rawValue)") ?? id.defaultModel
  }

  static func setModel(_ model: String, for id: ProviderID) {
    defaults.set(model, forKey: "model.\(id.rawValue)")
  }

  /// The Kokoro voice, for narration and as the cloud voice's fallback.
  static var kokoroVoice: VoiceOption {
    get { KokoroVoices.option(id: defaults.string(forKey: "voice.kokoro")) }
    set { defaults.set(newValue.id, forKey: "voice.kokoro") }
  }

  /// The Mac voice's identifier (`defaults write dev.glance.Glance voice <identifier>`). Nil picks the best installed.
  static var macVoice: String? {
    get { defaults.string(forKey: "voice") }
    set { defaults.set(newValue, forKey: "voice") }
  }
}
