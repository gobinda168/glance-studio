import AppKit
import Combine
import Foundation
import GlanceCore

/// What the engine is doing, line by line: every run log line as it is written, and its own notes (a dropped queued
/// run, a skipped watcher line, a catch-up). `glance automation run|serve` prints it; A3's views can follow it.
public enum AutomationActivity: Equatable, Sendable {
  case logged(AutomationRunRef, RunLogEvent)
  case note(automation: String, String)
}

/// What `AutomationEngine.approve` did.
public enum AutomationApproveResult: Equatable, Sendable {
  case approved
  /// Its permissions or triggers on disk are not the ones the caller showed: nothing was approved.
  case changedSinceShown
  /// It doesn't read or has problems.
  case broken
  /// A restore of it is going.
  case restoring
  /// The approval couldn't be written.
  case notSaved
}

/// The automation engine (spec 2026-10-09-automations-design.md, "The runtime"): the library and its approvals, runs
/// with a queue per automation, parked approvals and failures as Notifications cards, and the triggers of every armed
/// automation. Studio makes one at launch when `Feature.automations` is on; `glance automation run|serve` makes their
/// own. A3 (the Studio UI) and A4 (the MCP socket) build on the public API below.
@MainActor
public final class AutomationEngine: ObservableObject {
  public static let shared = AutomationEngine(library: .standard)

  public let library: AutomationLibrary
  /// Every package, by id.
  @Published public private(set) var entries: [AutomationEntry] = []
  /// Runs going now (parked ones too), oldest first.
  @Published public private(set) var live: [AutomationLiveRun] = []
  /// The side bar's "Needs you".
  @Published public private(set) var needs: [AutomationNeed] = []
  public let activity = PassthroughSubject<AutomationActivity, Never>()
  /// `glance automation run --approve-outward`: parked steps approve themselves.
  public var approvesOutward = false
  /// Cards in the Notifications inbox (off in the CLI, which prints instead).
  public var postsNotices = true
  /// The failure card's Open run (A3 opens the automation tab on Runs).
  public var onOpenRun: ((AutomationRunRef) -> Void)?
  /// The failure card's Ask Claude to fix (A4 opens the builder tab with the run's log).
  public var onAskClaude: ((AutomationRunRef) -> Void)?
  /// The side bar's New automation (A4 opens the builder tab). nil until A4: the button shows, switched off.
  public var onNewAutomation: (() -> Void)?
  /// Edit with Claude on a side bar row and in Setup (A4 opens the builder tab on that automation).
  public var onEditWithClaude: ((String) -> Void)?

  private struct Pending {
    var inputs: [String: AutomationValue]
    var fire: AutomationFire
  }

  private let bus: GlanceEventBus
  private var approvals = AutomationApprovalBook()
  private var sessions: [AutomationRunRef: AutomationRunSession] = [:]
  private var queues: [String: AutomationRunQueue<Pending>] = [:]
  private var brokenWatchers: [String: String] = [:]
  /// Open automation tabs and the manual runs whose approval shows in one (A3).
  private var inline = AutomationInlineBook()
  private var folderWatcher: FolderWatcher?
  private var triggers: AutomationTriggers?
  private var quitWatch: NSObjectProtocol?
  private var started = false
  /// Automations a restore is rewriting on disk: their entries stay as they were, and runs, saves, deletes and
  /// approvals wait until it lands.
  private var restoring: Set<String> = []
  /// approvals.json as the engine last read or wrote it: a change on disk that differs is another process's.
  private var approvalsOnDisk: Data?
  /// When each automation's last run ended: files triggers ignore changes that arrive just after, which were that
  /// run's own writes still on their way through FSEvents.
  private var lastEnded: [String: Date] = [:]
  static let fileEventsLag: TimeInterval = 1

  /// `bus`: Glance's shared one unless given (the CLI's one-off run uses its own).
  public init(library: AutomationLibrary, bus: GlanceEventBus? = nil) {
    self.library = library
    self.bus = bus ?? .shared
  }

  // MARK: Start and stop

