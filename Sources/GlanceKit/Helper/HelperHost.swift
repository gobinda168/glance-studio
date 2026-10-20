import AppKit
import Foundation
import GlanceCore

/// Glance Studio's side of the helper process: starts `glance helper` (the CLI bundled in the app), restarts it when it
/// exits, and passes commands and events between it and the services. The helper runs the background jobs, so one that
/// crashes takes the helper down and the app carries on; the helper reports `ready` after every start, and each
/// service then sends the commands for what it wants running.
@MainActor
public final class HelperHost: ObservableObject {
  public static let shared = HelperHost()

  /// The helper is up (between its start and its exit).
  @Published public private(set) var isRunning = false

  /// The CLI inside the app, nil when this build has none (a service then runs its job in the app, as before).
  public static var cli: URL? {
    let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance")
    return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
  }

  public var isAvailable: Bool { Self.cli != nil }

  private var eventHandlers: [@MainActor (HelperWire.Event) -> Void] = []
  private var exitHandlers: [@MainActor () -> Void] = []
  private var process: Process?
  private var input: FileHandle?
  private var wanted = false
  private var startedAt = Date()
  private var backoff = HelperBackoff()
  private var terminateObserver: NSObjectProtocol?

  private init() {}

  /// Calls `handler` for every event the helper sends, `ready` included.
  public func onEvent(_ handler: @escaping @MainActor (HelperWire.Event) -> Void) {
    eventHandlers.append(handler)
  }

  /// Calls `handler` each time the helper exits (a crash, a kill, or `stop()`), before it is started again.
  public func onExit(_ handler: @escaping @MainActor () -> Void) {
    exitHandlers.append(handler)
  }

  /// Starts the helper if it isn't running, and keeps it running until `stop()`.
  public func start() {
    wanted = true
    if terminateObserver == nil {
      terminateObserver = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { _ in MainActor.assumeIsolated { HelperHost.shared.stop() } }
    }
    launch()
  }

  public func stop() {
    wanted = false
    process?.terminate()
  }

  /// Sends the helper a command. Dropped when it isn't running: it starts again with `ready`, and the service sends it
  /// its jobs then.
  public func send(_ command: HelperWire.Command) {
    guard isRunning, let input else { return }
    try? input.write(contentsOf: Data((HelperWire.line(command) + "\n").utf8))
  }

  private func launch() {
    guard wanted, process == nil, let cli = Self.cli else { return }
    let process = Process()
    process.executableURL = cli
    process.arguments = ["helper"]
    let stdin = Pipe(), stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    // A write after the helper exits must fail, not end the app with SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    var lines = HelperLines()
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      let events = lines.append(data).compactMap(HelperWire.event(from:))
      guard !events.isEmpty else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { events.forEach { HelperHost.shared.deliver($0) } }
      }
    }
    process.terminationHandler = { [weak process] _ in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { HelperHost.shared.exited(process) }
      }
    }
    do {
      try process.run()
    } catch {
      NSLog("Glance: the helper couldn't start: \(error)")
      scheduleRestart(afterRunning: 0)
      return
    }
    self.process = process
    input = stdin.fileHandleForWriting
    startedAt = Date()
    isRunning = true
  }

  private func deliver(_ event: HelperWire.Event) {
    eventHandlers.forEach { $0(event) }
  }

  private func exited(_ ended: Process?) {
    guard ended === process else { return }
    process = nil
    input = nil
    isRunning = false
    exitHandlers.forEach { $0() }
    scheduleRestart(afterRunning: Date().timeIntervalSince(startedAt))
  }

  private func scheduleRestart(afterRunning seconds: TimeInterval) {
    guard wanted else { return }
    let delay = backoff.delay(afterRunning: seconds)
    NSLog("Glance: the helper stopped; starting it again in \(Int(delay)) s")
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { HelperHost.shared.launch() }
    }
  }
}
