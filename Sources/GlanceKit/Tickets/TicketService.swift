import AppKit
import Combine
import GlanceCore

/// Tickets (spec 2026-10-09-tickets-design.md): fetches the user's tickets through their tracker connectors in
/// `claude`, keeps them in `tickets.json`, ranks them, watches the work for status signals and moves tickets. One
/// tracker run at a time per tracker.
@MainActor
public final class TicketService: ObservableObject {
  public enum TrackerState: Equatable { case idle, fetching, failed(String) }

  public static let shared = TicketService()

  @Published public private(set) var book = TicketBook()
  @Published public var prefs: TicketPrefs = TicketStore.loadPrefs() {
    didSet { if prefs != oldValue { TicketStore.savePrefs(prefs) } }
  }
  @Published public private(set) var states: [String: TrackerState] = [:]
  @Published public private(set) var pausedUntil: Date?
  @Published public private(set) var ranking = false
  @Published public private(set) var rankError: String?

  /// Jira sites Glance reads itself; Studio sets it before `start()`.
  public var direct: DirectTickets? {
    didSet {
      directObserver = direct?.changed.receive(on: DispatchQueue.main).sink { [weak self] in
        MainActor.assumeIsolated { self?.directChanged() }
      }
    }
  }
  private var directObserver: AnyCancellable?
  private var directRuns: [String: Task<Void, Never>] = [:]

  /// Every tracker, switched on or off: Claude's connectors, then Glance's sites.
  public var allTrackers: [Tracker] { ConnectorProbe.shared.trackers + (direct?.trackers ?? []) }

  public var enabledTrackers: [Tracker] {
    allTrackers.filter { !prefs.trackersOff.contains($0.server) }
  }

  /// A site signed in or out: the page redraws; a newly signed-in site is read.
  private func directChanged() {
    objectWillChange.send()
    fetchNewTrackers()
  }

  /// Reads each switched-on tracker never read and not being read: a site just signed in, a connector the probe just
  /// found (signed in on claude.ai, then Check again).
  private func fetchNewTrackers() {
    guard started, (pausedUntil ?? .distantPast) <= Date() else { return }
    for tracker in enabledTrackers where book.fetched[tracker.server] == nil && states[tracker.server] == nil {
      fetch(tracker) {}
    }
  }

  /// The hosts Glance's switched-on sites cover, and their trackers' servers.
  private var covered: (hosts: Set<String>, keep: Set<String>) {
    let glance = enabledTrackers.filter { $0.kind == .glance }
    return (Set(glance.compactMap { direct?.host($0) }), Set(glance.map(\.server)))
  }

  private var started = false
  private var saveScheduled = false
  private var fetchRuns: [String: ClaudeOneShot.Run] = [:]
  /// Who is waiting on each tracker's run in flight. A second refresh joins the run instead of replacing it: a
  /// replaced run never answers, and a rank waiting on it would show "Ordering…" for good.
  private var fetchWaiters: [String: [() -> Void]] = [:]
  private var probeObserver: AnyCancellable?
  private var rankRun: ClaudeOneShot.Run?
  private var tick: Timer?
  private var wakeObserver: NSObjectProtocol?

