import Darwin
import Foundation
import GlanceCore

/// Claude Code run once, headless, for a short piece of text (the PR page's read of a pull request): `claude` with the
/// given arguments in a project folder, or `scratchFolder` without one, the prompt on stdin, its JSON result back (or,
/// with none, the last line it wrote to stderr). Nothing is kept.
@MainActor
public enum ClaudeOneShot {
  /// A run under way. `cancel()` ends it; its completion then isn't called. Only touched on the main thread (the
  /// callers are UI, and the closures that read it hop to main first), which is why it's Sendable.
  public final class Run: @unchecked Sendable {
    var process: Process?
    var cancelled = false
    var timedOut = false

    public func cancel() {
      cancelled = true
      if let process, process.isRunning { process.terminate() }
    }
  }

  /// Where a one-shot runs without a project folder (`$TMPDIR/glance-claude`): it only reads its prompt.
  public static var scratchFolder: String {
    let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-claude")
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Where Claude Code is, or nil when it isn't installed (or isn't on the login shell's PATH).
  public static func locate(_ completion: @escaping @MainActor (String?) -> Void) {
    ClaudeLocator.locate { completion($0?.executable) }
  }

  /// Where Claude Code is and the login shell's PATH to run it with (an npm install needs `node` on it), or nil when
  /// it isn't installed.
  public static func locateWithPath(_ completion: @escaping @MainActor ((executable: String, path: String?)?) -> Void) {
    ClaudeLocator.locate { found in completion(found.map { ($0.executable, $0.path) }) }
  }

  /// `environment` adds to the app's own (Tickets' `TrackerProbe.waitForConnectors`).
  @discardableResult
  public static func run(arguments: [String], prompt: String, folder: String?, timeout: TimeInterval? = nil,
                         environment extra: [String: String] = [:],
                         completion: @escaping @MainActor (Result<String, PullRequestClaude.Failure>) -> Void) -> Run {
    let run = Run()
    ClaudeLocator.locate { found in
      guard !run.cancelled else { return }
      guard let found else {
        completion(.failure(.notInstalled))
        return
      }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: found.executable)
      process.arguments = arguments
      process.currentDirectoryURL = URL(fileURLWithPath: folder ?? scratchFolder)
      var environment = ProcessInfo.processInfo.environment
      if let path = found.path { environment["PATH"] = path }
      environment["CLAUDECODE"] = nil
      environment.merge(extra) { $1 }
      process.environment = environment
      let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
      // A write after Claude exits must fail, not kill the app with SIGPIPE.
      _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
      process.standardInput = stdin
      process.standardOutput = stdout
      process.standardError = stderr
      do {
        try process.run()
      } catch {
        completion(.failure(.init(kind: .failed, message: "Couldn't start Claude Code: \(error.localizedDescription)")))
        return
      }
      run.process = process
      LiveProcesses.add(process)
      if let timeout {
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
          MainActor.assumeIsolated {
            guard process.isRunning, !run.cancelled else { return }
            run.timedOut = true
            process.terminate()
          }
        }
      }
      let input = Data(prompt.utf8)
      DispatchQueue.global(qos: .userInitiated).async {
        // stderr drains on its own thread from the start, so a chatty run can't fill its pipe while the prompt is
        // written or stdout read.
        let errors = Drain()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue(label: "ClaudeOneShot.stderr", qos: .utility).async {
          errors.data = stderr.fileHandleForReading.readDataToEndOfFile()
          group.leave()
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let result = PullRequestClaude.result(output, errors: errors.data)
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            LiveProcesses.remove(process)
            guard !run.cancelled else { return }
            completion(run.timedOut
              ? .failure(.init(kind: .failed, message: "Claude Code took longer than \(Int(timeout ?? 0)) seconds."))
              : result)
          }
        }
      }
    }
    return run
  }

  private final class Drain: @unchecked Sendable {
    var data = Data()
  }
}
