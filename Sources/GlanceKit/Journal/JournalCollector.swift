import Foundation
import GlanceCore

/// Runs Journal's collectors over some days (spec 2026-10-09-journal-design.md, "Capture"): scans Claude Code's
/// transcripts, runs git and gh, reads the terminal history. It blocks until done, so JournalService calls it on its
/// own work queue, never the main thread. The calendar's meetings come in `Input`: EventKit is read on the main thread.
public enum JournalCollector {
  public struct Input {
    public var days: [JournalDay]
    public var calendar: Calendar
    public var sources: Set<JournalSource>
    /// Folders Glance knows: the recent projects.
    public var folders: [String]
    /// "owner/name" → folder.
    public var repositoryFolders: [String: String]
    public var meetings: [MeetingEvent]
    /// Recorded meetings (Meeting Notes): their notes join their meeting, or stand alone without one.
    public var meetingNotes: [MeetingRecord]
    public var calendarAllowed: Bool
    public var calendarsOff: Set<String>
    public var home: String
    /// `~/.claude/projects`.
    public var claudeProjects: URL
    /// Glance's `history.sqlite`.
    public var history: URL

    public init(days: [JournalDay], calendar: Calendar, sources: Set<JournalSource>, folders: [String],
                repositoryFolders: [String: String], meetings: [MeetingEvent], calendarAllowed: Bool,
                calendarsOff: Set<String>, home: String, claudeProjects: URL, history: URL,
                meetingNotes: [MeetingRecord] = []) {
      self.days = days
      self.calendar = calendar
      self.sources = sources
      self.folders = folders
      self.repositoryFolders = repositoryFolders
      self.meetings = meetings
      self.meetingNotes = meetingNotes
      self.calendarAllowed = calendarAllowed
      self.calendarsOff = calendarsOff
      self.home = home
      self.claudeProjects = claudeProjects
      self.history = history
    }
  }

  public struct Outcome {
    public var events: [JournalEvent] = []
    public var terminal: [JournalDay: [String: [JournalSpan]]] = [:]
    /// The sources that collected nothing, and why ("GitHub" → "signed out").
    public var notes: [String: String] = [:]
  }

  public static func collect(_ input: Input) -> Outcome {
    guard let first = input.days.min(), let last = input.days.max() else { return Outcome() }
    let range = DateInterval(start: first.interval(in: input.calendar).start,
                             end: last.interval(in: input.calendar).end)
    var outcome = Outcome()
    var roots: [String: String] = [:]
    var notRepositories: Set<String> = []
    func root(_ folder: String) -> String? {
      if let known = roots[folder] { return known }
      guard !notRepositories.contains(folder), FileManager.default.fileExists(atPath: folder),
            let found = git(JournalGit.rootArguments(folder: folder)), !found.isEmpty else {
        notRepositories.insert(folder)
        return nil
      }
      roots[folder] = found
      return found
    }
    let commands = input.sources.contains(.git) || input.sources.contains(.terminal) ? history(input.history, range) : []

    if input.sources.contains(.claude) {
      outcome.events += transcripts(in: input.claudeProjects, range: range, calendar: input.calendar) { folder in
        root(folder) ?? folder
      }
    }

    if input.sources.contains(.git) {
      let candidates = input.folders + input.repositoryFolders.values.sorted() + commands.compactMap(\.gitRoot)
      let repositories = JournalGit.roots(candidates, home: input.home, resolve: root)
      var withoutEmail = 0
      for repository in repositories {
        guard let email = git(JournalGit.emailArguments(root: repository)), !email.isEmpty else {
          withoutEmail += 1
          continue
        }
        let arguments = JournalGit.logArguments(root: repository, email: email, range: range, calendar: input.calendar)
        if let log = git(arguments, trim: false) {
          outcome.events += JournalGit.parse(log, root: repository, range: range, calendar: input.calendar)
        }
      }
      if repositories.isEmpty {
        outcome.notes[JournalSource.git.title] = "no repositories yet"
      } else if withoutEmail == repositories.count {
        outcome.notes[JournalSource.git.title] = "no user.email set in git"
      }
    }

    if input.sources.contains(.github) {
      let arguments = JournalGitHub.searchArguments(days: input.days, calendar: input.calendar)
      switch GitHubCLI.run(PullRequests.executable(), arguments).flatMap(GitHubCLI.graphQLData) {
      case .success(let data):
        outcome.events += JournalGitHub.parse(data, range: range, calendar: input.calendar,
                                              folders: RepositoryFolders(input.repositoryFolders))
      case .failure(.signedOut): outcome.notes[JournalSource.github.title] = "signed out"
      case .failure(.notInstalled): outcome.notes[JournalSource.github.title] = "gh isn't installed"
      case .failure(.failed(let message)): outcome.notes[JournalSource.github.title] = message
      case .failure(.notGitHub): break
      }
    }

    if input.sources.contains(.calendar) {
      if input.calendarAllowed {
        outcome.events += JournalMeetings.events(input.meetings, calendarsOff: input.calendarsOff, range: range,
                                                 calendar: input.calendar,
                                                 notes: JournalMeetings.notes(input.meetingNotes))
      } else {
        outcome.notes[JournalSource.calendar.title] = "no calendar access"
      }
      // Meetings recorded without a calendar event count too, with their notes.
      let listed = Set(input.calendarAllowed ? input.meetings.map(\.id) : [])
      outcome.events += JournalMeetings.recorded(input.meetingNotes, calendarEventIDs: listed, range: range,
                                                 calendar: input.calendar)
    }

    if input.sources.contains(.terminal) {
      outcome.terminal = JournalTerminal.spans(commands, calendar: input.calendar)
    }
    return outcome
  }

  /// Each project folder's transcripts touched since `range` began.
  private static func transcripts(in folder: URL, range: DateInterval, calendar: Calendar,
                                  root: (String) -> String) -> [JournalEvent] {
    let files = FileManager.default
    var events: [JournalEvent] = []
    for project in (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
      let transcripts = (try? files.contentsOfDirectory(at: project,
                                                        includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      for file in transcripts where file.pathExtension == "jsonl" {
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard (modified ?? .distantPast) >= range.start else { continue }
        events += JournalTranscripts.events(lines: LineReader(url: file), in: range, calendar: calendar, root: root)
      }
    }
    return events
  }

  /// The terminal runs in `range`; none when the history file doesn't exist (never creates it).
  private static func history(_ url: URL, _ range: DateInterval) -> [CommandRecord] {
    guard FileManager.default.fileExists(atPath: url.path), let store = try? CommandHistoryStore(url: url) else {
      return []
    }
    return (try? store.records(from: range.start, to: range.end)) ?? []
  }

  /// git's output when it succeeds, else nil.
  private static func git(_ arguments: [String], trim: Bool = true) -> String? {
    guard let result = GitHubCLI.execute(JournalGit.git, arguments), result.status == 0 else { return nil }
    let text = String(decoding: result.output, as: UTF8.self)
    return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
  }
}