  /// Makes the library (git) if needed, prunes old run logs, loads everything, watches the folder, and arms the
  /// triggers (`triggers: false` for a one-off run).
  public func start(triggers armTriggers: Bool = true) {
    guard !started else { return }
    started = true
    library.prepare()
    library.prune(now: Date())
    approvalsOnDisk = library.approvalsData()
    approvals = library.loadApprovals()
    folderWatcher = FolderWatcher(path: library.realPath, debounce: 0.5) { [weak self] paths in
      self?.libraryChanged(paths)
    }
    if armTriggers { triggers = AutomationTriggers(engine: self, library: library, bus: bus) }
    // Scripts and watchers run in process groups of their own: nothing else ends them when Studio quits.
    quitWatch = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
    reload()
  }

  /// Disarms everything and cancels the runs going (Studio quitting, or the feature switched off).
  public func stop() {
    guard started else { return }
    started = false
    triggers?.disarmAll()
    triggers = nil
    folderWatcher?.stop()
    folderWatcher = nil
    if let quitWatch { NotificationCenter.default.removeObserver(quitWatch) }
    quitWatch = nil
    for queue in queues.keys { queues[queue]?.removeAll() }
    sessions.values.filter { !$0.isNested }.forEach { $0.cancel() }
  }

  /// Reads the library again and re-arms (a save, a hand edit, an approval).
  public func reload() {
    let calls = library.calls()
    let before = entries
    var read: [AutomationEntry] = library.ids().compactMap { id in
      // A restore moves the package aside while it works: what's on disk now isn't the automation.
      if restoring.contains(id) { return before.first { $0.id == id } }
      let loaded = library.load(id, calls: calls)
      let record = approvals.record(id)
      return AutomationEntry(id: id, manifest: loaded.manifest, problems: loaded.problems, readme: loaded.readme,
                             approval: loaded.manifest.map { approvals.status(of: $0) } ?? .never,
                             enabled: record.enabled, trusted: record.trusted,
                             lastRun: library.runs(id, limit: 1, live: liveRuns(id)).first,
                             brokenWatcher: brokenWatchers[id])
    }
    for id in restoring where !read.contains(where: { $0.id == id }) {
      if let index = before.firstIndex(where: { $0.id == id }) {
        read.insert(before[index], at: min(index, read.count))
      }
    }
    entries = read
    refreshNeeds()
    triggers?.arm(entries.filter(\.armed).compactMap(\.manifest), brokenWatchers: Set(brokenWatchers.keys))
  }

  public func entry(_ id: String) -> AutomationEntry? { entries.first { $0.id == id } }

  private func libraryChanged(_ paths: [String]) {
    let root = library.realPath
    let approvalsChanged = paths.contains("\(root)/\(AutomationApprovalBook.fileName)") && adoptApprovalsOnDisk()
    guard approvalsChanged || paths.contains(where: { AutomationLibraryLayout.package(ofChange: $0, root: root) != nil })
    else { return }
    reload()
  }

  /// Takes approvals.json again when another process (`glance automation enable|approve|trust`, the MCP) wrote it.
  /// False when the file is what the engine last read or wrote.
  @discardableResult
  private func adoptApprovalsOnDisk() -> Bool {
    let data = library.approvalsData()
    guard data != approvalsOnDisk else { return false }
    approvals = library.loadApprovals()
    approvalsOnDisk = library.approvalsData()
    return true
  }

  // MARK: Runs

