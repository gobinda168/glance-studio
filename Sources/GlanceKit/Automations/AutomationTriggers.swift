import AppKit
import Foundation
import GlanceCore

/// The armed automations' triggers (spec "Trigger sources"): one timer for the next schedule fire (with the catch-up
/// at arming and on wake), FSEvents for files triggers, bus subscriptions for event triggers, and watcher processes.
/// `arm` is called with the armed manifests after every reload; a trigger that didn't change keeps running.
@MainActor
final class AutomationTriggers {
  private enum Source {
    case files(FolderWatcher)
    case event(GlanceEventBus.Token)
    case watcher(WatcherRunner)
    case idle
  }

  private struct Armed {
    var signature: String
    var source: Source
  }

  private struct Scheduled {
    var id: String
    var trigger: AutomationTrigger
    var cron: CronSchedule
  }

  private weak var engine: AutomationEngine?
  private let library: AutomationLibrary
  private let bus: GlanceEventBus
  /// Follows the system's time zone and calendar settings.
  private let calendar = Calendar.autoupdatingCurrent
  private var state: AutomationScheduleState
  private var schedules: [String: Scheduled] = [:]
  private var timer: Timer?
  private var armed: [String: Armed] = [:]
  private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
  /// True while schedule-state.json can't be written, so the engine note comes once, not at every fire.
  private var stateUnwritable = false

