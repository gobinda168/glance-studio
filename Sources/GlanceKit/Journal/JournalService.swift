import AppKit
import GlanceCore
import SwiftUI

/// A day as its page shows it.
public struct JournalDayPage {
  public var record: JournalDayRecord?
  public var events: [JournalEvent]
  public var entries: [JournalEntry]
  public var summary: JournalDaySummary?
}

/// Journal's engine (spec 2026-10-09-journal-design.md). It owns `journal.sqlite`; collects today every 15 minutes,
/// on wake and when asked; catches missed days up at launch; drafts recaps with Claude at the wrap-up time or on Wrap
/// up day, one at a time; shows "Your day is ready"; and carries out every change the Journal pages make. Studio
/// starts it while the Journal feature is on; nothing is collected until journaling is switched on.
@MainActor
public final class JournalService: ObservableObject {
  public static let shared = JournalService()

  public struct Settings: Equatable {
    public var enabled: Bool
    public var sourcesOff: Set<JournalSource>
    public var wrapUp: Bool
    public var wrapUpMinutes: Int
  }

  @Published public private(set) var settings: Settings
  @Published public private(set) var summaries: [JournalDaySummary] = []
  @Published public private(set) var collecting = false
  @Published public private(set) var drafting: Set<JournalDay> = []
  /// Bumped after every change to the store, so an open page reloads.
  @Published public private(set) var revision = 0
  /// Where a damaged journal was moved this launch.
  @Published public private(set) var movedAside: URL?
  /// Why the journal couldn't be opened at all (a newer Glance's journal, a disk error).
  @Published public private(set) var storeError: String?
  @Published public private(set) var claudeInstalled = true

  /// The nudge's Review: Studio opens the Journal tab on that day.
  public var onReview: ((JournalDay) -> Void)?

