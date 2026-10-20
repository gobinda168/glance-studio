import AppKit
import Combine
import Darwin
import GlanceCore

/// The orb assistant (spec "The orb assistant"): a long-lived headless `claude` in Glance's own folder with Glance's
/// MCP server and the user's connectors. One conversation until 15 idle minutes; each answer is shown in Glance's card
/// from the orb the way a `tell` is (the question muted above it) and its part before `---` is spoken. Every acting
/// tool goes through an Allow / Deny card (`--permission-prompt-tool mcp__glance__approve`).
@MainActor
public final class OrbAssistant: ObservableObject {
  public static let shared = OrbAssistant()

  public struct Exchange: Identifiable, Equatable {
    public let id = UUID()
    public let asked: String
    public var spoken: String?
    public var detail: String?
  }

  @Published public private(set) var exchanges: [Exchange] = []
  /// A turn is running: the orb shows working.
  @Published public private(set) var working = false {
    didSet { if working != oldValue { OrbChannelHub.shared.assistantWorking = working } }
  }
  @Published public private(set) var problem: String?
  /// Studio: the bundle's `glance`, for the assistant's MCP config.
  public var glancePath = ""

  public var pid: Int32? { process.map { $0.processIdentifier } }

  private var process: Process?
  private var input: FileHandle?
  private var errorTail = ""
  /// Ends the `claude` once the conversation has gone idle (the next question starts a new one anyway).
  private var idleTimer: DispatchWorkItem?

