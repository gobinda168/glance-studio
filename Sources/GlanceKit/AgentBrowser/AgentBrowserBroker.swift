import Combine
import Foundation
import GlanceCore
import Network

/// Glance browser (spec 2026-10-14-agent-browser-design.md), Studio's side of the broker: two fixed loopback ports
/// (Playwright clients and CDP) whose first connection starts `agent-browser.mjs` with the user's node, the broker's
/// browsers for the panel to watch, Stop / Continue, and quitting after 5 idle minutes.
@MainActor
public final class AgentBrowserBroker: ObservableObject {
  public static let shared = AgentBrowserBroker()

  public static let stoppedText = "The user stopped the Glance browser"

  public enum State: Equatable {
    case off
    case starting
    case installing(String)
    case running
    case stopped
    case failed(String)
  }

  public struct Browser: Identifiable, Equatable {
    public let id: String
    public let kind: AgentBrowserEvent.Kind
    public let version: String
    public let cdpPort: Int
  }

  @Published public private(set) var state: State = .off
  @Published public private(set) var browsers: [Browser] = []
  @Published public private(set) var ports: AgentBrowserPorts.Pair?

  /// Whether something still wants the broker (the panel is shown, a page is open): no idle quit while true.
  public var keepAlive: () -> Bool = { false }
  /// Settings → Browser → "Quit the browser after 5 minutes idle".
  public var quitsWhenIdle = true

  private let home = AgentBrowserPackages.folder(home: NSHomeDirectory())
  private var clientRelay: AgentBrowserRelay?
  private var cdpRelay: AgentBrowserRelay?
  private var process: Process?
  private var input: FileHandle?
  private var outputBuffer = Data()
  private var brokerPorts: (client: Int, cdp: Int)?
  private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
  private var claudeWaiters: [CheckedContinuation<Int?, Never>] = []
  private var starting = false
  private var quitting = false
  private var idleSince: Date?
  private var idleTimer: Timer?

  private init() {}

  // MARK: Ports

