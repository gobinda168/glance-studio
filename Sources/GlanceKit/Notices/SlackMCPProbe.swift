import Combine
import Darwin
import Foundation
import GlanceCore

/// Whether Claude Code has the user's Slack connector (spec 2026-10-09-notifications-design.md, "Slack MCP
/// detection"): a short `claude` run whose first stream-json line, the `system`/`init` event, lists the MCP servers and
/// their tools. Only that line is read, then the run is ended: nothing is asked of the model. The answer is kept for
/// the run of the app until `check(force: true)` (Settings' Check again).
@MainActor
public final class SlackMCPProbe: ObservableObject {
  public static let shared = SlackMCPProbe()

  /// Nil until the first check ends.
  @Published public private(set) var status: SlackMCP.Status?
  @Published public private(set) var checking = false
  /// Why the last check couldn't tell (Claude Code missing, no answer); nil when it could.
  @Published public private(set) var problem: String?

  /// How long to wait for the init line: MCP servers connect before it's printed.
  private static let timeout: TimeInterval = 45
  /// claude.ai connectors are often still connecting when the init line is printed (Slack "pending", no tools yet):
  /// the check asks again, a few seconds apart, before it says Slack isn't there.
  private static let pendingTries = 4
  private static let pendingPause: TimeInterval = 3
  private var tries = 0

  static let arguments = ["-p", "--output-format", "stream-json", "--verbose", "--max-turns", "1", "--model", "haiku",
                          "--tools", "", "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#]

  private init() {}

  /// Checks once; later calls keep the answer unless `force`. A check under way is left to finish.
  public func check(force: Bool = false) {
    guard !checking, force || status == nil else { return }
    checking = true
    tries = 0
    ClaudeLocator.locate { [weak self] found in
      guard let self else { return }
      guard let found else {
        return self.finish(.disconnected, problem: "Claude Code isn't installed or isn't on PATH.")
      }
      self.probe(found)
    }
  }

  private func probe(_ found: ClaudeLocator.Found) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = Self.arguments
    process.currentDirectoryURL = URL(fileURLWithPath: ClaudeOneShot.scratchFolder)
    var environment = ProcessInfo.processInfo.environment
    if let path = found.path { environment["PATH"] = path }
    environment["CLAUDECODE"] = nil
    process.environment = environment
    let stdin = Pipe(), stdout = Pipe()
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return finish(.disconnected, problem: "Couldn't start Claude Code: \(error.localizedDescription)")
    }
    LiveProcesses.add(process)
    // No init line in time: end the run; the reader then sees the end of output.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
      if process.isRunning { process.terminate() }
    }
    DispatchQueue(label: "dev.glance.SlackMCPProbe", qos: .utility).async { [weak self] in
      try? stdin.fileHandleForWriting.write(contentsOf: Data("Reply with ok".utf8))
      try? stdin.fileHandleForWriting.close()
      let line = Self.firstLine(stdout.fileHandleForReading)
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      let status = line.flatMap(SlackMCP.status(initLine:))
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          LiveProcesses.remove(process)
          guard let self else { return }
          if let status, status.pending, self.tries + 1 < Self.pendingTries {
            self.tries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pendingPause) {
              MainActor.assumeIsolated { self.probe(found) }
            }
          } else if let status {
            self.finish(status, problem: status.pending ? "Slack was still connecting in Claude Code." : nil)
          } else {
            self.finish(.disconnected, problem: "Claude Code didn't say which connectors it has.")
          }
        }
      }
    }
  }

  private func finish(_ status: SlackMCP.Status, problem: String?) {
    self.status = status
    self.problem = problem
    checking = false
  }

  /// Bytes up to the first newline (or the end of output).
  nonisolated private static func firstLine(_ handle: FileHandle) -> String? {
    var buffer = Data()
    while true {
      let data = handle.availableData
      if data.isEmpty { break }
      if let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
        buffer.append(data[data.startIndex..<newline])
        break
      }
      buffer.append(data)
      if buffer.count > 4 << 20 { return nil }
    }
    let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
  }
}
