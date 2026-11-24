import Combine
import Foundation
import GlanceCore
import ImageIO

extension Notification.Name {
  /// A session's work record changed outside a hook (a clip was added). `userInfo["session"]` is the session id. The proof
  /// panel and the assets list reload on it: a clip lands seconds after the transcript stopped moving.
  public static let workRecordChanged = Notification.Name("dev.glance.work.recordChanged")
}

/// Who a recording belongs to: one Claude session's wrapper (a client of `AgentBrowserSessions`). Kept by the recorder from
/// the wrapper's `hello`, because the table forgets the client the moment its socket drops, and a clip can end after that.
final class ClipOwner: @unchecked Sendable {
  let client: Int
  let claudePID: Int32
  let session: String?
  let cwd: String?
  private let lock = NSLock()
  private var looked = false
  private var found: RepoLocation?

  init(client: Int, claudePID: Int32, session: String?, cwd: String?) {
    self.client = client
    self.claudePID = claudePID
    self.session = session
    self.cwd = cwd
  }

  /// Where the client's folder sits in git, looked up once (it runs git, so never on main).
  func location() -> RepoLocation? {
    lock.lock()
    defer { lock.unlock() }
    if !looked, let cwd {
      found = RepoLocation.find(cwd: cwd)
      looked = true
    }
    return found
  }
}

/// Which session's record a clip goes into, and where that session runs.
struct ClipFiling: Equatable, Sendable {
  var session: String
  var cwd: String?
  var worktree: String?
  var branch: String?
  var commonDir: String?
  var environment: String?
}

/// Command Center (spec 2026-11-01-command-center-design.md §4.2): records a clip of every page visit a Claude session
/// drives in its own browser windows, and files it in that session's work record.
///
/// The rules for when a clip starts and stops are `ClipRules` (one per wrapper). This is the part that touches the world:
/// it attaches to the page, takes the screencast, throttles it into a `VideoWriter`, and at the end resolves which
/// session the clip belongs to and adds it to the record.
///
/// Threads: the rules, the page tables and every decision are on main. A frame never is: the connection receives and
/// acknowledges it on its own queue, and the decoding and writing run on one serial queue (`ClipSink`). Resolving the
/// session runs git and `addCapture` copies up to 200 MB under a lock, so both run off main.
@MainActor
public final class ClipRecorder {
  public static let shared = ClipRecorder()

  typealias Resolver = @Sendable (ClipOwner, String) -> ClipFiling?

  private let connectNew: () -> ScreencastConnecting?
  private let store: WorkStore
  private let resolve: Resolver
  private let now: () -> Date
  private let allowed: () -> Bool

  private var rules: [Int: ClipRules] = [:]
  private var owners: [Int: ClipOwner] = [:]
  /// The wrapper that announced each page; the browser's word about a page (its URL) is joined to it by target id.
  private var clientOfTarget: [String: Int] = [:]
  /// The pages each wrapper owns and whether the user opened them: what the rules are told again after a `.reset`.
  private var pagesOfClient: [Int: [String: Bool]] = [:]
  private var urls: [String: String] = [:]

  private var connection: ScreencastConnecting?
  private var ready: Task<Bool, Never>?
  /// Failed attempts to reach a browser that was just started (its DevTools server takes a moment).
  private var failedConnections = 0
  private var retry: Task<Void, Never>?
  /// Seconds to wait before the nth failed attempt is retried.
  var retryDelay: (Int) -> Double = { min(30, pow(2, Double($0 - 1))) }
  private var active: [String: ClipSink] = [:]
  private let sinks = SinkTable()
  /// The latest browser command in flight for each page: the next one waits for it, so a stop never overtakes a start.
  private var chains: [String: Task<Void, Never>] = [:]
  private var inFlight: [UUID: Task<Void, Never>] = [:]

  private var timer: Timer?
  private var watches: [AnyCancellable] = []
  private var observer: NSObjectProtocol?