  /// Listens on the two ports (chosen once, kept in Application Support). Nothing else runs until a connection comes.
  public func startListening() {
    guard clientRelay == nil else { return }
    let saved = (try? Data(contentsOf: URL(fileURLWithPath: AgentBrowserPackages.portsFile(home: NSHomeDirectory()))))
      .flatMap { try? JSONDecoder().decode(AgentBrowserPorts.Pair.self, from: $0) }
    guard let pair = AgentBrowserPorts.choose(saved: saved.map { ($0.client, $0.cdp) }, isFree: Self.isFree) else {
      NSLog("Glance: the Glance browser found no free ports")
      return
    }
    try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    if saved != pair, let data = try? JSONEncoder().encode(pair) {
      try? data.write(to: URL(fileURLWithPath: AgentBrowserPackages.portsFile(home: NSHomeDirectory())))
    }
    let client = AgentBrowserRelay(port: pair.client) { [weak self] in await self?.routeClient() ?? .refuse("Glance is quitting") }
    let cdp = AgentBrowserRelay(port: pair.cdp) { [weak self] in await self?.routeCDP() ?? .refuse("Glance is quitting") }
    do {
      try client.start()
      try cdp.start()
    } catch {
      NSLog("Glance: the Glance browser couldn't listen on \(pair.client)/\(pair.cdp): \(error)")
      return
    }
    clientRelay = client
    cdpRelay = cdp
    ports = pair
    idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
      MainActor.assumeIsolated { self.checkIdle() }
    }
  }

  /// `PW_TEST_CONNECT_WS_ENDPOINT` for Studio's shells.
  public var testEndpoint: String? { ports.map { "ws://127.0.0.1:\($0.client)/" } }

  private static func isFree(_ port: Int) -> Bool {
    let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard socket >= 0 else { return false }
    defer { Darwin.close(socket) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
  }

  private func routeClient() async -> AgentBrowserRelay.Target {
    if state == .stopped { return .refuse(Self.stoppedText) }
    guard await ensureRunning(), let ports = brokerPorts else { return .refuse(failureText) }
    return .port(ports.client)
  }

  private func routeCDP() async -> AgentBrowserRelay.Target {
    if state == .stopped { return .refuse(Self.stoppedText) }
    guard await ensureRunning(), let port = await claudeBrowser() else {
      return .refuse(state == .stopped ? Self.stoppedText : failureText)
    }
    return .port(port)
  }

  private var failureText: String {
    if case .failed(let message) = state { return message }
    return "The Glance browser didn't start"
  }

  // MARK: The broker process

  /// Starts the broker if it isn't running; true once it's ready.
  public func ensureRunning() async -> Bool {
    if brokerPorts != nil, process?.isRunning == true { return true }
    return await withCheckedContinuation { continuation in
      readyWaiters.append(continuation)
      launch()
    }
  }

  /// Glance browser's CDP port, starting it (and installing Playwright the first time).
  private func claudeBrowser() async -> Int? {
    if let browser = browsers.first(where: { $0.kind == .claude }) { return browser.cdpPort }
    return await withCheckedContinuation { continuation in
      claudeWaiters.append(continuation)
      send("claude")
    }
  }

  /// Opens the Glance browser without a client (the panel's Restart, or showing the panel with nothing running).
  public func start() {
    Task { if await ensureRunning() { _ = await claudeBrowser() } }
  }

  private func launch() {
    guard !starting else { return }
    starting = true
    quitting = false
    state = .starting
    let script = Resources.agentBrowserScript.path
    let home = home
    DispatchQueue.global(qos: .userInitiated).async {
      let node = NodeLocator.find()
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.run(node: node, script: script, home: home) }
      }
    }
  }

  private func run(node: NodeLocator.Found?, script: String, home: String) {
    guard let node else { return fail(NodeLocator.missing) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node.node)
    process.arguments = [script, "--home", home]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = node.path
    environment.removeValue(forKey: "NODE_OPTIONS")
    process.environment = environment
    let output = Pipe()
    let input = Pipe()
    process.standardOutput = output
    process.standardInput = input
    process.standardError = FileHandle.nullDevice
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.read(data) }
      }
    }
    process.terminationHandler = { finished in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.ended(finished) }
      }
    }
    do {
      try process.run()
    } catch {
      return fail("The Glance browser couldn't start: \(error.localizedDescription)")
    }
    self.process = process
    self.input = input.fileHandleForWriting
  }

  private func read(_ data: Data) {
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = String(decoding: outputBuffer[outputBuffer.startIndex..<newline], as: UTF8.self)
      outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
      if let event = AgentBrowserEvent.parse(line: line) { handle(event) }
    }
  }

  private func handle(_ event: AgentBrowserEvent) {
    switch event {
    case .ready(let client, let cdp):
      brokerPorts = (client, cdp)
      starting = false
      state = .running
      resumeReady(true)
    case .installing(let what):
      state = .installing(what)
    case .browser(let id, let kind, let version, let port):
      browsers.removeAll { $0.id == id }
      browsers.append(Browser(id: id, kind: kind, version: version, cdpPort: port))
      state = .running
      if kind == .claude { resumeClaude(port) }
    case .browserGone(let id):
      browsers.removeAll { $0.id == id }
    case .stopped:
      state = .stopped
      resumeClaude(nil)
    case .resumed:
      state = .running
    case .error(let message):
      NSLog("Glance: the Glance browser: \(message)")
      if case .installing = state { state = .failed(message) }
      resumeClaude(nil)
    }
  }

  private func ended(_ finished: Process) {
    guard finished === process else { return }
    process = nil
    input = nil
    brokerPorts = nil
    browsers = []
    starting = false
    outputBuffer = Data()
    clientRelay?.dropConnections()
    cdpRelay?.dropConnections()
    if quitting {
      state = .off
    } else if case .failed = state {
      // keep the reason
    } else {
      state = .failed("The Glance browser stopped unexpectedly")
    }
    resumeReady(false)
    resumeClaude(nil)
  }

  private func fail(_ message: String) {
    starting = false
    state = .failed(message)
    resumeReady(false)
    resumeClaude(nil)
  }

  private func resumeReady(_ ok: Bool) {
    let waiters = readyWaiters
    readyWaiters = []
    for waiter in waiters { waiter.resume(returning: ok) }
  }

  private func resumeClaude(_ port: Int?) {
    let waiters = claudeWaiters
    claudeWaiters = []
    for waiter in waiters { waiter.resume(returning: port) }
  }

  private func send(_ command: String) {
    try? input?.write(contentsOf: Data((command + "\n").utf8))
  }

  // MARK: The panel's buttons

  /// Closes every browser; Claude's next call and new test runs fail with `stoppedText` until `resume()`.
  public func stop() {
    guard process?.isRunning == true else { state = .stopped; return }
    send("stop")
  }

  public func resume() {
    if process?.isRunning == true { send("resume") } else { state = .off }
  }

  /// After a failure: start again.
  public func restart() {
    if case .failed = state { state = .off }
    start()
  }

  public func quit() {
    guard let process, process.isRunning else { return }
    quitting = true
    send("quit")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
      if process?.isRunning == true { process?.terminate() }
    }
  }

  private func checkIdle() {
    guard quitsWhenIdle, process?.isRunning == true else { idleSince = nil; return }
    let busy = (clientRelay?.connections ?? 0) + (cdpRelay?.connections ?? 0) > 0 || keepAlive()
    if busy { idleSince = nil; return }
    if let idleSince, Date().timeIntervalSince(idleSince) >= 5 * 60 {
      self.idleSince = nil
      quit()
    } else if idleSince == nil {
      idleSince = Date()
    }
  }
}
