import Foundation

/// Runs `/usr/bin/git -C root …` for the tracking code: its output, or nil when git fails. (Each git helper in
/// GlanceCore keeps its own small runner.)
///
/// It waits for the exit with a `terminationHandler` and a semaphore, not `Process.waitUntilExit()`: without a run
/// loop (the `glance` CLI) `waitUntilExit()` polls and adds about 65 ms to every spawn, which blows the hook budget.
///
/// git runs with `GIT_OPTIONAL_LOCKS=0`, so a `git status` never takes the index lock from the user's own git, and
/// `GIT_LITERAL_PATHSPECS=1`, so a path such as `app/[id]/page.tsx` names that file and isn't a glob.
///
/// Public for GlanceKit's recap loader. Blocking: never call it on the main thread.
public enum GitRun {
  static let environment = ProcessInfo.processInfo.environment
    .merging(["GIT_OPTIONAL_LOCKS": "0", "GIT_LITERAL_PATHSPECS": "1"]) { _, ours in ours }

  /// With a `timeout`, git is terminated when it runs longer and the result is nil.
  public static func data(_ root: String, _ arguments: [String], timeout: TimeInterval? = nil) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", root] + arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() } // set before run(), or a fast exit could be missed
    do { try process.run() } catch { return nil }
    let expired = Expiry()
    let killer = DispatchWorkItem { if process.isRunning { expired.set(); process.terminate() } }
    if let timeout { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    killer.cancel()
    return process.terminationStatus == 0 && !expired.value ? data : nil
  }

  private final class Expiry: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
  }

  public static func text(_ root: String, _ arguments: [String], timeout: TimeInterval? = nil) -> String? {
    data(root, arguments, timeout: timeout).map { String(decoding: $0, as: UTF8.self) }
  }
}
