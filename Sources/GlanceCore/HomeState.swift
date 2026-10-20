import Foundation

/// What the Home tab shows: Glance Studio's start screen (GlanceKit's `HomeView`).
public struct HomeState: Equatable, Sendable {
  /// The project the window's terminal is in.
  public struct Folder: Equatable, Sendable {
    /// "~/Code/glance".
    public let display: String
    /// "glance".
    public let name: String
    public let branch: String?
    /// Files with uncommitted changes; nil outside a git repository.
    public let changes: Int?

    public init(display: String, name: String, branch: String?, changes: Int?) {
      self.display = display
      self.name = name
      self.branch = branch
      self.changes = changes
    }

    public init(path: String, branch: String?, changes: Int?, home: String = NSHomeDirectory()) {
      self.init(display: HomeState.display(path, home: home), name: FolderLabel.name(forPath: path, home: home),
                branch: branch, changes: changes)
    }
  }

  /// Claude's plan limits: each window's whole percent and the countdown to its reset.
  public struct Usage: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
      public let percent: Int
      /// "3h 7m".
      public let resets: String

      public init(percent: Int, resets: String) {
        self.percent = percent
        self.resets = resets
      }

      init(_ window: PlanUsage.Window, now: Date) {
        self.init(percent: window.shownPercent, resets: window.shortResetText(now: now))
      }

      /// High from 70%, near the limit from 90%, as in the top bar.
      public var severity: PlanUsage.Window.Severity { PlanUsage.Window.severity(shownPercent: percent) }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?

    public init(fiveHour: Window?, sevenDay: Window?) {
      self.fiveHour = fiveHour
      self.sevenDay = sevenDay
    }

    public init(_ usage: PlanUsage, now: Date) {
      self.init(fiveHour: usage.fiveHour.map { Window($0, now: now) }, sevenDay: usage.sevenDay.map { Window($0, now: now) })
    }
  }

  /// A row of the Recent list.
  public struct Project: Equatable, Sendable {
    public let name: String
    /// Absolute: what `openProject` sends back.
    public let path: String
    public let display: String
    public let branch: String?
    /// "2h ago".
    public let when: String

    public init(name: String, path: String, display: String, branch: String?, when: String) {
      self.name = name
      self.path = path
      self.display = display
      self.branch = branch
      self.when = when
    }

    public init(_ entry: RecentProjects.Entry, branch: String?, now: Date, home: String = NSHomeDirectory()) {
      self.init(name: FolderLabel.name(forPath: entry.path, home: home), path: entry.path,
                display: HomeState.display(entry.path, home: home), branch: branch,
                when: RecentProjects.age(of: entry.lastActive, now: now))
    }

    /// The age on the log's time line, where "ago" goes without saying: "2h", "now".
    public var shortAge: String {
      if when == "just now" { return "now" }
      return when.hasSuffix(" ago") ? String(when.dropLast(4)) : when
    }
  }

  /// How many recent projects Home lists.
  public static let recentLimit = 8

  public var version: String
  public var greetingName: String?
  public var showAtLaunch: Bool
  /// The editor new editor tabs open: "Razor Code" or "GS Code".
  public var editorName: String
  public var paneOpen: Bool
  public var folder: Folder?
  public var claude: TabStatusBook.Status
  public var usage: Usage?
  /// Newest first, at most `recentLimit`.
  public var recent: [Project] {
    didSet { if recent.count > Self.recentLimit { recent = Array(recent.prefix(Self.recentLimit)) } }
  }

  public init(
    version: String, greetingName: String?, showAtLaunch: Bool, editorName: String, paneOpen: Bool, folder: Folder?,
    claude: TabStatusBook.Status, usage: Usage?, recent: [Project]
  ) {
    self.version = version
    self.greetingName = greetingName
    self.showAtLaunch = showAtLaunch
    self.editorName = editorName
    self.paneOpen = paneOpen
    self.folder = folder
    self.claude = claude
    self.usage = usage
    self.recent = Array(recent.prefix(Self.recentLimit))
  }

  /// The projects in `new` worth pointing out, by path: ones `old` didn't have, ones on another branch, and ones that
  /// moved ahead of a project that was ahead of them (the one you just went back to). Not the projects it passed,
  /// nor one that only rose because another dropped off.
  public static func news(from old: [Project], to new: [Project]) -> Set<String> {
    var was: [String: (index: Int, project: Project)] = [:]
    for (index, project) in old.enumerated() where was[project.path] == nil { was[project.path] = (index, project) }
    var news: Set<String> = []
    for (index, project) in new.enumerated() {
      guard let before = was[project.path] else {
        news.insert(project.path)
        continue
      }
      let passed = new[(index + 1)...].contains { later in was[later.path].map { $0.index < before.index } ?? false }
      if before.project.branch != project.branch || passed { news.insert(project.path) }
    }
    return news
  }

  /// The first word of the user's full name ("Gobinda" from "Gobinda Das"), or nil when there's none.
  public static func greetingName(fullName: String) -> String? {
    fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
  }

  /// A path with the home folder written `~`.
  public static func display(_ path: String, home: String) -> String {
    let normalized = SessionMatch.normalize(path, home: home)
    let home = SessionMatch.normalize(home, home: home)
    if normalized == home { return "~" }
    if normalized.hasPrefix(home + "/") { return "~" + normalized.dropFirst(home.count) }
    return normalized
  }
}

/// What Home asks the app for.
public enum HomeAction: Equatable, Sendable {
  public enum Target: String, Sendable { case terminal, editor }

  case newTerminal
  /// Back to the shell: the window's terminal tab, focused.
  case focusTerminal
  case newEditor
  /// A recent project, in a new terminal tab or in the editor.
  case openProject(path: String, target: Target)
  case toggleGlance
  case settings
  case setShowAtLaunch(Bool)
}
