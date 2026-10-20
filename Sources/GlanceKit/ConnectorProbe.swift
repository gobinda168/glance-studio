import Darwin
import Foundation
import GlanceCore

/// Which MCP servers Claude Code has connected, from one cheap run's first stream-json event (spec
/// 2026-10-09-tickets-design.md, "Trackers and fetch"). Cached for the app's run; `check(force: true)` asks again.
@MainActor
public final class ConnectorProbe: ObservableObject {
  public static let shared = ConnectorProbe()

  @Published public private(set) var trackers: [Tracker] = []
  /// Every server Claude Code reported, connected or not (Settings → Connectors).
  @Published public private(set) var servers: [ConnectorServer] = []
  @Published public private(set) var checked = false
  @Published public private(set) var checking = false
  @Published public private(set) var error: String?
  @Published public private(set) var initLine: String?

  private var waiters: [() -> Void] = []

  public func check(force: Bool = false, then: (() -> Void)? = nil) {
    if let then { waiters.append(then) }
    if checked && !force { return flush() }
    guard !checking else { return }
    checking = true
    ClaudeLocator.locate { [weak self] found in
      guard let self else { return }
      guard let found else { return self.finish(line: nil, error: "Claude Code isn't installed.") }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: found.executable)
      process.arguments = ["-p", "--output-format", "stream-json", "--verbose", "--max-turns", "1",
                           "--model", "haiku", "--tools", "", "--no-session-persistence",
                           "--settings", #"{"disableAllHooks":true}"#]
      let folder = ClaudeOneShot.scratchFolder
      process.currentDirectoryURL = URL(fileURLWithPath: folder)
      var environment = ProcessInfo.processInfo.environment
      if let path = found.path { environment["PATH"] = path }
      environment["CLAUDECODE"] = nil
      // claude.ai connectors (Jira through Claude) connect before the init event, so it lists them with their tools.
      environment.merge(TrackerProbe.waitForConnectors) { $1 }
      process.environment = environment
      let stdin = Pipe(), stdout = Pipe()
      _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch {
        return self.finish(line: nil, error: "Couldn't start Claude Code: \(error.localizedDescription)")
      }
      LiveProcesses.add(process)
      // Connectors can take a while to connect; past 45 s the probe gives up.
      DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
        MainActor.assumeIsolated { if process.isRunning { process.terminate() } }
      }
      DispatchQueue.global(qos: .userInitiated).async {
        try? stdin.fileHandleForWriting.write(contentsOf: Data("Reply with ok".utf8))
        try? stdin.fileHandleForWriting.close()
        let line = Self.initLine(from: stdout.fileHandleForReading)
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        DispatchQueue.main.async { MainActor.assumeIsolated { LiveProcesses.remove(process) } }
        // `claude mcp list` waits for each server's health check, so its statuses win over the init event's (a
        // connector still "pending" there, or one Claude Code remembers needing a sign-in).
        let listed = Self.mcpList(found: found, environment: environment, folder: folder).flatMap(TrackerProbe.servers(mcpList:))
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self.finish(line: line, listed: listed,
                        error: line == nil && listed == nil ? "Claude Code didn't say which connectors it has." : nil)
          }
        }
      }
    }
  }

  /// `claude mcp add --transport http --scope user <name> <url>` (Settings → Connectors' Add to Claude Code): nil
  /// when added or already there, else what went wrong.
  public func addServer(name: String, url: String, then: @escaping @MainActor (String?) -> Void) {
    run(["mcp", "add", "--transport", "http", "--scope", "user", name, url], tolerating: "already exists", then: then)
  }

  /// Adds a tool at user scope (`ToolsCatalog.addArguments`: an https address or a command line), then asks again
  /// which servers there are. Nil when added or already there, else what went wrong.
  public func addTool(name: String, target: String, then: @escaping @MainActor (String?) -> Void) {
    guard let arguments = ToolsCatalog.addArguments(name: name, target: target) else {
      return then("Give it a name and an https address or a command.")
    }
    run(arguments, tolerating: "already exists") { [weak self] error in
      if error == nil { self?.check(force: true) }
      then(error)
    }
  }

  /// Removes a tool added at user scope, then asks again which servers there are.
  public func removeTool(name: String, then: @escaping @MainActor (String?) -> Void) {
    run(ToolsCatalog.removeArguments(name: name), tolerating: nil) { [weak self] error in
      if error == nil { self?.check(force: true) }
      then(error)
    }
  }

  /// One `claude` run with `arguments` (no model turn: the `mcp` commands): nil when it succeeds or its output
  /// holds `tolerating`, else the output's last line.
  private func run(_ arguments: [String], tolerating: String?, then: @escaping @MainActor (String?) -> Void) {
    capture(arguments) { ok, text in
      let tolerated = tolerating.map { text.lowercased().contains($0) } == true
      then(ok || tolerated ? nil : (text.split(separator: "\n").last.map(String.init) ?? "Claude Code couldn't do that."))
    }
  }

  /// One `claude` run with `arguments`: whether it exited 0, and everything it printed (stdout and stderr).
  private func capture(_ arguments: [String], then: @escaping @MainActor (Bool, String) -> Void) {
    ClaudeLocator.locate { found in
      guard let found else { return then(false, "Claude Code isn't installed.") }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: found.executable)
      process.arguments = arguments
      process.currentDirectoryURL = URL(fileURLWithPath: ClaudeOneShot.scratchFolder)
      var environment = ProcessInfo.processInfo.environment
      if let path = found.path { environment["PATH"] = path }
      environment["CLAUDECODE"] = nil
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      process.standardError = output
      process.standardInput = FileHandle.nullDevice
      do { try process.run() } catch { return then(false, "Couldn't start Claude Code: \(error.localizedDescription)") }
      // A server that hangs mustn't hang the button: past 60 s the run is stopped.
      let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
      DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
      DispatchQueue.global(qos: .userInitiated).async {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = process.terminationStatus == 0
        DispatchQueue.main.async { MainActor.assumeIsolated { then(ok, text) } }
      }
    }
  }

  /// Asks Claude Code about one server (`claude mcp get <name>`, which connects it): its status is updated in place
  /// and `then` gets what Claude Code printed about it (the details a failing row shows), or nil when it printed
  /// nothing.
  public func recheck(name: String, then: @escaping @MainActor (String?) -> Void) {
    capture(["mcp", "get", name]) { [weak self] _, text in
      if let self, let status = ToolsCatalog.status(mcpGet: text),
         let index = self.servers.firstIndex(where: { $0.name == name }) {
        self.servers[index] = ConnectorServer(name: name, status: status)
      }
      then(text.isEmpty ? nil : text)
    }
  }

  /// `claude mcp list`'s output, or nil when it didn't finish within 60 s.
  nonisolated private static func mcpList(found: ClaudeLocator.Found, environment: [String: String],
                                          folder: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = ["mcp", "list"]
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timer.cancel()
    return process.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
  }

  /// Reads lines until the init event (at most 50 lines), or the end.
  nonisolated private static func initLine(from handle: FileHandle) -> String? {
    var buffer = Data()
    var lines = 0
    while lines < 50 {
      let chunk = handle.availableData
      if chunk.isEmpty { break }
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
        buffer.removeSubrange(buffer.startIndex...newline)
        lines += 1
        if TrackerProbe.trackers(initLine: line) != nil { return line }
      }
    }
    return nil
  }

  private func finish(line: String?, listed: [ConnectorServer]? = nil, error: String?) {
    checking = false
    checked = true
    self.error = error
    if let line {
      initLine = line
      trackers = TrackerProbe.trackers(initLine: line, listed: listed) ?? []
      servers = TrackerProbe.servers(initLine: line) ?? []
    }
    if let listed { servers = listed }
    flush()
  }

  private func flush() {
    let waiting = waiters
    waiters = []
    waiting.forEach { $0() }
  }
}
