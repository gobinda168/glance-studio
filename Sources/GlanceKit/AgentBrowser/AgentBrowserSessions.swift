import Combine
import Foundation
import GlanceCore

/// Command Center (spec 2026-11-01-command-center-design.md §4.1): the unix socket each Claude session's Playwright
/// wrapper (`agent-browser/session-mcp.mjs`) keeps open to Studio. It builds the `BrowserSessionTable` (who owns which
/// window), tells whoever listens what happened, and hands back the windows a session left behind when its connection
/// drops. It also writes `options.json`, which is how the wrappers (and `glance agent-browser mcp`) learn whether to run
/// and where Studio listens.
///
/// Switching the feature off only stops advertising session windows: connections stay, because dropping one closes the
/// windows its session is still using.
@MainActor
public final class AgentBrowserSessions: ObservableObject {
  public static let shared = AgentBrowserSessions()

  @Published public private(set) var table = BrowserSessionTable()

  /// Studio: whether Feature.commandCenter is on.
  public var isEnabled: () -> Bool = { false }
  /// Every message a wrapper sent after it passed its `hello` check: connection, message, when. A single slot, owned by
  /// `ClipRecorder`: nothing else may take it.
  public var onEvent: ((Int, BrowserSessionTable.Event, Date) -> Void)?
  /// A connection ended: it and the pages it owned, which the listener closes in the browser.
  public var onDisconnect: ((Int, [String]) -> Void)?
  /// A connection's socket ended, at once (`onDisconnect` waits a few seconds for a wrapper that is about to reconnect).
  /// The clip recorder ends that client's clips on it.
  public var onDrop: ((Int) -> Void)?

  private let server = ChannelServer()
  private let home = NSHomeDirectory()
  /// The peer pid of each connection, to check against what its `hello` claims.
  private var peers: [Int: pid_t] = [:]

  private init() {}

  /// Whether Studio is listening for the wrappers.
  public var isListening: Bool { server.path != nil }

  /// Windows for each session: the feature is on, Claude's browser is Chromium (Lightpanda has no windows) and the
  /// socket is open. The broker starts with `--session-windows` when this is true.
  public var sessionWindows: Bool { isEnabled() && AgentBrowserBroker.shared.engine == .chromium && isListening }

  /// Starts listening (once) when the feature is on, then writes the options. With the feature off at launch nothing
  /// listens and the options say so.
  public func start() {
    if isEnabled(), !isListening { listen() }
    updateOptions()
    ClipRecorder.shared.start()
  }

  /// Writes `<agent-browser>/options.json` atomically: after the listener, the feature or the engine changed.
  public func updateOptions() {
    let options = AgentBrowserOptions(sessionWindows: sessionWindows, socket: server.path)
    let file = AgentBrowserOptions.file(home: home)
    do {
      try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try JSONEncoder().encode(options).write(to: URL(fileURLWithPath: file), options: .atomic)
    } catch {
      NSLog("Glance: couldn't write the Glance browser's options: \(error.localizedDescription)")
    }
    // The engine or the feature changed: clips follow (Lightpanda and the feature off record nothing).
    ClipRecorder.shared.refresh()
  }

  // MARK: Listening

  private func listen() {
    let path = BrowserSessionSocket.path(home: home, pid: getpid(), temporary: NSTemporaryDirectory())
    sweep(folder: (path as NSString).deletingLastPathComponent)
    server.onOpen = { [weak self] id, pid in self?.peers[Int(id)] = pid }
    server.onLine = { [weak self] id, line in self?.received(Int(id), line) }
    server.onClose = { [weak self] id in self?.closed(Int(id)) }
    do {
      try server.start(path: path)
    } catch {
      NSLog("Glance: the Glance browser can't listen for its sessions: \(error)")
    }
  }

  /// Sockets Studios that crashed left behind: any `s-*.sock` that nothing answers on (one that answers is another
  /// Studio's, and stays).
  private func sweep(folder: String) {
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    where name.hasPrefix("s-") && name.hasSuffix(".sock") {
      let path = (folder as NSString).appendingPathComponent(name)
      if !ChannelServer.isLive(path) { unlink(path) }
    }
  }

  private func received(_ id: Int, _ line: String) {
    guard let event = BrowserSessionTable.decode(line) else { return }
    if case .hello(let wrapper, _, _, _) = event {
      // The wrapper says its own pid; the socket says whose connection this is. Anything else isn't a wrapper.
      guard peers[id] == wrapper else { return server.drop(Int32(id)) }
    } else if table.clients[id] == nil {
      return // nothing before a hello counts
    }
    let now = Date()
    table.apply(event, client: id, at: now)
    onEvent?(id, event, now)
  }

  /// A connection ended. Its windows close only when its wrapper is gone: a dropped socket with the wrapper alive (it is
  /// about to reconnect) mustn't close what a session is using. A process that was just killed can still look alive for
  /// a moment, so a live one is looked at again after a few seconds. A page a new connection has claimed since is never
  /// closed.
  private func closed(_ id: Int) {
    onDrop?(id)
    peers[id] = nil
    let wrapper = table.clients[id]?.wrapperPID
    let targets = table.disconnect(client: id)
    guard let wrapper, !targets.isEmpty else { return notifyDisconnect(id, targets) }
    let now = closable(targets, wrapper: wrapper)
    if !now.isEmpty { return notifyDisconnect(id, now) }
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard let self else { return }
      self.notifyDisconnect(id, self.closable(targets, wrapper: wrapper))
    }
  }

  private func notifyDisconnect(_ id: Int, _ targets: [String]) { onDisconnect?(id, targets) }

  private func closable(_ targets: [String], wrapper: pid_t) -> [String] {
    kill(wrapper, 0) != 0 && errno == ESRCH ? targets.filter { table.client(owning: $0) == nil } : []
  }
}
