import Foundation

/// What Glance Studio's update toast says and offers at each step of an update: Cursor's "New update available ·
/// Later · Install Now", in the design system (agreed in chat 2026-10-09). Install Now downloads and prepares the
/// update; the restart waits for Restart Now, because a restart ends every running terminal session.
public struct UpdateNotice: Equatable, Sendable {
  public enum Step: Equatable, Sendable {
    /// Sparkle asks whether to check for updates on its own.
    case permission
    /// A check the user started.
    case checking
    case available(version: String)
    /// nil until the download's size is known.
    case downloading(fraction: Double?)
    case preparing(fraction: Double)
    /// Downloaded and prepared, waiting for a restart.
    case ready(version: String?, terminalsRunning: Bool)
    /// Restart Now was pressed: Studio quits, installs and opens again.
    case restarting
    case upToDate(version: String)
    case failed(message: String)
  }

  public enum Symbol: Equatable, Sendable { case gift, question, checking, download, prepare, restart, upToDate, failed }
  /// The symbol's colour: coral asks for the user, quiet reports, ok and critical are outcomes.
  public enum Tone: Equatable, Sendable { case coral, quiet, ok, critical }
  public enum Action: Equatable, Sendable { case allow, notNow, cancel, later, install, restart, dismiss, retry }
  /// The design system's buttons: one coral primary at most, the rest quiet.
  public enum Role: Equatable, Sendable { case primary, quiet }

  public struct Button: Equatable, Sendable {
    public let action: Action
    public let title: String
    public let role: Role
  }

  public let symbol: Symbol
  public let tone: Tone
  public let title: String
  /// A version or a percentage, set in the mono face beside the title.
  public let detail: String?
  /// A second line: what a restart ends, or what went wrong.
  public let note: String?
  /// How far the download or its preparation has got, 0...1: the line along the card's bottom edge.
  public let progress: Double?
  public let buttons: [Button]

  public init(_ step: Step) {
    var detail: String?
    var note: String?
    var progress: Double?
    switch step {
    case .permission:
      (symbol, tone, title) = (.question, .quiet, "Check for updates automatically?")
      buttons = [Button(action: .notNow, title: "Not Now", role: .quiet), Button(action: .allow, title: "Allow", role: .primary)]
    case .checking:
      (symbol, tone, title) = (.checking, .quiet, "Checking for updates…")
      buttons = [Button(action: .cancel, title: "Cancel", role: .quiet)]
    case .available(let version):
      (symbol, tone, title) = (.gift, .coral, "New update available")
      detail = Self.nonBlank(version)
      buttons = [Button(action: .later, title: "Later", role: .quiet), Button(action: .install, title: "Install Now", role: .primary)]
    case .downloading(let fraction):
      (symbol, tone) = (.download, .quiet)
      title = fraction == nil ? "Downloading update…" : "Downloading update"
      progress = fraction.map(Self.clamped)
      detail = progress.map(Self.percent)
      buttons = [Button(action: .cancel, title: "Cancel", role: .quiet)]
    case .preparing(let fraction):
      (symbol, tone, title) = (.prepare, .quiet, "Preparing update")
      progress = Self.clamped(fraction)
      detail = progress.map(Self.percent)
      buttons = []
    case .ready(let version, let terminalsRunning):
      (symbol, tone, title) = (.restart, .coral, "Update ready")
      detail = version.flatMap(Self.nonBlank)
      note = terminalsRunning ? "Running terminal sessions will end." : nil
      buttons = [Button(action: .later, title: "Later", role: .quiet), Button(action: .restart, title: "Restart Now", role: .primary)]
    case .restarting:
      (symbol, tone, title) = (.restart, .quiet, "Restarting to update…")
      buttons = []
    case .upToDate(let version):
      (symbol, tone, title) = (.upToDate, .ok, "Glance Studio is up to date")
      detail = Self.nonBlank(version)
      buttons = []
    case .failed(let message):
      (symbol, tone, title) = (.failed, .critical, "Update failed")
      note = Self.nonBlank(message)
      buttons = [Button(action: .dismiss, title: "Dismiss", role: .quiet), Button(action: .retry, title: "Retry", role: .primary)]
    }
    self.detail = detail
    self.note = note
    self.progress = progress
  }

  /// "0.1.0 (18512)", as About and Settings write a version: pilot builds share the marketing version, so the build
  /// tells them apart.
  public static func versionLabel(display: String, build: String) -> String {
    let display = display.trimmingCharacters(in: .whitespacesAndNewlines)
    let build = build.trimmingCharacters(in: .whitespacesAndNewlines)
    if display.isEmpty { return build }
    if build.isEmpty || build == display { return display }
    return "\(display) (\(build))"
  }

  private static func nonBlank(_ text: String) -> String? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  private static func clamped(_ fraction: Double) -> Double { min(max(fraction, 0), 1) }

  /// Rounded down, so it reads 100% only once the download is done.
  private static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded(.down)))%" }
}

/// "Later" on an update: that build stays out of sight for a day, unless the user checks for updates themselves.
/// Studio checks every hour (`SUScheduledCheckInterval`), so without it the toast would come back every hour.
public struct UpdateLater: Equatable, Sendable {
  public static let span: TimeInterval = 24 * 60 * 60

  /// The update's build number (`sparkle:version`), which every release changes.
  public let build: String
  public let until: Date

  public init(build: String, now: Date) {
    self.init(build: build, until: now.addingTimeInterval(Self.span))
  }

  private init(build: String, until: Date) {
    self.build = build
    self.until = until
  }

  public func hides(build: String, now: Date, userInitiated: Bool) -> Bool {
    !userInitiated && build == self.build && now < until
  }

  private static let buildKey = "updateLaterBuild"
  private static let untilKey = "updateLaterUntil"

  public static func load(from defaults: UserDefaults) -> UpdateLater? {
    guard let build = defaults.string(forKey: buildKey), let until = defaults.object(forKey: untilKey) as? Date else {
      return nil
    }
    return UpdateLater(build: build, until: until)
  }

  public func save(to defaults: UserDefaults) {
    defaults.set(build, forKey: Self.buildKey)
    defaults.set(until, forKey: Self.untilKey)
  }
}
