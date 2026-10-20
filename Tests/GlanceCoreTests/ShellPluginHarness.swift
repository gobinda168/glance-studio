import Darwin
import Foundation
@testable import GlanceCore

/// A real `zsh -i` with Glance's plugin (terminal/src/shell-integration/zsh/glance-integration) in a pseudo-terminal,
/// and a socket server in the test playing Studio: it collects what the shell sends and sends commands back.
/// Readers run on their own threads (never the shared GCD pool, which blocked tests can starve).
final class PluginShell: @unchecked Sendable {
  enum Loader {
    /// `.zshrc` autoloads the plugin directly.
    case direct
    /// Started the way Studio starts a shell: ZDOTDIR is Ghostty's zsh integration folder, which loads both files.
    case ghostty
  }

  struct Timeout: Error, CustomStringConvertible {
    let description: String
  }

  static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  static let integration = repo.appendingPathComponent("terminal/src/shell-integration/zsh")
  static let plugin = integration.appendingPathComponent("glance-integration")

  let folder: URL
  let socketPath: String
  private var listener: Int32 = -1
  private var connection: Int32 = -1
  private var master: Int32 = -1
  private let process = Process()
  private let lock = NSLock()
  private var received: [ShellEvent] = []
  private var rawLines: [String] = []
  private var screenBytes = Data()
  private var closedByShell = false