  /// Its working directory: only CLAUDE.md and mcp.json in it.
  static var folder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/Assistant", isDirectory: true)
  }

  /// The id of the Restart button on the "Glance assistant stopped" card.
  static let restartAction = "orbAssistant.restart"

  private init() {}

  public func send(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !working else {
      if Prefs.orbChannelSessionsSpeak, SpeechQueue.quietReason() == nil {
        SpeechQueue.shared.say("I'm still on your last question.", interrupt: false) { _ in }
      }
      return
    }
    // The conversation went idle while its `claude` lived on (a Mac asleep past the timer): start a new one.
    if process != nil, let last = Prefs.orbAssistantLastUse,
       Date().timeIntervalSince(last) >= AssistantSession.idleLimit { end() }
    idleTimer?.cancel()
    idleTimer = nil
    exchanges.append(Exchange(asked: trimmed))
    if exchanges.count > 6 { exchanges.removeFirst(exchanges.count - 6) }
    working = true
    problem = nil
    if process != nil { return write(trimmed) }
    ClaudeLocator.locate { [weak self] found in
      guard let self, self.working else { return }
      guard let found else { return self.fail("Claude Code isn't installed or isn't on PATH.") }
      do {
        try self.launch(found)
        Prefs.orbAssistantLastUse = Date()
        self.write(trimmed)
      } catch {
        self.fail("Couldn't start Claude Code: \(error.localizedDescription)")
      }
    }
  }

  public func newConversation() {
    end()
    Prefs.orbAssistantSession = nil
    exchanges.removeAll()
    problem = nil
  }

  /// After a failure: a fresh `claude`, and the question that failed asked again.
  public func restart() {
    guard problem != nil, !working else { return }
    end()
    problem = nil
    if let last = exchanges.last, last.spoken == nil {
      exchanges.removeLast()
      send(last.asked)
    }
  }

  private func launch(_ found: ClaudeLocator.Found) throws {
    errorTail = ""
    let fm = FileManager.default
    try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
    try Data(AssistantPrompt.claudeMD.utf8).write(to: Self.folder.appendingPathComponent("CLAUDE.md"), options: .atomic)
    let config = Self.folder.appendingPathComponent("mcp.json")
    try Data(AssistantPrompt.mcpConfig(glancePath: glancePath).text.utf8).write(to: config, options: .atomic)
    let saved = Prefs.orbAssistantSession
    let plan = AssistantSession.plan(saved: saved, lastUse: Prefs.orbAssistantLastUse,
                                     transcriptExists: saved.flatMap { ChatFeed.locate(id: $0) } != nil, now: Date(),
                                     newID: { UUID().uuidString.lowercased() })
    Prefs.orbAssistantSession = plan.id

    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = HumanizeStyle.apply(Prefs.responseStyle, body: Resources.humanizeBody,
                                            to: AssistantSession.arguments(id: plan.id, resume: plan.resume,
                                                                           mcpConfigPath: config.path))
    process.currentDirectoryURL = Self.folder
    var environment = ProcessInfo.processInfo.environment
    if let path = found.path { environment["PATH"] = path }
    environment["CLAUDECODE"] = nil
    process.environment = environment
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    // A write after Claude exits must fail, not kill the app with SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let lines = LineSplitter()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      let complete = lines.append(data)
      guard !complete.isEmpty else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(complete) } }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      let text = String(decoding: data, as: UTF8.self)
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.errorTail = String(((self?.errorTail ?? "") + text).suffix(600)) }
      }
    }
    process.terminationHandler = { [weak self] ended in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(ended) } }
    }
    do {
      try process.run()
    } catch {
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      throw error
    }
    LiveProcesses.add(process)
    self.process = process
    input = stdin.fileHandleForWriting
  }

  private func write(_ text: String) {
    do {
      try input?.write(contentsOf: Data((InlineAsk.userLine(text) + "\n").utf8))
    } catch {
      fail("Claude stopped unexpectedly.")
    }
  }

  /// Every turn ends with a `result` line (`ChatSession.outcome`): an error, or the answer (which may be empty).
  private func received(_ lines: [String]) {
    for line in lines {
      switch ChatSession.outcome(line: line) {
      case nil: continue
      case .failed(let detail): fail(detail)
      case .done: answered(AssistantReply.resultText(line: line) ?? "")
      }
    }
  }

  private func answered(_ text: String) {
    guard working else { return }
    let reply = AssistantReply.split(text)
    let asked = exchanges.last?.asked ?? ""
    if var last = exchanges.popLast() {
      last.spoken = reply.spoken
      last.detail = reply.detail
      exchanges.append(last)
    }
    working = false
    Prefs.orbAssistantLastUse = Date()
    scheduleIdleEnd()
    let markdown = [reply.spoken, reply.detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    guard !markdown.isEmpty else { return }
    OrbChannelHub.shared.showAssistantReply(asked: asked, markdown: markdown)
    if !reply.spoken.isEmpty, Prefs.orbChannelSessionsSpeak, SpeechQueue.quietReason() == nil {
      SpeechQueue.shared.say(reply.spoken, interrupt: false) { _ in }
    }
  }

  private func scheduleIdleEnd() {
    idleTimer?.cancel()
    let timer = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { if let self, !self.working { self.end() } }
    }
    idleTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + AssistantSession.idleLimit, execute: timer)
  }

  private func ended(_ ended: Process) {
    LiveProcesses.remove(ended)
    guard ended === process else { return }
    process = nil
    input = nil
    if working {
      let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
      fail(detail.isEmpty ? "Claude stopped unexpectedly." : "Claude stopped unexpectedly: \(detail)")
    }
  }

  /// The turn failed: a Claude card at the top says so, with Restart.
  private func fail(_ message: String) {
    guard working else { return }
    working = false
    problem = message
    scheduleIdleEnd()
    var notice = ChannelNotices.message(id: "orb-assistant-" + UUID().uuidString, label: "Glance", surface: nil,
                                        cwd: nil, title: "Glance assistant stopped — \(message)", body: nil,
                                        date: Date())
    notice.actions = [Notice.Action(id: Self.restartAction, title: "Restart")]
    NotificationHub.shared.post(notice)
  }

  private static var restartWired = false

  /// The Restart button through the hub's `onAction`, in front of whatever handled actions before (at the hub's
  /// start, so a card saved before a relaunch still finds it).
  static func wireRestart() {
    guard !restartWired else { return }
    restartWired = true
    let hub = NotificationHub.shared
    let previous = hub.onAction
    hub.onAction = { notice, id in
      if id == restartAction { OrbAssistant.shared.restart() } else { previous?(notice, id) }
    }
  }

  /// Ends its `claude` (the orb channel or the assistant switch going off; the next question starts it again).
  public func end() {
    idleTimer?.cancel()
    idleTimer = nil
    try? input?.close()
    input = nil
    if let process {
      LiveProcesses.remove(process)
      if process.isRunning { process.terminate() }
    }
    process = nil
    working = false
  }
}

/// What the assistant's Glance tools read and do (spec "Extra tools in assistant mode"). Studio fills the two hooks.
@MainActor
public enum OrbAssistantTools {
  public static var openTarget: ((AssistantTarget.Target) -> Bool)?
  public static var startSession: ((String, String) -> Bool)?