  init(connect: @escaping () -> ScreencastConnecting? = ClipRecorder.connectToBroker,
       store: WorkStore = WorkStore(),
       resolve: @escaping Resolver = { ClipRecorder.resolveSession($0, url: $1) },
       now: @escaping () -> Date = Date.init,
       allowed: @escaping () -> Bool = ClipRecorder.recordingAllowed) {
    connectNew = connect
    self.store = store
    self.resolve = resolve
    self.now = now
    self.allowed = allowed
  }

  // MARK: Start-up

  /// Starts listening to the sessions (once) and applies the settings as they are now. Safe to call again.
  public func start() {
    if timer == nil {
      sweepTemporaryClips()
      // In the common modes, so an open menu or a drag doesn't hold back the end of a clip.
      let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }
      RunLoop.main.add(ticker, forMode: .common)
      timer = ticker
      let sessions = AgentBrowserSessions.shared
      // `onEvent` and `onDrop` are single slots and the recorder owns them: nothing else may take either.
      sessions.onEvent = { [weak self] client, event, at in self?.handle(client: client, event, at: at) }
      sessions.onDrop = { [weak self] client in
        guard let self else { return }
        self.dropped(client: client, at: self.now())
      }
      observer = NotificationCenter.default.addObserver(forName: ClipSettings.didChange, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      // `$browsers` publishes before it changes, so look after the change has landed.
      AgentBrowserBroker.shared.$browsers.dropFirst().receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          self?.failedConnections = 0
          self?.refresh()
        }.store(in: &watches)
    }
    refresh()
  }

  /// Applies the guards: with Lightpanda, the feature off or Settings → Browser → record clips off nothing is recorded, and
  /// the clips being recorded end here. Otherwise a browser that is up gets its connection.
  func refresh() {
    if allowed() {
      if !owners.isEmpty { ensureConnection() }
      return
    }
    let dropped = connection
    connection = nil
    ready = nil
    chains = [:]
    retry?.cancel()
    retry = nil
    let date = now()
    // The rules end their clips and are told the pages again, so recording picks up at the next tool call.
    for client in rules.keys.sorted() { resync(client, at: date) }
    for target in Array(active.keys) { endClip(target, keep: true, endedAt: date) }
    dropped?.close()
  }

  /// Tells a client's rules to forget what they think is recording, then what pages it has: after the recorder dropped
  /// clips the rules still hold, so a later visit starts a new one.
  private func resync(_ client: Int, at date: Date) {
    run(client, .reset(at: date))
    for (target, adopted) in (pagesOfClient[client] ?? [:]).sorted(by: { $0.key < $1.key }) {
      run(client, .pageOpened(target: target, url: urls[target] ?? "", adopted: adopted, at: date))
    }
  }

  nonisolated static func recordingAllowed() -> Bool {
    MainActor.assumeIsolated { AgentBrowserSessions.shared.sessionWindows && ClipSettings.recordClips }
  }

  /// A connection to the Glance browser's real debugging port, if it is up.
  nonisolated static func connectToBroker() -> ScreencastConnecting? {
    MainActor.assumeIsolated {
      guard let browser = AgentBrowserBroker.shared.browsers.first(where: { $0.kind == .claude }) else { return nil }
      return ScreencastConnection(port: browser.cdpPort)
    }
  }

  /// Clips an earlier run left half-written. Files carry their Studio's pid (`<pid>-<id>.mp4`), so another Studio's clip
  /// in progress is left alone.
  func sweepTemporaryClips() {
    let folder = temporaryFolder
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] {
      if let pid = name.split(separator: "-").first.flatMap({ Int32($0) }), ProcessTree.isAlive(pid) { continue }
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  private var temporaryFolder: URL { store.folder.appendingPathComponent(".tmp-clips", isDirectory: true) }

  // MARK: Input

  /// A message from a session's wrapper.
  func handle(client: Int, _ event: BrowserSessionTable.Event, at date: Date) {
    switch event {
    case .hello(_, let claudePID, let session, let cwd):
      // A repeated hello is a reconnect: it announces its pages and calls in flight again, so the old picture ends.
      if rules[client] != nil { forget(client: client, at: date) }
      failedConnections = 0
      rules[client] = ClipRules()
      owners[client] = ClipOwner(client: client, claudePID: claudePID, session: session, cwd: cwd)
      ensureConnection()
    case .page(let target, let adopted):
      guard rules[client] != nil else { return }
      if let other = clientOfTarget[target], other != client {
        pagesOfClient[other]?[target] = nil
        run(other, .pageClosed(target: target, at: date))
      }
      pagesOfClient[client, default: [:]][target] = adopted
      // The page is already known and the browser hasn't said where it is: nothing to add.
      if clientOfTarget[target] == client, urls[target] == nil { return }
      clientOfTarget[target] = client
      run(client, .pageOpened(target: target, url: urls[target] ?? "", adopted: adopted, at: date))
    case .pageGone(let target):
      guard clientOfTarget[target] == client else { return }
      clientOfTarget[target] = nil
      pagesOfClient[client]?[target] = nil
      run(client, .pageClosed(target: target, at: date))
    case .tool(_, let phase):
      run(client, .tool(phase: phase, at: date))
    }
  }

  /// A wrapper's socket ended: its clips end with the frames they have, and nothing remains of it.
  func dropped(client: Int, at date: Date) {
    forget(client: client, at: date)
  }

  private func forget(client: Int, at date: Date) {
    run(client, .reset(at: date))
    rules[client] = nil
    owners[client] = nil
    pagesOfClient[client] = nil
    for (target, owner) in clientOfTarget where owner == client { clientOfTarget[target] = nil }
    // Nobody left to record for: the connection (and the pages it attached to) goes too.
    if owners.isEmpty, let idle = connection {
      connection = nil
      ready = nil
      chains = [:]
      retry?.cancel()
      retry = nil
      idle.close()
    }
  }

  /// Once a second: time passes for the rules (5 s idle, 180 s limit).
  func tick() {
    let date = now()
    for client in rules.keys.sorted() { run(client, .tick(at: date)) }
  }

  private func received(_ event: ScreencastEvent, from source: ScreencastConnecting) {
    guard source === connection else { return }
    let date = now()
    switch event {
    case .created(let target, let url), .changed(let target, let url):
      let before = urls[target]
      urls[target] = url
      if before != url, let client = clientOfTarget[target] { run(client, .navigated(target: target, url: url, at: date)) }
    case .destroyed(let target):
      urls[target] = nil
      chains[target] = nil
      if let client = clientOfTarget.removeValue(forKey: target) {
        pagesOfClient[client]?[target] = nil
        run(client, .pageClosed(target: target, at: date))
      }
    case .closed:
      lost(source)
    }
  }

  private func frameWritten(_ target: String, by sink: ClipSink) {
    guard active[target] === sink, let client = clientOfTarget[target] else { return }
    run(client, .frame(target: target, at: now()))
  }

  // MARK: Rules

  private func run(_ client: Int, _ input: ClipRules.Input) {
    guard var current = rules[client] else { return }
    let outputs = current.step(input)
    rules[client] = current
    // A finish and a start can come together for one page (it navigated): the old clip is closed before the new opens.
    for output in outputs {
      switch output {
      case .start(let target, let url): beginClip(target: target, url: url, client: client)
      case .finish(let target, let keep, let endedAt): endClip(target, keep: keep, endedAt: endedAt)
      }
    }
  }

  // MARK: Connection

  private func ensureConnection() {
    guard connection == nil, allowed(), !owners.isEmpty, let source = connectNew() else { return }
    connection = source
    source.onFrame = { [sinks] target, data, time in sinks.deliver(target, data, at: time) }
    source.onEvent = { [weak self, weak source] event in
      guard let self, let source else { return }
      MainActor.assumeIsolated { self.received(event, from: source) }
    }
    let opening = Task<Bool, Never> { @MainActor [weak self] in
      do {
        try await source.open()
        self?.failedConnections = 0
        return true
      } catch {
        NSLog("Glance: clips can't connect to the browser: \(error.localizedDescription)")
        source.close()
        self?.lost(source)
        return false
      }
    }
    ready = opening
    track(opening)
  }

  /// The connection failed to open or ended (the socket dropped, or the browser quit). What was recorded is kept; the rules
  /// forget their clips but not their pages; and recording comes back by itself: with the next tool call that starts a
  /// clip, or when the backoff timer fires, whichever is first. Both the failed `open()` and the socket's `.closed` can
  /// report the same loss, in either order: only the first counts.
  private func lost(_ source: ScreencastConnecting) {
    guard connection === source else { return }
    connection = nil
    ready = nil
    chains = [:]
    urls = urls.filter { clientOfTarget[$0.key] != nil }
    let date = now()
    for client in rules.keys.sorted() { resync(client, at: date) }
    for target in Array(active.keys) { endClip(target, keep: true, endedAt: date) }
    scheduleReconnect()
  }

  private func scheduleReconnect() {
    guard retry == nil, !owners.isEmpty else { return }
    failedConnections += 1
    let delay = retryDelay(failedConnections)
    retry = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      self.retry = nil
      self.refresh()
    }
  }

  // MARK: Clips

  private func beginClip(target: String, url: String, client: Int) {
    guard allowed(), owners[client] != nil else { return didNotStart(client) }
    if connection == nil { ensureConnection() }
    guard let source = connection, let owner = owners[client], let opening = ready else { return didNotStart(client) }
    if active[target] != nil { endClip(target, keep: false, endedAt: now()) }
    let folder = temporaryFolder
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("\(getpid())-\(UUID().uuidString).mp4")
    let sink: ClipSink
    do {
      sink = try ClipSink(target: target, url: url, file: file, owner: owner)
    } catch {
      NSLog("Glance: couldn't start a clip: \(error.localizedDescription)")
      return didNotStart(client)
    }
    sink.onFrame = { [weak self, weak sink] in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { if let self, let sink { self.frameWritten(target, by: sink) } }
      }
    }
    active[target] = sink
    sinks.set(target, sink)
    chain(target) { [weak self] in
      do {
        guard await opening.value else { throw ScreencastConnection.Failure(message: "No connection to the browser") }
        try await source.attach(target: target)
        // The clip may have ended while the browser was attaching: then nobody wants the screencast.
        guard self?.active[target] === sink else { return }
        try await source.startScreencast(target: target)
      } catch {
        self?.startFailed(target, sink, error)
      }
    }
  }

  /// The rules started a clip the recorder can't record: they are told, so a later visit starts one again.
  private func didNotStart(_ client: Int) {
    resync(client, at: now())
  }

  private func startFailed(_ target: String, _ sink: ClipSink, _ error: Error) {
    guard active[target] === sink else { return }
    NSLog("Glance: couldn't record \(sink.url): \(error.localizedDescription)")
    active[target] = nil
    sinks.remove(target, sink)
    spawn { await sink.cancel() }
  }

  private func endClip(_ target: String, keep: Bool, endedAt: Date) {
    guard let sink = active.removeValue(forKey: target) else { return }
    sinks.remove(target, sink)
    if let source = connection {
      chain(target) { _ = try? await source.stopScreencast(target: target) }
    }
    let store = store, resolve = resolve, date = now()
    spawn { [weak self] in
      await Self.file(sink, keep: keep, endedAt: endedAt, store: store, resolve: resolve, now: date)
      self?.filed(sink)
    }
  }

  private func filed(_ sink: ClipSink) {
    if let session = sink.filedSession {
      NotificationCenter.default.post(name: .workRecordChanged, object: nil, userInfo: ["session": session])
    }
  }

  /// Ends the writer and, when the clip is worth keeping and its session is known, adds it to the record. The temp file goes
  /// either way.
  private static func file(_ sink: ClipSink, keep: Bool, endedAt: Date, store: WorkStore, resolve: @escaping Resolver,
                           now: Date) async {
    // The newest frame the throttle held is the page's last state: it goes in before the video is closed.
    let frames = await sink.flush()
    guard keep, frames > 0 else { return await sink.cancel() }
    let owner = sink.owner, url = sink.url
    let filing = await onFileQueue { resolve(owner, url) }
    guard let filing else { return await sink.cancel() }
    do {
      try await sink.finish(at: endedAt)
    } catch {
      NSLog("Glance: couldn't finish a clip of \(url): \(error.localizedDescription)")
      return await sink.cancel()
    }
    let file = sink.file
    let host = URL(string: url)?.host ?? URL(string: url)?.lastPathComponent ?? url
    let added = await onFileQueue {
      store.addCapture(session: filing.session, id: UUID().uuidString, from: file, kind: .clip, url: url,
                       environment: filing.environment, caption: "Clip of \(host)", purpose: .test, source: .glance,
                       cwd: filing.cwd, worktree: filing.worktree, branch: filing.branch, commonDir: filing.commonDir,
                       now: now, budget: 5)
    }
    try? FileManager.default.removeItem(at: file)
    if added != nil {
      sink.filedSession = filing.session
    } else {
      NSLog("Glance: couldn't add a clip of \(url) to the session's record")
    }
  }

  /// Filing blocks (git, a lock held up to 5 s, a copy of up to 200 MB): a queue of its own, not a thread the async
  /// runtime shares with everything else.
  private static let fileQueue = DispatchQueue(label: "dev.glance.clips.file", qos: .utility)

  private static func onFileQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in fileQueue.async { continuation.resume(returning: work()) } }
  }

  // MARK: Default resolution

  /// The session a clip belongs to: the live Claude session the wrapper's `claude` process runs in its folder's repository
  /// (it survives `/clear`, which changes the session id), else the session the wrapper said when it connected. Off main.
  nonisolated static func resolveSession(_ owner: ClipOwner, url: String) -> ClipFiling? {
    var session = owner.session
    if let cwd = owner.cwd {
      let location = owner.location()
      if case .success(let live) = ProofTools.resolveSession(claudePID: owner.claudePID, cwd: cwd, location: { _ in location }) {
        session = live
      }
    }
    guard let session, WorkStore.isSessionID(session) else { return nil }
    guard let cwd = owner.cwd else { return ClipFiling(session: session) }
    return ClipFiling(session: session, cwd: cwd, worktree: ProjectRoot.find(from: cwd), branch: GitHead.branch(inFolder: cwd),
                      commonDir: GitCommonDir.find(from: cwd), environment: ProofMatcher.environment(forURL: url, cwd: cwd))
  }

  // MARK: Tasks

  private func chain(_ target: String, _ operation: @escaping @MainActor () async -> Void) {
    let previous = chains[target]
    chains[target] = spawn { await previous?.value; await operation() }
  }

  @discardableResult
  private func spawn(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let task = Task { @MainActor in await operation() }
    track(task)
    return task
  }

  private func track<T: Sendable>(_ task: Task<T, Never>) {
    let id = UUID()
    inFlight[id] = Task { @MainActor [weak self] in
      _ = await task.value
      self?.inFlight[id] = nil
    }
  }

  /// Waits until frames in flight were written and the browser commands and filing in flight are done. For tests.
  func settle() async {
    while true {
      await sinks.drain()
      await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
      let tasks = Array(inFlight.values)
      if tasks.isEmpty { return }
      for task in tasks { await task.value }
    }
  }
}