  public nonisolated static var folder: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glance")
  }

  public var calendar: Calendar { JournalDay.calendar() }
  public var today: JournalDay { JournalDay(Date(), calendar: calendar) }

  private var store: JournalStore?
  private let work = DispatchQueue(label: "dev.glance.journal.work")
  private var featureOn = false
  private var observing = false
  private var tick: Timer?
  private var wrapUpTimer: Timer?
  /// The day the last 15-minute tick collected: when today moves on, yesterday gets one last pass.
  private var tickDay: JournalDay?
  private var pending: Set<JournalDay> = []
  private var waiting: [() -> Void] = []
  private var draftQueue: [(day: JournalDay, announce: Bool)] = []
  private var currentDraft: JournalDay?
  private var runs: [JournalDay: ClaudeOneShot.Run] = [:]
  private var panel: NudgePanel?
  private var helperPass: HelperPass?
  private var collectionID = 0
  private var helperWired = false

  private init() {
    settings = Settings(enabled: Prefs.journalEnabled, sourcesOff: Prefs.journalSourcesOff,
                        wrapUp: Prefs.journalWrapUp, wrapUpMinutes: Prefs.journalWrapUpMinutes)
  }

  // MARK: Lifecycle

  /// The Journal feature is on (launch, or the Develop menu).
  public func start() {
    featureOn = true
    if !observing {
      observing = true
      NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                        queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.woke() }
      }
      ClaudeOneShot.locate { [weak self] path in self?.claudeInstalled = path != nil }
    }
    if !helperWired {
      helperWired = true
      HelperHost.shared.onEvent { event in JournalService.shared.helperSaid(event) }
      HelperHost.shared.onExit { JournalService.shared.helperExited() }
    }
    if HelperHost.shared.isAvailable { HelperHost.shared.start() }
    openStore()
    apply()
  }

  /// The Journal feature went off in the Develop menu: timers stop; drafts under way finish.
  public func stop() {
    featureOn = false
    apply()
  }

  private var active: Bool { featureOn && settings.enabled && store != nil }

  private func openStore() {
    guard store == nil else { return }
    do {
      let opened = try JournalStore.open(url: Self.folder.appendingPathComponent("journal.sqlite"))
      store = opened.store
      movedAside = opened.movedAside
      storeError = nil
      reloadSummaries()
    } catch {
      storeError = "\(error)"
    }
  }

  /// Arms or disarms the timers for the current settings.
  private func apply() {
    guard active else {
      tick?.invalidate()
      tick = nil
      wrapUpTimer?.invalidate()
      wrapUpTimer = nil
      hideNudge()
      return
    }
    if tick == nil {
      tick = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.ticked() }
      }
      ticked()
      catchUp()
    }
    scheduleWrapUp()
    wrapUpIfMissed()
  }

  private func woke() {
    guard active else { return }
    ticked()
    scheduleWrapUp()
    wrapUpIfMissed()
  }

  private func ticked() {
    let today = self.today
    if let previous = tickDay, previous != today {
      collect([previous, today]) { [weak self] in
        self?.withStore({ try $0.setMeta("last_collected_day", previous.key) })
      }
    } else {
      collect([today])
    }
    tickDay = today
  }

  // MARK: Settings

  public func setEnabled(_ on: Bool) {
    settings.enabled = on
    Prefs.journalEnabled = on
    apply()
  }

  public func setSource(_ source: JournalSource, on: Bool) {
    if on { settings.sourcesOff.remove(source) } else { settings.sourcesOff.insert(source) }
    Prefs.journalSourcesOff = settings.sourcesOff
  }

  public func setWrapUp(_ on: Bool) {
    settings.wrapUp = on
    Prefs.journalWrapUp = on
    scheduleWrapUp()
  }

  public func setWrapUpMinutes(_ minutes: Int) {
    settings.wrapUpMinutes = min(max(minutes, 0), 24 * 60 - 1)
    Prefs.journalWrapUpMinutes = settings.wrapUpMinutes
    scheduleWrapUp()
  }

  // MARK: Collecting

  /// Collects `days`, one pass at a time; a request during a pass joins the next. `then` runs after its pass, with
  /// `summaries` already fresh.
  public func collect(_ days: [JournalDay], then: (() -> Void)? = nil) {
    guard active else {
      then?()
      return
    }
    pending.formUnion(days)
    if let then { waiting.append(then) }
    if !collecting { runPass() }
  }

  private func runPass() {
    let days = pending.sorted()
    pending = []
    let callbacks = waiting
    waiting = []
    guard !days.isEmpty else { return }
    collecting = true
    let input = collectorInput(days)
    let finish: (Result<[JournalDaySummary], Error>) -> Void = { [weak self] result in
      guard let self else { return }
      self.collecting = false
      if case .success(let summaries) = result { self.summaries = summaries }
      self.revision += 1
      callbacks.forEach { $0() }
      if !self.pending.isEmpty { self.runPass() }
    }
    // The helper process collects (a crash in a collector restarts it, not the app) and writes the same file; the
    // app reads the summaries once it says so. With the helper down, or if it can't, the app collects itself.
    let local: () -> Void = { [weak self] in
      self?.withStore({ try JournalCollection.run(input, in: $0) }, done: finish)
    }
    if HelperHost.shared.isRunning, store != nil, let json = Self.json(JournalCollectRequest(input)) {
      collectionID &+= 1
      let id = collectionID
      helperPass = HelperPass(id: id, finish: finish, local: local)
      HelperHost.shared.send(.journalCollect(id: id, json: json))
    } else {
      local()
    }
  }

  private struct HelperPass {
    var id: Int
    var finish: (Result<[JournalDaySummary], Error>) -> Void
    var local: () -> Void
  }

  private static func json(_ request: JournalCollectRequest) -> String? {
    (try? JSONEncoder().encode(request)).map { String(decoding: $0, as: UTF8.self) }
  }

  /// What the helper reports: the pass it was asked for is in the store, or it couldn't run.
  private func helperSaid(_ event: HelperWire.Event) {
    guard case .journalCollected(let id, let ok) = event, let pass = helperPass, pass.id == id else { return }
    helperPass = nil
    if ok {
      withStore({ try $0.summaries() }, done: pass.finish)
    } else {
      pass.local()
    }
  }

  /// The helper exited with a pass under way: collect it here.
  private func helperExited() {
    guard let pass = helperPass else { return }
    helperPass = nil
    pass.local()
  }

  private func collectorInput(_ days: [JournalDay]) -> JournalCollector.Input {
    let calendar = self.calendar
    let sources = Set(JournalSource.allCases).subtracting(settings.sourcesOff)
    let first = days.min() ?? today
    let last = days.max() ?? today
    let source = MeetingNudger.shared.calendar
    let allowed = source.access == .allowed
    let meetings = sources.contains(.calendar) && allowed
      ? source.events(from: first.start(in: calendar), to: last.interval(in: calendar).end) : []
    let home = NSHomeDirectory()
    return JournalCollector.Input(
      days: days, calendar: calendar, sources: sources, folders: Prefs.recentProjects.entries.map(\.path),
      repositoryFolders: Prefs.repositoryFolders, meetings: meetings, calendarAllowed: allowed,
      calendarsOff: Set(Prefs.meetingCalendarsOff), home: home,
      claudeProjects: URL(fileURLWithPath: home).appendingPathComponent(".claude/projects"),
      history: Self.folder.appendingPathComponent("history.sqlite"),
      meetingNotes: sources.contains(.calendar) ? MeetingNotesStore.standard.all() : [])
  }

  /// At launch: the days missed since the last collection, then drafts for the past days left without one.
  private func catchUp() {
    let today = self.today
    let calendar = self.calendar
    withStore({ try $0.meta("last_collected_day").flatMap(JournalDay.init(key:)) }) { [weak self] result in
      guard let self else { return }
      let days = JournalSchedule.catchUp(today: today, lastCollected: (try? result.get()) ?? nil, calendar: calendar)
      guard let newest = days.last else { return self.draftMissed() }
      self.collect(days) { [weak self] in
        self?.withStore({ try $0.setMeta("last_collected_day", newest.key) }) { _ in self?.draftMissed() }
      }
    }
  }

  private func draftMissed() {
    for day in JournalSchedule.daysToDraft(summaries, today: today) { enqueueDraft(day, announce: false) }
  }

  // MARK: Wrap-up and drafting

  private func scheduleWrapUp() {
    wrapUpTimer?.invalidate()
    wrapUpTimer = nil
    guard active, settings.wrapUp else { return }
    let fire = JournalSchedule.nextWrapUp(after: Date(), minutes: settings.wrapUpMinutes, calendar: calendar)
    wrapUpTimer = Timer.scheduledTimer(withTimeInterval: max(1, fire.timeIntervalSinceNow), repeats: false) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.wrapUpFired() }
    }
  }

  /// The Mac was asleep (or Studio closed) at the wrap-up time today: wrap up once now.
  private func wrapUpIfMissed() {
    guard active, settings.wrapUp, Prefs.journalLastWrapUpDay != today.key,
          let time = calendar.date(bySettingHour: settings.wrapUpMinutes / 60, minute: settings.wrapUpMinutes % 60,
                                   second: 0, of: Date()), Date() >= time else { return }
    wrapUpFired()
  }

  private func wrapUpFired() {
    let day = today
    Prefs.journalLastWrapUpDay = day.key
    collect([day]) { [weak self] in
      guard let self, JournalSchedule.shouldWrapUp(self.summaries.first(where: { $0.day == day })) else { return }
      self.enqueueDraft(day, announce: true)
    }
    scheduleWrapUp()
  }

  /// Wrap up day: collect once more, then draft.
  public func wrapUp(_ day: JournalDay) {
    collect([day]) { [weak self] in
      guard let self, (self.summaries.first(where: { $0.day == day })?.eventCount ?? 0) > 0 else { return }
      self.enqueueDraft(day, announce: false)
    }
  }

  /// Redraft (the page has already asked, for a reviewed day). Edited entries are kept.
  public func redraft(_ day: JournalDay) {
    enqueueDraft(day, announce: false)
  }

  private func enqueueDraft(_ day: JournalDay, announce: Bool) {
    guard store != nil, !drafting.contains(day) else { return }
    drafting.insert(day)
    draftQueue.append((day, announce))
    nextDraft()
  }

  private func nextDraft() {
    guard currentDraft == nil, !draftQueue.isEmpty else { return }
    let (day, announce) = draftQueue.removeFirst()
    currentDraft = day
    let calendar = self.calendar
    withStore({ store -> (JournalDigest, [JournalEntry], JournalDayRecord) in
      let digest = JournalDigest.make(day: day, calendar: calendar, events: try store.events(on: day))
      return (digest, try store.entries(on: day), try store.record(day) ?? JournalDayRecord(day: day))
    }) { [weak self] result in
      guard let self else { return }
      guard case .success(let (digest, existing, record)) = result, !digest.refs.isEmpty else {
        return self.finishDraft(day)
      }
      self.runs[day] = ClaudeOneShot.run(arguments: JournalRecap.arguments(), prompt: JournalRecap.prompt(digest),
                                         folder: nil, timeout: JournalRecap.timeout) { [weak self] reply in
        self?.received(reply, day: day, digest: digest, existing: existing, record: record, announce: announce)
      }
    }
  }

  private func received(_ reply: Result<String, PullRequestClaude.Failure>, day: JournalDay, digest: JournalDigest,
                        existing: [JournalEntry], record: JournalDayRecord, announce: Bool) {
    runs[day] = nil
    if case .failure(let failure) = reply, failure.kind == .notInstalled { claudeInstalled = false }
    var record = record
    let now = Date()
    let parsed = reply.mapError { JournalRecap.Failure(message: $0.message) }
      .flatMap { JournalRecap.parse($0, day: day, digest: digest, now: now) }
    switch parsed {
    case .success(let draft):
      let closed = AutomationEventSignals.journalClosed(day: day, before: record.status)
      record.status = .drafted
      record.headline = draft.headline
      record.recap = draft.recap
      record.minutesByProject = draft.minutesByProject
      record.generatedAt = now
      record.reviewedAt = nil
      record.error = nil
      let entries = JournalRecap.merge(existing: existing, draft: draft.entries)
      let saved = record
      withStore({ try $0.replaceEntries(on: day, with: entries, record: saved) }) { [weak self] _ in
        guard let self else { return }
        self.changed()
        if let closed { GlanceEventBus.shared.publish(closed) }
        if announce { self.showNudge(day, headline: saved.headline) }
        self.finishDraft(day)
      }
    case .failure(let failure):
      record.status = .failed
      record.error = failure.message
      let saved = record
      withStore({ try $0.save(saved) }) { [weak self] _ in
        self?.changed()
        self?.finishDraft(day)
      }
    }
  }

  private func finishDraft(_ day: JournalDay) {
    drafting.remove(day)
    if currentDraft == day { currentDraft = nil }
    nextDraft()
  }

  // MARK: The nudge

  private func showNudge(_ day: JournalDay, headline: String) {
    let panel = self.panel ?? NudgePanel()
    self.panel = panel
    panel.onAction = { [weak self] action, _ in
      self?.hideNudge()
      if action == .review { self?.onReview?(day) }
    }
    panel.show(Nudge(id: "journal:\(day.key)", dot: GlanceColor.coral, start: Date(), timeRange: "",
                     title: "Your day is ready", meta: headline, actions: [.review], label: "Recap"), arriving: true)
  }

  private func hideNudge() { panel?.hide() }

  // MARK: Reading

  public func load(_ day: JournalDay, done: @escaping (JournalDayPage) -> Void) {
    let summary = summaries.first { $0.day == day }
    withStore({ store in
      JournalDayPage(record: try store.record(day), events: try store.events(on: day),
                     entries: try store.entries(on: day), summary: summary)
    }) { result in
      done((try? result.get()) ?? JournalDayPage(record: nil, events: [], entries: [], summary: summary))
    }
  }

  public func loadInsights(_ range: JournalInsights.Range, done: @escaping (JournalInsights) -> Void) {
    let today = self.today
    let calendar = self.calendar
    withStore({ store -> JournalInsights in
      let records = try store.records()
      let first = records.first?.day ?? today
      return JournalAnalytics.insights(range: range, today: today, records: records,
                                       events: try store.events(from: first, through: today),
                                       entries: try store.entries(from: first, through: today), calendar: calendar,
                                       name: { FolderLabel.name(forPath: $0) })
    }) { result in
      if case .success(let insights) = result { done(insights) }
    }
  }

  /// The side bar's filter: the days whose recap or entries mention `text`; every day when it's blank.
  public func search(_ text: String, done: @escaping ([JournalDay]) -> Void) {
    let query = text.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return done(summaries.map(\.day)) }
    withStore({ try $0.days(matching: query) }) { done((try? $0.get()) ?? []) }
  }

  // MARK: Changes from the pages

  public func addNote(_ text: String) {
    let text = JournalText.clean(text, limit: 2000)
    guard !text.isEmpty else { return }
    let now = Date()
    let note = JournalEvent(source: .note, externalID: UUID().uuidString, day: JournalDay(now, calendar: calendar),
                            start: now, title: text)
    withStore({ try $0.upsert([note]) }) { [weak self] _ in self?.changed() }
  }

  public func updateNote(_ event: JournalEvent, text: String) {
    var note = event
    note.title = JournalText.clean(text, limit: 2000)
    guard !note.title.isEmpty else { return deleteNote(event) }
    withStore({ try $0.upsert([note]) }) { [weak self] _ in self?.changed() }
  }

  public func deleteNote(_ event: JournalEvent) {
    withStore({ try $0.deleteEvent(id: event.id) }) { [weak self] _ in self?.changed() }
  }

  /// An entry the user changed: kept on every redraft from now on.
  public func save(_ entry: JournalEntry) {
    var entry = entry
    entry.edited = true
    entry.updatedAt = Date()
    withStore({ try $0.save(entry) }) { [weak self] _ in self?.changed() }
  }

  public func addEntry(on day: JournalDay) {
    let now = Date()
    withStore({ store in
      let position = try store.entries(on: day).count
      try store.save(JournalEntry(day: day, position: position, title: "New entry", edited: true, createdAt: now))
    }) { [weak self] _ in self?.changed() }
  }

  public func deleteEntry(_ entry: JournalEntry) {
    withStore({ try $0.deleteEntry(id: entry.id) }) { [weak self] _ in self?.changed() }
  }

  public func markReviewed(_ day: JournalDay) {
    withStore({ store in
      guard var record = try store.record(day) else { return }
      record.status = .reviewed
      record.reviewedAt = Date()
      try store.save(record)
    }) { [weak self] _ in self?.changed() }
  }

  public func deleteDay(_ day: JournalDay) {
    runs[day]?.cancel()
    withStore({ try $0.deleteDay(day) }) { [weak self] _ in self?.changed() }
  }

  public func deleteAll() {
    runs.values.forEach { $0.cancel() }
    runs = [:]
    draftQueue = []
    drafting = []
    currentDraft = nil
    Prefs.journalLastWrapUpDay = nil
    withStore({ try $0.deleteAll() }) { [weak self] _ in self?.changed() }
  }

  /// Writes "Glance Journal <today>/journal.json" and "…/markdown/YYYY-MM.md" into `folder`.
  public func export(to folder: URL, done: @escaping (Result<URL, Error>) -> Void) {
    let today = self.today
    let calendar = self.calendar
    withStore({ store -> URL in
      let records = try store.records()
      let first = records.first?.day ?? today
      let events = try store.events(from: first, through: today)
      let entries = try store.entries(from: first, through: today)
      let target = folder.appendingPathComponent("Glance Journal \(today.key)")
      let markdown = target.appendingPathComponent("markdown")
      try FileManager.default.createDirectory(at: markdown, withIntermediateDirectories: true)
      try JournalExport.json(days: records, events: events, entries: entries, exportedAt: Date())
        .write(to: target.appendingPathComponent("journal.json"))
      for (name, text) in JournalExport.markdown(days: records, entries: entries, calendar: calendar,
                                                 name: { FolderLabel.name(forPath: $0) }) {
        try Data(text.utf8).write(to: markdown.appendingPathComponent(name))
      }
      return target
    }, done: done)
  }

  // MARK: Plumbing

  private func changed() {
    revision += 1
    reloadSummaries()
  }

  private func reloadSummaries() {
    withStore({ try $0.summaries() }) { [weak self] result in
      if case .success(let summaries) = result { self?.summaries = summaries }
    }
  }

  /// `body` with the store on the work queue (never the main thread, never the global queues), then `done` on the
  /// main thread.
  private func withStore<T>(_ body: @escaping (JournalStore) throws -> T,
                            done: @escaping (Result<T, Error>) -> Void = { _ in }) {
    guard let store else { return }
    work.async {
      let result = Result { try body(store) }
      DispatchQueue.main.async { done(result) }
    }
  }
}