  /// Runs an automation now (or queues it behind its run going). Manual runs need it valid and approved, like every
  /// run; `inputs` go over the defaults (and over a trigger's own inputs).
  @discardableResult
  public func run(_ id: String, inputs: [String: AutomationValue] = [:],
                  fire: AutomationFire = .manual) -> AutomationRunStart {
    guard let entry = entry(id) else { return .refused("There's no automation `\(id)`.") }
    guard !restoring.contains(id) else { return .refused("\(entry.name) is being restored. Try again in a moment.") }
    guard let manifest = entry.manifest, entry.problems.isEmpty else {
      return .refused("\(entry.name) is broken: \(entry.problems.first?.description ?? "automation.json doesn't read")")
    }
    guard entry.approval.isApproved else { return .refused("Approve \(entry.name) first.") }
    let resolved = fire.inputs(for: manifest, given: inputs)
    guard resolved.problems.isEmpty else { return .refused(AutomationCheck.report(resolved.problems)) }
    if isRunning(id) {
      var queue = queues[id] ?? AutomationRunQueue()
      if let dropped = queue.push(Pending(inputs: inputs, fire: fire)) {
        note(id, "dropped a queued run from \(dropped.fire.summary): more than \(queue.limit) were waiting")
      }
      queues[id] = queue
      return .queued(queue.count)
    }
    guard let session = begin(entry, manifest, inputs: resolved.values, fire: fire, nested: false) else {
      return .refused("Couldn't start a run log for \(entry.name).")
    }
    return .started(session.ref)
  }

  /// Whether a change to `id`'s watched folder that just reached us was probably its own run's doing: the run is going,
  /// or ended a moment ago (FSEvents reports a change a little after it happened).
  func madeByOwnRun(_ id: String) -> Bool {
    if isRunning(id) { return true }
    return lastEnded[id].map { Date().timeIntervalSince($0) < Self.fileEventsLag } ?? false
  }

  /// A trigger fired: run, or say why not on a card. Not when the automation was switched off since the trigger
  /// queued (a bus delivery, a debounce).
  func fire(_ id: String, _ fire: AutomationFire) {
    guard entry(id)?.enabled == true else {
      note(id, "ignored \(fire.summary): it's switched off")
      return
    }
    guard !restoring.contains(id) else {
      note(id, "ignored \(fire.summary): it's being restored")
      return
    }
    note(id, "fired by \(fire.summary)")
    guard case .refused(let reason) = run(id, fire: fire) else { return }
    note(id, "didn't start: \(reason)")
    guard postsNotices, let entry = entry(id) else { return }
    NotificationHub.shared.post(AutomationNotices.couldNotStart(
      name: entry.name, automation: id, trigger: fire.summary,
      problems: [AutomationProblem("", reason)], date: Date()))
  }

  /// A run of `id` going (not counting nested ones).
  public func isRunning(_ id: String) -> Bool {
    sessions.values.contains { $0.ref.automation == id && !$0.isNested }
  }

  public func cancel(_ ref: AutomationRunRef) {
    sessions[ref]?.cancel()
  }

  /// The user's answer to a run's question (the orb's card, the agent page). False when the run no longer waits on
  /// one (answered elsewhere, cancelled, expired).
  @discardableResult
  public func answer(_ ref: AutomationRunRef, _ answer: AutomationAnswer) -> Bool {
    guard let session = sessions[ref], session.question != nil else { return false }
    inline.settled(ref)
    if postsNotices { NotificationHub.shared.markDone(threadKey: AutomationNotices.threadKey(ref)) }
    session.answer(answer)
    refreshLive()
    return true
  }

  /// The question a run waits on.
  public func question(_ ref: AutomationRunRef) -> AutomationQuestion? { sessions[ref]?.question }

  /// Approve / Skip / Trust at a parked step (the card, the tab, the MCP).
  public func decide(_ ref: AutomationRunRef, _ decision: RunRecord.Decision) {
    inline.settled(ref)
    if postsNotices { NotificationHub.shared.markDone(threadKey: AutomationNotices.threadKey(ref)) }
    guard let session = sessions[ref], session.parkedPlan != nil else {
      // Trust from a card whose run already ended or expired still trusts the automation.
      if decision == .trust, entry(ref.automation) != nil { setTrusted(ref.automation, true) }
      return
    }
    session.decide(decision)
    refreshLive()
  }

  /// Makes the run's log and folder and starts it. `onEnd` is set before the first step so a run that ends at once
  /// (every step skipped) is still heard.
  private func begin(_ entry: AutomationEntry, _ manifest: AutomationManifest, inputs: [String: AutomationValue],
                     fire: AutomationFire, nested: Bool,
                     onEnd: ((AutomationRunSession) -> Void)? = nil) -> AutomationRunSession? {
    guard let made = library.newRun(manifest.id, start: Date()) else { return nil }
    let home = NSHomeDirectory()
    let setup = AutomationRunMachine.Setup(
      manifest: manifest, inputs: inputs, fire: fire, runDirectory: made.directory.path,
      automationDirectory: library.folder(manifest.id).path, home: home, texts: library.texts(for: manifest),
      trusted: entry.trusted)
    let profile = SandboxProfile.make(permissions: manifest.permissions, runDirectory: made.directory.path,
                                      stateDirectory: library.stateDirectory, home: home)
    let session = AutomationRunSession(ref: made.ref, name: entry.name, setup: setup, log: made.log, profile: profile,
                                       isNested: nested, engine: self)
    sessions[made.ref] = session
    session.onEnd = { [weak self] ended in
      onEnd?(ended)
      self?.ended(ended)
    }
    refreshLive()
    session.start()
    return session
  }

  /// An `automation` step: the callee runs under its own approval; its last step's output is the step's. `done`
  /// always arrives on a later turn of the run loop, never inside this call.
  func startNested(_ callee: String, inputs: [String: AutomationValue], caller: AutomationRunSession,
                   done: @escaping @MainActor (AutomationStepResult) -> Void) -> AutomationRunSession? {
    func report(_ result: AutomationStepResult) {
      DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
    }
    func fail(_ text: String) -> AutomationRunSession? {
      report(AutomationStepResult(status: .failed, text: text))
      return nil
    }
    guard let entry = entry(callee), let manifest = entry.manifest, entry.problems.isEmpty else {
      return fail("There's no working automation `\(callee)`.")
    }
    guard entry.approval.isApproved else { return fail("Approve \(entry.name) first.") }
    let resolved = AutomationFire.nested(caller: caller.ref.automation).inputs(for: manifest, given: inputs)
    guard resolved.problems.isEmpty else { return fail(AutomationCheck.report(resolved.problems)) }
    let started = Date()
    let session = begin(entry, manifest, inputs: resolved.values, fire: .nested(caller: caller.ref.automation),
                        nested: true) { ended in
      let durationMs = Int(Date().timeIntervalSince(started) * 1000)
      switch ended.status {
      case .ok:
        let output = ended.lastOutput ?? AutomationStepOutput(text: "")
        report(AutomationStepResult(status: .ok, text: output.text, json: output.json, durationMs: durationMs))
      case .cancelled:
        report(AutomationStepResult(status: .cancelled, text: "", durationMs: durationMs))
      default:
        let at = ended.failedStep.map { " at \($0)" } ?? ""
        let why = ended.failureText.map { ":\n\($0)" } ?? ""
        report(AutomationStepResult(status: .failed, text: "\(entry.name) \(ended.status.rawValue)\(at)\(why)",
                                    durationMs: durationMs))
      }
    }
    return session ?? fail("Couldn't start a run log for \(entry.name).")
  }

  func parked(_ session: AutomationRunSession, _ plan: AutomationStepPlan) {
    refreshLive()
    if approvesOutward {
      note(session.ref.automation, "approving \(plan.step) (--approve-outward)")
      DispatchQueue.main.async { MainActor.assumeIsolated { self.decide(session.ref, .approve) } }
      return
    }
    guard postsNotices else { return }
    // A manual run of an automation whose tab is open asks in the tab, not on a card (A3).
    if inline.parked(session.ref, manual: session.fire == .manual) { return }
    NotificationHub.shared.post(AutomationNotices.parked(name: session.name, ref: session.ref, plan: plan,
                                                         date: Date()))
  }

  /// An ask step put its question: Studio shows it (it watches `live`). A run without Studio to answer it (the CLI's
  /// one-off run) is told so by its caller.
  func asked(_ session: AutomationRunSession, _ question: AutomationQuestion) {
    refreshLive()
    note(session.ref.automation, "asking: \(question.question)")
    guard postsNotices else { return }
    // A manual run of an agent whose tab is open asks in the tab, not on a card.
    if inline.parked(session.ref, manual: session.fire == .manual) { return }
    NotificationHub.shared.post(AutomationNotices.asked(name: session.name, ref: session.ref, question: question,
                                                        date: Date()))
  }

  private func ended(_ session: AutomationRunSession) {
    inline.settled(session.ref)
    sessions[session.ref] = nil
    let id = session.ref.automation
    if !session.isNested { lastEnded[id] = Date() }
    if postsNotices {
      NotificationHub.shared.markDone(threadKey: AutomationNotices.threadKey(session.ref))
      if !session.isNested, [.failed, .expired].contains(session.status) {
        NotificationHub.shared.post(AutomationNotices.failed(
          name: session.name, ref: session.ref, step: session.failedStep,
          output: session.failureText ?? session.stepOutput,
          status: session.status, date: Date()))
      }
    }
    if let index = entries.firstIndex(where: { $0.id == id }) {
      entries[index].lastRun = library.runs(id, limit: 1, live: liveRuns(id)).first
    }
    refreshLive()
    guard !session.isNested else { return }
    // A queued run that is refused (approval revoked, manifest broken) mustn't strand the ones behind it.
    while let next = queues[id]?.pop() {
      if next.fire != .manual, entry(id)?.enabled != true {
        note(id, "a queued run from \(next.fire.summary) didn't start: it's switched off")
        continue
      }
      switch run(id, inputs: next.inputs, fire: next.fire) {
      case .refused(let reason): note(id, "a queued run from \(next.fire.summary) didn't start: \(reason)")
      case .started, .queued: return
      }
    }
  }

  func logged(_ ref: AutomationRunRef, _ event: RunLogEvent) {
    switch event {
    case .stepStart, .stepEnd, .runPark, .runResume, .runAsk, .runAnswer: refreshLive()  // `live[].step` follows the run
    default: break
    }
    activity.send(.logged(ref, event))
  }

  func note(_ id: String, _ text: String) {
    activity.send(.note(automation: id, text))
  }

  /// A watcher gave up: it stays off (and shows under Needs you) until the automation is switched on again.
  func watcherBroke(_ id: String, stderr: String) {
    brokenWatchers[id] = stderr
    note(id, "watcher stopped after \(WatcherBackoff.crashLimit) crashes in 10 minutes")
    if postsNotices, let entry = entry(id) {
      NotificationHub.shared.post(AutomationNotices.watcherBroken(name: entry.name, automation: id, stderr: stderr,
                                                                  date: Date()))
    }
    reload()
  }

  private func liveRuns(_ id: String) -> Set<String> {
    Set(sessions.keys.filter { $0.automation == id }.map(\.run))
  }

  private func refreshLive() {
    live = sessions.values.map { session in
      AutomationLiveRun(ref: session.ref, name: session.name, trigger: session.fire.summary,
                        startedAt: session.startedAt, step: session.currentStep,
                        parked: session.parkedPlan != nil || session.question != nil, question: session.question)
    }.sorted { $0.startedAt < $1.startedAt }
    refreshNeeds()
  }

  private func refreshNeeds() {
    needs = AutomationNeed.make(entries, live: live)
  }

  // MARK: Agent memory and messages (spec 2026-10-12-agent-memory-design.md)

  /// state/<id>.memory.md: what the agent wrote down in earlier runs (outside git, with the rest of the state).
  func memoryFile(_ id: String) -> URL {
    URL(fileURLWithPath: library.stateDirectory).appendingPathComponent("\(id).memory.md")
  }

  /// What the agent remembers; empty when nothing yet.
  public func memory(_ id: String) -> String {
    (try? String(contentsOf: memoryFile(id), encoding: .utf8)) ?? ""
  }

  /// Forgets everything the agent remembered.
  public func clearMemory(_ id: String) {
    try? FileManager.default.removeItem(at: memoryFile(id))
    objectWillChange.send()
  }

  /// The words before an agent's Claude steps: its memory and the other agents it can message. Nil for anything but
  /// an agent.
  func agentPreface(for id: String) -> String? {
    guard let manifest = entry(id)?.manifest, manifest.isAgent else { return nil }
    let peers = entries.compactMap { entry -> AgentNotes.Peer? in
      guard entry.id != id, !entry.isBroken, let other = entry.manifest, other.isAgent else { return nil }
      return AgentNotes.Peer(id: entry.id, name: other.name, description: other.description)
    }
    return AgentNotes.preface(memory: memory(id), peers: peers)
  }

  /// An agent's Claude step answered: what it asked to remember is kept, and what it sent goes to the agents named
  /// (that exist and aren't itself) as `agent.message` events, at most `maxSends` and `maxHops` hops deep.
  func agentSaid(_ session: AutomationRunSession, _ text: String) {
    let id = session.ref.automation
    guard entry(id)?.manifest?.isAgent == true else { return }
    let found = AgentNotes.extract(text)
    if !found.memories.isEmpty {
      let day = Self.dayFormat.string(from: Date())
      let merged = AgentNotes.merged(memory: memory(id), adding: found.memories, on: day)
      try? FileManager.default.createDirectory(atPath: library.stateDirectory, withIntermediateDirectories: true)
      do {
        try merged.write(to: memoryFile(id), atomically: true, encoding: .utf8)
        note(id, "remembered \(found.memories.count) thing\(found.memories.count == 1 ? "" : "s")")
      } catch {
        note(id, "couldn't save its memory: \(error.localizedDescription)")
      }
    }
    let hops = AgentNotes.hops(of: session.fire.payload ?? .null) + 1
    for message in found.messages.prefix(AgentNotes.maxSends) {
      guard message.to != id, entry(message.to)?.manifest?.isAgent == true else {
        note(id, "tried to message `\(message.to)`, which isn't an agent here")
        continue
      }
      guard hops <= AgentNotes.maxHops else {
        note(id, "didn't pass its message to \(message.to) on: \(AgentNotes.maxHops) agents deep already")
        continue
      }
      bus.publish(.agentMessage(from: id, to: message.to, text: message.text, hops: hops))
      note(id, "messaged \(message.to)")
    }
  }

  private static let dayFormat: DateFormatter = {
    let format = DateFormatter()
    format.dateFormat = "yyyy-MM-dd"
    format.locale = Locale(identifier: "en_US_POSIX")
    return format
  }()

  // MARK: The automation tab (A3)

  /// An automation tab shows `id`: its manual runs' approvals show in the tab instead of on a card.
  public func tabOpened(_ id: String) {
    inline.opened(id)
  }

  /// One of `id`'s tabs closed; when it was the last, a manual run still waiting gets its card after all.
  public func tabClosed(_ id: String) {
    for ref in inline.closed(id) {
      guard postsNotices, let session = sessions[ref] else { continue }
      if let plan = session.parkedPlan {
        NotificationHub.shared.post(AutomationNotices.parked(name: session.name, ref: ref, plan: plan, date: Date()))
      } else if let question = session.question {
        NotificationHub.shared.post(AutomationNotices.asked(name: session.name, ref: ref, question: question,
                                                            date: Date()))
      }
    }
  }

  /// The step a run waits at, for the tab's inline approval (its command and stdin preview).
  public func parkedPlan(_ ref: AutomationRunRef) -> AutomationStepPlan? {
    sessions[ref]?.parkedPlan
  }

  /// glance.state's file for `id`: state/<id>.json in the library (outside git).
  public func stateFile(_ id: String) -> URL {
    URL(fileURLWithPath: library.stateDirectory).appendingPathComponent("\(id).json")
  }

  // MARK: Approval and switches

  /// Writes approvals.json. A write that fails is an engine note, and the book goes back to what is on disk so the
  /// side bar never shows an approval that didn't stick.
  @discardableResult
  private func persistApprovals(_ id: String) -> Bool {
    guard library.saveApprovals(approvals) else {
      note(id, "couldn't write \(AutomationApprovalBook.fileName)")
      approvals = library.loadApprovals()
      approvalsOnDisk = library.approvalsData()
      return false
    }
    approvalsOnDisk = library.approvalsData()
    return true
  }

  /// Approves the version on disk (its permissions and triggers); its triggers arm when it's enabled. `hash` is the
  /// `AutomationApproval.hash` of the manifest the caller showed the user: when what's on disk now hashes differently
  /// (a hand edit, a save, a restore since), nothing is approved, the engine reads the library again and the caller
  /// shows the new lines. nil approves whatever is on disk.
  @discardableResult
  public func approve(_ id: String, expecting hash: String? = nil) -> AutomationApproveResult {
    guard !restoring.contains(id) else { return .restoring }
    let loaded = library.load(id, calls: library.calls())
    guard let manifest = loaded.manifest, let text = loaded.manifestText, loaded.problems.isEmpty else {
      reload()
      return .broken
    }
    if let hash, hash != AutomationApproval.hash(manifest) {
      reload()
      return .changedSinceShown
    }
    adoptApprovalsOnDisk()
    approvals.approve(manifest, manifestText: text)
    let saved = persistApprovals(id)
    reload()
    return saved ? .approved : .notSaved
  }

  public func setTrusted(_ id: String, _ on: Bool) {
    adoptApprovalsOnDisk()
    approvals.setTrusted(id, on)
    persistApprovals(id)
    reload()
  }

  /// The form's Save: the edited fields become the automation's settings (AutomationSettings), and its watchers
  /// restart with them. False when a field is wrong or settings.json couldn't be written.
  public func saveSettings(_ id: String, edited: [String: String]) -> Bool {
    guard let manifest = entry(id)?.manifest,
          let settings = library.loadSettings().saving(manifest, fields: AutomationFormModel.fields(manifest),
                                                       edited: edited),
          library.saveSettings(settings) else { return false }
    reload()
    return true
  }

  /// Switching it on also clears a broken watcher.
  public func setEnabled(_ id: String, _ on: Bool) {
    adoptApprovalsOnDisk()
    approvals.setEnabled(id, on)
    persistApprovals(id)
    if on { brokenWatchers[id] = nil }
    reload()
  }

  /// The Setup page's lines: what changed since the approval (a trigger-only change reads "Changes its triggers"),
  /// or what approving allows.
  public func approvalLines(_ id: String) -> [String] {
    guard let entry = entry(id), let manifest = entry.manifest else { return [] }
    if case .changed(let lines) = entry.approval { return lines }
    return AutomationApproval.summary(manifest)
  }

  // MARK: The library

  public func runs(_ id: String, limit: Int = 50) -> [RunRecord] {
    library.runs(id, limit: limit, live: liveRuns(id))
  }

  public func log(_ ref: AutomationRunRef) -> [RunLogLine] { library.runLines(ref) }

  public func logURL(_ ref: AutomationRunRef) -> URL { library.logURL(ref) }

  public func save(_ id: String, files: [String: String], delete: [String] = [])
    -> Result<AutomationSaved, AutomationSaveError> {
    if restoring.contains(id) { return .failure(.failed("\(id) is being restored. Try again in a moment.")) }
    defer { reload() }
    return library.save(id, files: files, delete: delete)
  }

  /// Brings back the package as it was at `commit`, as a new version. The git work runs off the main thread; while
  /// it does, the automation's entry stays as it was and its runs, saves, deletes and approvals wait (a run going
  /// now makes it refuse). Reads the library once when it lands.
  public func restore(_ id: String, commit: String) async -> Result<AutomationSaved, AutomationSaveError> {
    guard !restoring.contains(id) else { return .failure(.failed("\(id) is already being restored.")) }
    guard !isRunning(id) else { return .failure(.failed("Wait for the run of \(id) to finish, then restore it.")) }
    restoring.insert(id)
    let library = self.library
    let result = await Task.detached(priority: .userInitiated) { library.restore(id, commit: commit) }.value
    restoring.remove(id)
    reload()
    return result
  }

  public func delete(_ id: String) -> Result<AutomationSaved, AutomationSaveError> {
    if restoring.contains(id) { return .failure(.failed("\(id) is being restored. Try again in a moment.")) }
    let result = library.delete(id)
    if case .success = result {
      adoptApprovalsOnDisk()
      approvals.remove(id)
      persistApprovals(id)
      brokenWatchers[id] = nil
      queues[id] = nil
    }
    reload()
    return result
  }

  public func history(_ id: String) -> AutomationHistory { library.history(id) }

  /// Claude steps' cost in [from, to) (the Usage page's "Automations" row, A3).
  public func claudeCost(from: Date, to: Date) -> Double { library.claudeCost(from: from, to: to) }

  // MARK: Cards

  /// The hub's `onAction` for Automations cards.
  public func handle(_ notice: Notice, actionID: String) {
    guard let action = AutomationNotices.Action(rawValue: actionID) else { return }
    let ref = AutomationNotices.ref(notice)
    switch action {
    case .approve: if let ref { decide(ref, .approve) }
    case .skip: if let ref { decide(ref, .skip) }
    case .trust: if let ref { decide(ref, .trust) }
    case .openRun: if let ref { onOpenRun?(ref) }
    case .askClaude: if let ref { onAskClaude?(ref) }
    case .enable: if let id = notice.meta["automation"] { setEnabled(id, true) }
    }
  }
}