  init(engine: AutomationEngine, library: AutomationLibrary, bus: GlanceEventBus) {
    self.engine = engine
    self.library = library
    self.bus = bus
    state = library.loadScheduleState()
    // A Mac that slept through a schedule catches up once when it wakes; a new time zone or a set clock moves the
    // next fire.
    let rearm: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.armSchedules() } }
    let workspace = NSWorkspace.shared.notificationCenter
    observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                       queue: .main, using: rearm)))
    let center = NotificationCenter.default
    for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
      observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: rearm)))
    }
  }

  /// Arms exactly these automations' triggers. `brokenWatchers`: automations whose watcher gave up (it stays off
  /// until the user switches the automation on again).
  func arm(_ manifests: [AutomationManifest], brokenWatchers: Set<String>) {
    var wanted: [String: (signature: String, manifest: AutomationManifest, trigger: AutomationTrigger)] = [:]
    var wantedSchedules: [String: Scheduled] = [:]
    for manifest in manifests {
      for (index, trigger) in manifest.triggers.enumerated() {
        let key = "\(manifest.id)#\(index)"
        switch trigger.typed {
        case .schedule:
          guard let cron = trigger.cron, let schedule = try? CronSchedule(parsing: cron) else { continue }
          let scheduleKey = AutomationScheduleState.key(automation: manifest.id, index: index, cron: cron)
          wantedSchedules[scheduleKey] = Scheduled(id: manifest.id, trigger: trigger, cron: schedule)
        case .files, .event:
          wanted[key] = (Self.signature(trigger), manifest, trigger)
        case .watcher where !brokenWatchers.contains(manifest.id):
          // A save (new version), new permissions or new settings (its GLANCE_INPUTS) restart the watcher.
          let inputs = AutomationValue.object(manifest.resolveInputs([:]).values).json
          wanted[key] = ("\(Self.signature(trigger)) v\(manifest.version) \(AutomationApproval.hash(manifest)) \(inputs)",
                         manifest, trigger)
        default:
          continue
        }
      }
    }
    for (key, entry) in armed where wanted[key]?.signature != entry.signature {
      stop(entry.source)
      armed[key] = nil
    }
    for (key, want) in wanted.sorted(by: { $0.key < $1.key }) where armed[key] == nil {
      armed[key] = Armed(signature: want.signature, source: start(want.manifest, want.trigger))
    }
    schedules = wantedSchedules
    armSchedules()
  }

  /// Stops every trigger. Watchers get SIGTERM, then (after up to 3 s, though normally at once) SIGKILL, so none
  /// outlives the engine: the process may be about to exit, and nothing would be left to kill them later.
  func disarmAll() {
    let sources = armed.values.map(\.source)
    sources.forEach { stop($0) }
    let deadline = Date().addingTimeInterval(3)
    for case .watcher(let runner) in sources { runner.waitForExit(until: deadline) }
    armed.removeAll()
    schedules.removeAll()
    timer?.invalidate()
    timer = nil
    observers.forEach { $0.center.removeObserver($0.token) }
    observers.removeAll()
  }

  static func signature(_ trigger: AutomationTrigger) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(trigger)).map { String(decoding: $0, as: UTF8.self) } ?? trigger.summary
  }

  // MARK: Schedules

  /// Records new schedules as armed now, fires the ones that are behind once, then waits for the next fire.
  private func armSchedules() {
    let now = Date()
    for key in state.arm(schedules.mapValues(\.cron), now: now, calendar: calendar) {
      guard let scheduled = schedules[key] else { continue }
      let due = scheduled.cron.previous(atOrBefore: now, calendar: calendar) ?? now
      state.fired(key, at: now)
      engine?.note(scheduled.id, "catching up on \(scheduled.trigger.summary)")
      fire(scheduled, due: due)
    }
    saveState()
    reschedule(after: now)
  }

  private func reschedule(after date: Date) {
    timer?.invalidate()
    timer = nil
    guard let next = AutomationScheduleState.next(schedules.mapValues(\.cron), after: date, calendar: calendar) else {
      return
    }
    let timer = Timer(fire: next.date, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.fired(next.date, keys: next.keys) }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func fired(_ due: Date, keys: [String]) {
    for key in keys {
      guard let scheduled = schedules[key] else { continue }
      state.fired(key, at: due)
      fire(scheduled, due: due)
    }
    saveState()
    reschedule(after: max(Date(), due))
  }

  /// A schedule-state.json that can't be written only costs a catch-up after the next launch: say so once.
  private func saveState() {
    if library.saveScheduleState(state) {
      stateUnwritable = false
    } else if !stateUnwritable {
      stateUnwritable = true
      for id in Set(schedules.values.map(\.id)).sorted() {
        engine?.note(id, "couldn't write \(AutomationLibraryLayout.scheduleStateFile): a missed schedule won't catch up")
      }
    }
  }

  private func fire(_ scheduled: Scheduled, due: Date) {
    let payload = AutomationTriggerMatch.schedulePayload(cron: scheduled.trigger.cron ?? "", at: due)
    engine?.fire(scheduled.id, .trigger(scheduled.trigger, payload: payload))
  }

  // MARK: Files, events, watchers

  private func start(_ manifest: AutomationManifest, _ trigger: AutomationTrigger) -> Source {
    let id = manifest.id
    switch trigger.typed {
    case .files:
      let root = AutomationTriggerMatch.expand(trigger.path ?? "", home: NSHomeDirectory())
      let real = AutomationLibrary.realPath(root)
      var isFolder: ObjCBool = false
      guard FileManager.default.fileExists(atPath: real, isDirectory: &isFolder) else {
        engine?.note(id, "can't watch \(root): it doesn't exist")
        return .idle
      }
      let watched = isFolder.boolValue ? real : (real as NSString).deletingLastPathComponent
      // A step that writes into the folder it watches would start itself again: changes that arrive while it runs
      // (or just after it ended) are its own and are dropped as they arrive, before the debounce.
      let watcher = FolderWatcher(path: watched, debounce: 2, accept: { [weak self] paths in
        let changed = AutomationTriggerMatch.changedPaths(paths, root: real, glob: trigger.glob)
        guard !changed.isEmpty, let engine = self?.engine, engine.madeByOwnRun(id) else { return true }
        engine.note(id, "ignored \(changed.count) change(s) made while it was running")
        return false
      }) { [weak self] paths in
        let changed = AutomationTriggerMatch.changedPaths(paths, root: real, glob: trigger.glob)
        guard !changed.isEmpty else { return }
        self?.engine?.fire(id, .trigger(trigger, payload: AutomationTriggerMatch.filesPayload(changed)))
      }
      guard let watcher else {
        engine?.note(id, "can't watch \(root)")
        return .idle
      }
      return .files(watcher)
    case .event:
      let token = bus.subscribe(trigger.name ?? "") { [weak self] event in
        guard AutomationTriggerMatch.matches(trigger.filter, event.payload) else { return }
        self?.engine?.fire(id, .trigger(trigger, payload: event.payload))
      }
      return .event(token)
    case .watcher:
      guard let engine else { return .idle }
      let runner = WatcherRunner(manifest: manifest, trigger: trigger, library: library, engine: engine)
      runner.start()
      return .watcher(runner)
    default:
      return .idle
    }
  }

  private func stop(_ source: Source) {
    switch source {
    case .files(let watcher): watcher.stop()
    case .event(let token): bus.unsubscribe(token)
    case .watcher(let runner): runner.stop()
    case .idle: break
    }
  }
}

/// A watcher script (spec "Trigger sources", *watcher*): under the automation's sandbox in `.runs/<id>/watcher/`,
/// every `every` (a poll, killed after 5 minutes) or kept alive (streaming). Each stdout line that is a JSON object
/// fires the trigger; other lines are noted and skipped. A crash restarts it with backoff (`WatcherBackoff`); 5
/// crashes in 10 minutes and it is broken.
@MainActor
final class WatcherRunner {
  static let pollTimeout: TimeInterval = 300

  private let id: String
  private let trigger: AutomationTrigger
  private weak var engine: AutomationEngine?
  private let arguments: [String]
  private let environment: [String: String]
  private let directory: String
  private let interval: TimeInterval?
  private var backoff = WatcherBackoff()
  private var process: AutomationProcess?
  private var buffer = WatcherLineBuffer()
  private var stderr = ""
  private var stopped = false
  private var startedAt = Date()
  private var next: DispatchWorkItem?