  public func start() {
    guard !started else { return }
    started = true
    book = TicketStore.load()
    // The page shows the probe's trackers; re-publish so views observing the service redraw. A tracker it finds is
    // read once the change has landed.
    probeObserver = ConnectorProbe.shared.objectWillChange.sink { [weak self] in
      self?.objectWillChange.send()
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.fetchNewTrackers() } }
    }
    ConnectorProbe.shared.check()
    tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.ticked() }
    }
    if wakeObserver == nil {
      wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.ticked() } }
    }
    if activeObserver == nil {
      activeObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.scanSignals() } }
    }
    ticked()
  }

  public func stop() {
    started = false
    fetchRuns.values.forEach { $0.cancel() }
    fetchRuns = [:]
    directRuns.values.forEach { $0.cancel() }
    directRuns = [:]
    fetchWaiters = [:]
    probeObserver = nil
    tick?.invalidate()
    tick = nil
    rankRun?.cancel()
    rankRun = nil
    ranking = false
    TicketsCard.shared.hide()
  }

  // MARK: Moves

  @Published public private(set) var moving: Set<String> = []
  public var onShowTicket: ((String) -> Void)?
  private var moveRuns: [String: ClaudeOneShot.Run] = [:]

  public func post(_ notice: Notice) { NotificationHub.shared.post(notice) }

  public func move(_ ticket: Ticket, to transition: Ticket.Transition, reason: String, auto: Bool,
                   assignToMe: Bool = false, then: ((Bool) -> Void)? = nil) {
    guard moveRuns[ticket.id] == nil, !moving.contains(ticket.id) else { then?(false); return }
    guard let tracker = allTrackers.first(where: { $0.server == ticket.tracker }) else {
      return moveFailed(ticket, transition, "\(ticket.tracker) isn't connected.", auto: auto, then: then)
    }
    let comment = auto && prefs.comment ? "\(reason) — moved by Glance" : nil
    if tracker.kind == .glance, let direct {
      moving.insert(ticket.id)
      Task { [weak self] in
        let result = await direct.move(ticket, to: transition, assignToMe: assignToMe, comment: comment)
        guard let self else { return }
        self.moving.remove(ticket.id)
        self.finishMove(ticket, transition, result, reason: reason, auto: auto, assignToMe: assignToMe, then: then)
      }
      return
    }
    guard !tracker.moveTools.isEmpty else {
      return moveFailed(ticket, transition, "The \(tracker.name) connector can't change tickets.", auto: auto,
                        then: then)
    }
    moving.insert(ticket.id)
    moveRuns[ticket.id] = ClaudeOneShot.run(
      arguments: TicketPrompts.arguments(tools: TicketPrompts.moveTools(tracker, comment: comment != nil),
                                         model: "haiku", otherServers: otherServers(than: tracker)),
      prompt: TicketPrompts.movePrompt(ticket, to: transition, assignToMe: assignToMe, comment: comment,
                                       tracker: tracker),
      folder: nil, timeout: TicketPrompts.moveTimeout, environment: TrackerProbe.waitForConnectors
    ) { [weak self] reply in
      guard let self else { return }
      self.moveRuns[ticket.id] = nil
      self.moving.remove(ticket.id)
      self.finishMove(ticket, transition, reply.mapError({ TicketFailure(message: $0.message) }).flatMap(TicketPrompts.moved),
                      reason: reason, auto: auto, assignToMe: assignToMe, then: then)
    }
  }

  /// A move's answer, from either kind of source: the record, the ticket's new status, Undo's notice, or the failure.
  private func finishMove(_ ticket: Ticket, _ transition: Ticket.Transition, _ result: Result<String?, TicketFailure>,
                          reason: String, auto: Bool, assignToMe: Bool, then: ((Bool) -> Void)?) {
    switch result {
    case .success(let status):
      let record = TicketMove(id: UUID().uuidString, ticketID: ticket.id, key: ticket.key, from: ticket.status,
                              fromCategory: ticket.statusCategory, to: status ?? transition.name,
                              toCategory: transition.category, reason: reason, auto: auto, date: Date())
      var updated = ticket
      updated.status = record.to
      updated.statusCategory = transition.category
      if assignToMe { updated.group = .assigned }
      mutate {
        $0.update(updated)
        $0.record(record)
        $0.suggestions.resolve(ticketID: ticket.id)
        $0.suggestions.setAutoBlocked(ticket.id, false)
        $0.noteActivity(ticket.id, at: record.date)
      }
      GlanceEventBus.shared.publish(.ticketMoved(key: record.key, from: record.from, to: record.to))
      if auto { post(TicketNotices.moved(record, ticket: updated)) }
      refresh(ticket.tracker)
      then?(true)
    case .failure(let failure):
      moveFailed(ticket, transition, failure.message, auto: auto, then: then)
    }
  }

  private func moveFailed(_ ticket: Ticket, _ transition: Ticket.Transition, _ message: String, auto: Bool,
                          then: ((Bool) -> Void)?) {
    if auto { mutate { $0.suggestions.setAutoBlocked(ticket.id, true) } }
    if TicketPrompts.isUsageLimit(message) { pausedUntil = Date().addingTimeInterval(3600) }
    if message.lowercased().contains("tool") { ConnectorProbe.shared.check(force: true) }
    post(TicketNotices.failed(ticket, transition: transition, message: message, at: Date()))
    then?(false)
  }

  /// Every MCP server but the tracker's, to keep out of its runs.
  private func otherServers(than tracker: Tracker) -> [String] {
    ConnectorProbe.shared.servers.map(\.name).filter { $0 != tracker.server }
  }

  /// Ask Claude what the user's words mean for this ticket. Nothing is written; the caller shows the proposal and,
  /// on a yes, calls `move`.
  @discardableResult
  public func proposeEdit(_ ticket: Ticket, request: String,
                          completion: @escaping @MainActor (Result<TicketPrompts.Edit, TicketFailure>) -> Void)
    -> ClaudeOneShot.Run {
    ClaudeOneShot.run(
      arguments: TicketPrompts.arguments(tools: [], model: "haiku"),
      prompt: TicketPrompts.editPrompt(ticket, request: request),
      folder: nil, timeout: TicketPrompts.editTimeout
    ) { reply in
      completion(reply.mapError { TicketFailure(message: $0.message) }.flatMap { TicketPrompts.edit(from: $0, for: ticket) })
    }
  }

  /// Up next's Assign to me + Start, and the morning card's Start: into the in-progress status (assigning an Up next
  /// ticket first). With no single in-progress status, the page opens on it to choose.
  public func start(_ ticket: Ticket) {
    guard let transition = ticket.onlyTransition(to: .inProgress) else { onShowTicket?(ticket.id); return }
    move(ticket, to: transition, reason: "Started by you", auto: false, assignToMe: ticket.group == .upNext)
  }

  public func undo(_ moveID: String) {
    guard let record = book.moves.first(where: { $0.id == moveID }), let ticket = book.ticket(record.ticketID) else {
      return
    }
    let back = ticket.transitions.first { $0.name.caseInsensitiveCompare(record.from) == .orderedSame }
      ?? ticket.onlyTransition(to: record.fromCategory)
    guard let back else { onShowTicket?(ticket.id); return }
    move(ticket, to: back, reason: "Undo", auto: false)
  }

  public func snooze(_ suggestionID: String) { mutate { $0.suggestions.snooze(suggestionID) } }

  public func mute(_ ticketID: String) { mutate { $0.suggestions.mute(ticketID) } }

  /// A ticket notice's button (from the nudge card or the inbox).
  public func handle(_ notice: Notice, actionID: String) {
    guard let action = TicketNotices.Action(id: actionID), let id = notice.meta["ticket"],
          let ticket = book.ticket(id) else { return }
    switch action {
    case .move(let transitionID), .retry(let transitionID):
      guard let transition = ticket.transitions.first(where: { $0.id == transitionID }) else {
        onShowTicket?(id)
        return
      }
      let reason = book.suggestions.pending(for: id).first?.evidence ?? "By you"
      move(ticket, to: transition, reason: reason, auto: false)
    case .snooze(let suggestionID): snooze(suggestionID)
    case .mute: mute(id)
    case .undo(let moveID): undo(moveID)
    case .choose: onShowTicket?(id)
    }
  }

  // MARK: Signals

  private var scanning = false
  private var ticks = 0
  private var activeObserver: NSObjectProtocol?
  /// Ticket id → the folder it was last worked in (a commit's or branch's repository, a session's folder), for Work on
  /// this.
  public private(set) var lastFolder: [String: String] = [:]

  /// Runs the git/gh scan, turns it (and staleness) into suggestions, and applies them.
  public func scanSignals() {
    guard started, !scanning, !book.tickets.isEmpty else { return }
    scanning = true
    let now = Date()
    TicketSignalWatcher.scan(now: now) { [weak self] scan in
      guard let self else { return }
      self.scanning = false
      let tickets = self.book.tickets
      let found = TicketSignals.git(commits: scan.commits, branches: scan.branches, tickets: tickets, now: now)
        + TicketSignals.pullRequests(scan.pullRequests, tickets: tickets, now: now)
        + TicketSignals.stale(tickets: tickets, activity: self.book.activity, now: now, days: self.prefs.staleDays)
      for suggestion in found where suggestion.signal == .git {
        if let root = scan.roots[suggestion.evidenceID] { self.lastFolder[suggestion.ticketID] = root }
      }
      let seeding = self.book.lastScan == nil
      self.mutate { $0.lastScan = now }
      self.apply(found, seeding: seeding)
    }
  }

  /// Each suggestion: note the activity, then drop it, move the ticket, or nudge (once per pending suggestion).
  public func apply(_ suggestions: [Suggestion], seeding: Bool) {
    for suggestion in suggestions {
      guard let ticket = book.ticket(suggestion.ticketID) else { continue }
      if suggestion.signal != .stale { mutate { $0.noteActivity(ticket.id, at: suggestion.date) } }
      switch TicketPolicy.decide(suggestion, ticket: ticket, prefs: prefs, state: book.suggestions, seeding: seeding) {
      case .drop:
        continue
      case .auto(let transition):
        guard !moving.contains(ticket.id) else { continue }
        move(ticket, to: transition, reason: suggestion.evidence, auto: true)
      case .nudge:
        var isNew = false
        mutate { isNew = $0.suggestions.add(suggestion) }
        if isNew { post(TicketNotices.suggestion(suggestion, ticket: ticket)) }
      }
    }
  }

  // MARK: Sessions and the check-in

  /// A Claude turn ended (the transcript watcher's `.done`): its prompts and branch become session suggestions, and
  /// the session is kept for the check-in.
  public func sessionEnded(file: String, cwd: String?) {
    guard started, !book.tickets.isEmpty else { return }
    DispatchQueue.global(qos: .utility).async {
      let lines = Self.tail(of: file, bytes: 512 * 1024)
      let scan = TicketTranscript.scan(lines)
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          let now = Date()
          let repository = cwd.flatMap { TicketSignals.repository(for: $0, in: Prefs.repositoryFolders) }
          let found = TicketSignals.session(prompts: scan.prompts, branch: scan.branch, repository: repository,
                                            file: file, tickets: self.book.tickets, at: now)
          if let cwd { found.forEach { self.lastFolder[$0.ticketID] = cwd } }
          if !scan.prompts.isEmpty {
            self.mutate { $0.note(SessionNote(file: file, folder: cwd, prompts: Array(scan.prompts.suffix(5)), date: now)) }
          }
          self.apply(found, seeding: false)
        }
      }
    }
  }

  /// The last `bytes` of a file as lines (the first, likely cut, dropped when the file is longer).
  nonisolated static func tail(of path: String, bytes: Int) -> [String] {
    guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
    try? handle.seek(toOffset: start)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    var lines = text.split(separator: "\n").map(String.init)
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
  }

  /// Work on this started: the ticket counts as touched today, and its folder is remembered.
  public func noteWorkOn(_ ticketID: String, folder: String) {
    lastFolder[ticketID] = folder
    mutate { $0.noteActivity(ticketID, at: Date()) }
  }

  private var checkInRun: ClaudeOneShot.Run?

  public func checkIn() {
    let tickets = book.tickets.filter { $0.statusCategory != .done }
    let sessions = TicketCheckIn.unmatched(book.sessions.filter { Calendar.current.isDateInToday($0.date) },
                                           tickets: tickets)
    let show = { [weak self] (matched: Set<String>) in
      guard let self else { return }
      let rows = TicketCheckIn.rows(book: self.book, matched: matched, now: Date(), calendar: .current)
      guard !rows.isEmpty else { return }
      self.post(TicketNotices.checkIn(count: rows.count, at: Date()))
      TicketsCard.shared.showCheckIn(rows)
    }
    guard !sessions.isEmpty, !tickets.isEmpty else { return show([]) }
    checkInRun?.cancel()
    checkInRun = ClaudeOneShot.run(arguments: TicketPrompts.arguments(tools: [], model: "haiku"),
                                   prompt: TicketCheckIn.matchPrompt(tickets: tickets, sessions: sessions),
                                   folder: nil, timeout: 60) { [weak self] reply in
      self?.checkInRun = nil
      let matched = (try? reply.get()).map { TicketCheckIn.matched(from: $0, tickets: tickets) } ?? []
      self?.mutate { book in matched.forEach { book.noteActivity($0, at: Date()) } }
      show(matched)
    }
  }

  // MARK: Rank

  /// Fetches every tracker, then ranks (`ranking` from the start). `then` gets whether a new rank came back.
  public func rerank(then: ((Bool) -> Void)? = nil) {
    guard started else { then?(false); return }
    ranking = true
    rankError = nil
    refresh { [weak self] in self?.rank(then: then) }
  }

  /// Stop a rank that is taking too long: the plain order stands until the next one.
  public func stopRanking() {
    rankRun?.cancel()
    rankRun = nil
    ranking = false
  }

  /// One rank; an unreadable answer is retried once before the plain order stands (spec "Errors").
  private func rank(retried: Bool = false, then: ((Bool) -> Void)?) {
    let tickets = book.tickets
    guard started, !tickets.isEmpty else {
      ranking = false
      then?(false)
      return
    }
    rankRun?.cancel()
    ranking = true
    rankError = nil
    rankRun = ClaudeOneShot.run(
      arguments: TicketPrompts.arguments(tools: [], model: nil),
      prompt: TicketRanking.prompt(tickets: tickets, evidence: evidence(), instructions: prefs.rankingPrompt,
                                   now: Date()),
      folder: nil, timeout: TicketRanking.timeout
    ) { [weak self] reply in
      guard let self else { return }
      self.rankRun = nil
      self.ranking = false
      switch reply {
      case .success(let text):
        guard let rank = TicketRanking.parse(text, tickets: tickets, at: Date()) else {
          if !retried { return self.rank(retried: true, then: then) }
          self.rankError = "Claude's order couldn't be read, so this is the plain order."
          then?(false)
          return
        }
        self.mutate { $0.rank = rank }
        then?(true)
      case .failure(let failure):
        self.rankError = failure.message
        if TicketPrompts.isUsageLimit(failure.message) { self.pausedUntil = Date().addingTimeInterval(3600) }
        then?(false)
      }
    }
  }

  /// What Glance saw per ticket, for the rank: pending suggestions' evidence and today's activity.
  public func evidence() -> [String: [String]] {
    var seen: [String: [String]] = [:]
    for suggestion in book.suggestions.pending { seen[suggestion.ticketID, default: []].append(suggestion.evidence) }
    for (id, date) in book.activity where Calendar.current.isDateInToday(date) {
      seen[id, default: []].append("worked on today")
    }
    return seen
  }

  // MARK: The day

  /// Seconds since the last keyboard or mouse input anywhere.
  static func idleSeconds() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
  }

  /// Do not disturb, or a meeting under way: the daily cards wait for the next activity after.
  private var quiet: Bool {
    NotificationHub.shared.prefs.doNotDisturb || NotificationHub.shared.isInMeeting()
  }

  private func ticked() {
    guard started else { return }
    ticks += 1
    // Every 5 minutes (and on the first tick): commits, branches, pull requests and quiet tickets.
    if ticks % 5 == 1 { scanSignals() }
    let now = Date(), calendar = Calendar.current
    if !quiet, TicketSchedule.morningDue(now: now, prefs: prefs, lastDay: book.lastMorning,
                                         idle: Self.idleSeconds(), calendar: calendar) {
      mutate { $0.lastMorning = TicketSchedule.dayKey(now, calendar: calendar) }
      morning()
    }
    if !quiet, TicketSchedule.checkInDue(now: now, prefs: prefs, lastDay: book.lastCheckIn,
                                         idle: Self.idleSeconds(), calendar: calendar) {
      mutate { $0.lastCheckIn = TicketSchedule.dayKey(now, calendar: calendar) }
      checkIn()
    }
  }

  /// The morning card: yesterday's order marked "updating…" at once, then the new order after a fetch and rank.
  public func morning() {
    let show = { [weak self] (updating: Bool) in
      guard let self else { return }
      let top = Array(TicketRanking.arrange(self.book.tickets, rank: self.book.rank).today.prefix(3))
      guard !top.isEmpty else { return }
      TicketsCard.shared.showMorning(top: top, summary: self.book.rank?.summary ?? "", updating: updating)
    }
    show(true)
    rerank { [weak self] _ in
      guard let self else { return }
      show(false)
      let top = Array(TicketRanking.arrange(self.book.tickets, rank: self.book.rank).today.prefix(3))
      if !top.isEmpty {
        self.post(TicketNotices.morning(summary: self.book.rank?.summary ?? "", keys: top.map(\.ticket.key),
                                        at: Date()))
      }
      if self.prefs.readAloud, !top.isEmpty {
        NudgeVoice.shared.say(TicketRanking.spoken(top: top, summary: self.book.rank?.summary ?? "",
                                                    name: NudgeVoice.name))
      }
    }
  }

  /// Fetches every enabled tracker (or only `tracker`); `then` runs when all have answered.
  public func refresh(_ tracker: String? = nil, then: (() -> Void)? = nil) {
    guard started else { return }
    if let until = pausedUntil, until > Date() { then?(); return }
    pausedUntil = nil
    // With no tracker at all, ask Claude Code again: one may have been signed in since.
    ConnectorProbe.shared.check(force: allTrackers.isEmpty) { [weak self] in
      guard let self else { return }
      let trackers = self.enabledTrackers.filter { tracker == nil || $0.server == tracker }
      guard !trackers.isEmpty else { then?(); return }
      var left = trackers.count
      for item in trackers {
        self.fetch(item) {
          left -= 1
          guard left == 0 else { return }
          // New tickets may match work already seen.
          if tracker == nil { self.scanSignals() }
          then?()
        }
      }
    }
  }

  /// One fetch; an answer that isn't the JSON asked for is retried once (spec "Errors"). A fetch already running for
  /// the tracker is joined, not replaced; `done` runs when it answers.
  private func fetch(_ tracker: Tracker, retried: Bool = false, done: @escaping () -> Void) {
    let server = tracker.server
    if !retried {
      let running = fetchRuns[server] != nil || directRuns[server] != nil
      fetchWaiters[server, default: []].append(done)
      if running { return }
    }
    if tracker.kind == .glance { return fetchDirect(tracker) }
    states[server] = .fetching
    fetchRuns[server] = ClaudeOneShot.run(
      arguments: TicketPrompts.arguments(tools: tracker.readTools, model: "haiku",
                                         otherServers: otherServers(than: tracker)),
      prompt: TicketPrompts.fetchPrompt(tracker, query: prefs.query(for: server), now: Date()),
      folder: nil, timeout: TicketPrompts.fetchTimeout, environment: TrackerProbe.waitForConnectors
    ) { [weak self] reply in
      guard let self else { return }
      self.fetchRuns[server] = nil
      let parsed = reply.mapError { TicketFailure(message: $0.message) }
        .flatMap { TicketPrompts.tickets(from: $0, tracker: server) }
      switch parsed {
      case .success(let tickets):
        let covered = self.covered
        self.mutate {
          $0.merge(tickets, tracker: server, at: Date())
          $0.dropCovered(hosts: covered.hosts, keep: covered.keep)
        }
        self.states[server] = .idle
      case .failure(let failure) where failure.message == TicketPrompts.notJSON && !retried:
        return self.fetch(tracker, retried: true, done: {})
      case .failure(let failure):
        self.states[server] = .failed(failure.message)
        if TicketPrompts.isUsageLimit(failure.message) { self.pausedUntil = Date().addingTimeInterval(3600) }
        // A connector whose tools changed: ask Claude Code again which it has.
        if failure.message.lowercased().contains("tool") { ConnectorProbe.shared.check(force: true) }
      }
      self.finishFetch(server)
    }
  }

  private func finishFetch(_ server: String) {
    let waiters = fetchWaiters.removeValue(forKey: server) ?? []
    waiters.forEach { $0() }
  }

  /// A Glance site's fetch: Jira over REST, no Claude run.
  private func fetchDirect(_ tracker: Tracker) {
    let server = tracker.server
    guard let direct else { return finishFetch(server) }
    states[server] = .fetching
    let query = prefs.query(for: server)
    directRuns[server] = Task { [weak self] in
      let result = await direct.fetch(tracker, query: query)
      guard let self, !Task.isCancelled else { return }
      self.directRuns[server] = nil
      switch result {
      case .success(let tickets):
        let covered = self.covered
        self.mutate {
          $0.merge(tickets, tracker: server, at: Date())
          $0.dropCovered(hosts: covered.hosts, keep: covered.keep)
        }
        self.states[server] = .idle
      case .failure(let failure):
        self.states[server] = .failed(failure.message)
      }
      self.finishFetch(server)
    }
  }

  func mutate(_ change: (inout TicketBook) -> Void) {
    change(&book)
    guard !saveScheduled else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.saveScheduled = false
        TicketStore.save(self.book)
      }
    }
  }
}