  init(cwd: URL? = nil, zshrc: String = "", loader: Loader = .direct, glance: Bool = true,
       environment extra: [String: String] = [:]) throws {
    let id = String(UUID().uuidString.prefix(8)).lowercased()
    folder = URL(fileURLWithPath: "/tmp/glt-\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    socketPath = folder.appendingPathComponent("s").path
    let user = folder.appendingPathComponent("user", isDirectory: true)
    try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)

    var rc = zshrc + "\nPS1='%~ %# '\nHISTFILE=\(folder.path)/history\n"
    if loader == .direct { rc += "autoload -Uz \(Self.plugin.path) && glance-integration\n" }
    try rc.write(to: user.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

    try listen()

    var slave: Int32 = -1
    var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Timeout(description: "openpty failed") }
    var env: [String: String] = [
      "HOME": NSHomeDirectory(), "USER": NSUserName(), "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
      "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": folder.path,
    ]
    switch loader {
    case .direct: env["ZDOTDIR"] = user.path
    case .ghostty:
      env["ZDOTDIR"] = Self.integration.path
      env["GHOSTTY_ZSH_ZDOTDIR"] = user.path
      env["GHOSTTY_SHELL_FEATURES"] = "cursor,title"
    }
    if glance {
      env["GLANCE_SHELL_SOCKET"] = socketPath
      env["GLANCE_SHELL_TAB"] = "TAB-\(id)"
      env["GLANCE_SHELL_CACHE"] = folder.path
    }
    env.merge(extra) { $1 }
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-i"]
    process.environment = env
    process.currentDirectoryURL = cwd ?? folder
    let handle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
    process.standardInput = handle
    process.standardOutput = handle
    process.standardError = handle
    try process.run()
    close(slave)

    let ptyFD = master
    Thread.detachNewThread { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = read(ptyFD, &buffer, buffer.count)
        guard n > 0, let self else { return }
        self.lock.withLock { self.screenBytes.append(contentsOf: buffer[0..<n]) }
      }
    }
    if glance { try accept() }
  }

  deinit { stop() }

  func stop() {
    // An interactive zsh ignores SIGTERM; it exits on SIGHUP. The pty is closed only once it's gone: closing it under
    // a thread blocked reading it would block too.
    if process.isRunning {
      kill(process.processIdentifier, SIGHUP)
      let end = Date().addingTimeInterval(2)
      while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.02) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
    if connection >= 0 { close(connection); connection = -1 }
    if listener >= 0 { close(listener); listener = -1 }
    if master >= 0 { close(master); master = -1 }
    try? FileManager.default.removeItem(at: folder)
  }

  private func listen() throws {
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketPath.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, Darwin.listen(listener, 4) == 0 else { throw Timeout(description: "listen failed: \(errno)") }
  }

  /// Waits (up to 10 s) for the plugin to connect, then reads its messages on a thread.
  private func accept() throws {
    var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard poll(&poller, 1, 10_000) == 1 else { throw Timeout(description: "the plugin never connected") }
    connection = Darwin.accept(listener, nil, nil)
    var noSigPipe: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let fd = connection
    Thread.detachNewThread { [weak self] in
      var lines = ShellLines()
      var buffer = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = read(fd, &buffer, buffer.count)
        guard let self else { return }
        guard n > 0 else {
          self.lock.withLock { self.closedByShell = true }
          return
        }
        let new = lines.append(Data(buffer[0..<n]))
        self.lock.withLock {
          self.rawLines += new
          self.received += new.compactMap(ShellEvent.init(line:))
        }
      }
    }
  }

  // MARK: - Driving it

  func send(_ command: ShellCommand) {
    let bytes = Array(command.line.utf8)
    _ = bytes.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
  }

  /// Studio's side going away.
  func dropConnection() {
    close(connection)
    connection = -1
  }

  func type(_ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
  }

  var events: [ShellEvent] { lock.withLock { received } }
  var lines: [String] { lock.withLock { rawLines } }
  var screen: String { lock.withLock { String(decoding: screenBytes, as: UTF8.self) } }
  var shellClosed: Bool { lock.withLock { closedByShell } }
  var isRunning: Bool { process.isRunning }

  func clear() {
    lock.withLock {
      received.removeAll()
      rawLines.removeAll()
      screenBytes.removeAll()
    }
  }

  @discardableResult
  func wait(_ what: String = "event", timeout: TimeInterval = 8, _ match: (ShellEvent) -> Bool) throws -> ShellEvent {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if let found = events.first(where: match) { return found }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw Timeout(description: "no \(what) in \(timeout)s; got \(lines.suffix(8))")
  }

  func waitScreen(_ text: String, timeout: TimeInterval = 8) throws {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if screen.contains(text) { return }
      Thread.sleep(forTimeInterval: 0.01)
    }
    throw Timeout(description: "screen never showed \(text.debugDescription); it has \(screen.suffix(300).debugDescription)")
  }

  /// The hello, then `config` with `features`, then the first prompt.
  @discardableResult
  func start(features: [String] = ["tab"]) throws -> ShellHello {
    guard case .hello(let hello) = try wait("hello", { if case .hello = $0 { true } else { false } }) else {
      throw Timeout(description: "no hello")
    }
    send(.config(features: features))
    try wait("prompt") { if case .prompt = $0 { true } else { false } }
    Thread.sleep(forTimeInterval: 0.2)
    return hello
  }

  /// The latest `line` report.
  var lastLine: (seq: Int, cursor: Int, text: String)? {
    for event in events.reversed() {
      if case .line(let seq, let cursor, let text) = event { return (seq, cursor, text) }
    }
    return nil
  }

  /// Waits until the line reads `text`.
  func waitLine(_ text: String, timeout: TimeInterval = 8) throws {
    try wait("line \(text.debugDescription)", timeout: timeout) {
      if case .line(_, _, let t) = $0 { t == text } else { false }
    }
  }

  /// Types `text` and Tab, then waits for the candidates; returns them (empty when Tab completed directly).
  func tab(_ text: String, timeout: TimeInterval = 8) throws -> (request: Int, candidates: [CompletionCandidate]) {
    clear()
    type(text + "\t")
    let end = try wait("end of candidates", timeout: timeout) { if case .candidatesEnd = $0 { true } else { false } }
    guard case .candidatesEnd(let request) = end else { return (0, []) }
    let candidates = events.compactMap { event -> CompletionCandidate? in
      if case .candidate(let r, let c) = event, r == request { c } else { nil }
    }
    return (request, candidates)
  }

  /// Clears the line (⌃U) and the collected events.
  func clearLine() throws {
    type("\u{15}")
    Thread.sleep(forTimeInterval: 0.15)
    clear()
  }
}