  init(manifest: AutomationManifest, trigger: AutomationTrigger, library: AutomationLibrary,
       engine: AutomationEngine) {
    id = manifest.id
    self.trigger = trigger
    self.engine = engine
    interval = trigger.every.flatMap(AutomationInterval.parse).map { max($0, AutomationInterval.minimum) }
    let script = library.folder(manifest.id).appendingPathComponent(trigger.script ?? "").path
    let firstLine = library.texts(for: manifest)[trigger.script ?? ""]?
      .split(separator: "\n", maxSplits: 1).first.map(String.init)
    directory = library.root.appendingPathComponent(AutomationLibraryLayout.runsFolder)
      .appendingPathComponent(manifest.id).appendingPathComponent(AutomationLibraryLayout.watcherFolder).path
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let profile = SandboxProfile.make(permissions: manifest.permissions, runDirectory: directory,
                                      stateDirectory: library.stateDirectory, home: NSHomeDirectory())
    arguments = AutomationStepCommand.sandboxed(AutomationStepCommand.scriptLine(path: script, firstLine: firstLine),
                                                profile: profile)
    var environment = ProcessInfo.processInfo.environment
    environment["CLAUDECODE"] = nil
    environment["GLANCE_RUN_DIR"] = directory
    environment["GLANCE_AUTOMATION_DIR"] = library.folder(manifest.id).path
    // The automation's input defaults (its saved settings): a trigger's own `inputs` are templates over a payload
    // that doesn't exist yet.
    environment["GLANCE_INPUTS"] = AutomationValue.object(manifest.resolveInputs([:]).values).json
    self.environment = environment
  }

  func start() { launch() }

  /// SIGTERM to the watcher's group (SIGKILL 3 s later); it won't restart.
  func stop() {
    stopped = true
    next?.cancel()
    process?.terminateGroup()
  }

  /// After `stop`: waits (blocking) for the watcher to exit, up to `deadline`, then SIGKILLs whatever is left of
  /// its group, so nothing outlives a quitting app.
  func waitForExit(until deadline: Date) {
    guard let process else { return }
    while !process.hasExited, Date() < deadline { usleep(20_000) }
    process.killGroup()
  }

  private func launch() {
    guard !stopped else { return }
    startedAt = Date()
    buffer = WatcherLineBuffer()
    let process = AutomationProcess(arguments: arguments, environment: environment, directory: directory)
    self.process = process
    do {
      try process.start(stdin: nil, output: { [weak self] data, isError in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(data, isError: isError, from: process) } }
      }, exit: { [weak self] status in
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(status, process: process) } }
      })
    } catch {
      stderr += "\(error)\n"
      self.process = nil
      return crashed(127)
    }
    guard interval != nil else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.pollTimeout) { [weak self] in
      MainActor.assumeIsolated {
        guard self?.process === process, !process.hasExited else { return }
        self?.stderr += "the poll took longer than 5 minutes\n"
        process.terminateGroup()
      }
    }
  }

  private func received(_ data: Data, isError: Bool, from process: AutomationProcess) {
    guard process === self.process, !stopped else { return }
    if isError {
      stderr += String(decoding: data, as: UTF8.self)
      if stderr.utf8.count > 16_384 { stderr = String(stderr.suffix(8_192)) }
      return
    }
    for line in buffer.append(data) { handle(line) }
  }

  private func handle(_ line: String) {
    switch WatcherLine.parse(line) {
    case .event(let payload): engine?.fire(id, .trigger(trigger, payload: payload))
    case .skipped(let reason): engine?.note(id, "watcher skipped a line: \(reason)")
    }
  }

  private func ended(_ status: Int32, process: AutomationProcess) {
    guard process === self.process else { return }
    self.process = nil
    guard !stopped else { return }
    for line in buffer.finish() { handle(line) }
    if let interval, status == 0 {
      backoff.succeeded()
      return schedule(after: interval)
    }
    // A streaming watcher that stayed up 10 minutes was healthy: its next crash starts the doubling over.
    if interval == nil, Date().timeIntervalSince(startedAt) >= WatcherBackoff.window { backoff.succeeded() }
    crashed(status)
  }

  private func crashed(_ status: Int32) {
    switch backoff.crashed(at: Date()) {
    case .broken:
      stopped = true
      engine?.watcherBroke(id, stderr: stderr)
    case .restart(let delay):
      engine?.note(id, "watcher exited with status \(status); starting it again in \(Int(delay))s")
      schedule(after: max(delay, interval ?? 0))
    }
  }

  private func schedule(after delay: TimeInterval) {
    let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.launch() } }
    next = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }
}