  static func run(_ call: ChannelCall, hub: OrbChannelHub) -> (JSONValue, Bool) {
    switch call {
    case .notifications(let filter):
      let rows = NotificationHub.shared.book.rows(filter: nil, showDone: false)
        .filter { filter == "all" || (filter == "needs_you" ? $0.newest.kind.needsYou : $0.unread) }
        .prefix(30)
      let iso = ISO8601DateFormatter()
      return (.array(rows.map { row in
        ["id": .string(row.newest.threadKey), "source": .string(row.newest.source.title),
         "kind": .string(row.newest.kind.label), "title": .string(row.newest.title),
         "place": row.newest.place.map(JSONValue.string) ?? .null, "preview": .string(row.newest.preview),
         "date": .string(iso.string(from: row.newest.date)), "unread": .bool(row.unread)]
      }), false)
    case .calendar(let days):
      guard MeetingNudger.shared.calendar.access == .allowed else {
        return ("Glance doesn't have calendar access.", true)
      }
      let start = Calendar.current.startOfDay(for: Date())
      let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
      let events = MeetingNudger.shared.calendar.events(from: start, to: end).filter { !$0.declined }
      let iso = ISO8601DateFormatter()
      return (.array(events.map { event in
        ["title": .string(event.title), "start": .string(iso.string(from: event.start)),
         "end": .string(iso.string(from: event.end)), "all_day": .bool(event.isAllDay),
         "link": event.link.map { .string($0.url.absoluteString) } ?? .null]
      }), false)
    case .sessions:
      let sessions = hub.book.sessions.values.filter { !$0.assistant }.sorted { $0.id < $1.id }
      return (.array(sessions.map { session in
        ["name": .string(hub.book.handle(of: session.id)),
         "folder": session.projectDir.map(JSONValue.string) ?? .null,
         "state": .string(session.state?.rawValue ?? ChannelOrbState.idle.rawValue),
         "doing": session.caption.map(JSONValue.string) ?? .null,
         "can_be_messaged": .bool(session.channel || session.surface != nil),
         "in_studio": .bool(session.surface != nil)]
      }), false)
    case .meetingNotes(let query):
      let library = MeetingNotesLibrary.shared
      library.load()
      let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
      let records = library.records.filter { record in
        guard !needle.isEmpty else { return true }
        return record.title.lowercased().contains(needle)
          || (record.summary?.overview.lowercased().contains(needle) ?? false)
      }.sorted { $0.start > $1.start }.prefix(5)
      let iso = ISO8601DateFormatter()
      return (.array(records.map { record in
        ["title": .string(record.title), "start": .string(iso.string(from: record.start)),
         "overview": record.summary.map { .string($0.overview) } ?? .null,
         "decisions": .array((record.summary?.decisions ?? []).map(JSONValue.string)),
         "action_items": .array((record.summary?.actionItems ?? []).map { .string($0.task) })]
      }), false)
    case .tickets:
      return (.array(TicketService.shared.book.tickets.prefix(20).map { ticket in
        ["key": .string(ticket.key), "title": .string(ticket.title), "status": .string(ticket.status),
         "priority": ticket.priority.map(JSONValue.string) ?? .null]
      }), false)
    case .open(let text):
      let ids = Set(NotificationHub.shared.book.rows(filter: nil, showDone: true).map(\.newest.threadKey))
      let handles = Set(hub.book.sessions.values.filter { !$0.assistant }.map { hub.book.handle(of: $0.id) })
      guard let target = AssistantTarget.parse(text, notificationIDs: ids, sessionHandles: handles) else {
        return (.string("Nothing called \(text) to open. Use a notification id, a session name, or a pull request."),
                true)
      }
      let opened = openTarget?(target) ?? false
      return opened ? (["opened": true], false) : (.string("Couldn't open \(text)."), true)
    case .messageSession(let handle, let text):
      guard let session = hub.book.session(handle: handle) else {
        return (.string("No session called \(handle). Call sessions for their names."), true)
      }
      // Without a channel the words are typed into its split; a waiting session may be showing a permission menu
      // where Return picks "Yes".
      if !session.channel, session.state == .waiting {
        return ("That session is waiting for you — answer it first.", true)
      }
      return hub.message(handle: handle, text: text, via: .text)
        ? (["sent": true], false) : (.string("\(handle) can't take a message."), true)
    case .startSession(let folder, let prompt):
      let path = (folder as NSString).expandingTildeInPath
      guard path.hasPrefix("/") else {
        return (.string("Give start_session a full folder path (starting with / or ~), not \(folder)."), true)
      }
      return startSession?(path, prompt) == true
        ? (["started": true], false) : (.string("Couldn't start Claude in \(folder)."), true)
    default:
      return ("Not an assistant tool.", true)
    }
  }
}
