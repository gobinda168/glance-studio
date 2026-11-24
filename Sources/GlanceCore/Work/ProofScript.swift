import Darwin
import Foundation

/// Runs a project's setup script (a `urlScript`, spec §3): the user's login shell, a time limit, and the script's own
/// process group so that a timeout takes its children with it. Blocking: call off the main thread.
public enum ProofScript {
  public enum Outcome: Equatable, Sendable { case output(String), failed(String) }

  /// Runs `script` (a path, relative to `root` unless absolute) with `root` as its working directory and `environment`
  /// on top of Glance's own. A script that fails or runs past `timeout` seconds returns what it printed.
  ///
  /// The script's output is read while it runs and the run ends when the script itself ends: a background child that
  /// keeps the output open does not hold the call, and is left running (a timeout stops the whole group).
  public static func run(_ script: String, root: String, environment: [String: String] = [:],
                         timeout: TimeInterval = 30) -> Outcome {
    let path = script.hasPrefix("/") ? script : root + "/" + script
    return execute("exec " + shellQuoted(path), named: script, root: root, environment: environment, timeout: timeout,
                   stop: nil)
  }

  /// Ends a `runCommand` from another thread: its whole process group gets TERM, then KILL.
  public final class Stop: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    public init() {}
    public func cancel() { lock.lock(); set = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return set }
  }

  /// Runs a command line (`explainer.command`): `zsh -lc <command>` in `root`, so arguments, `&&` and the user's own
  /// PATH work. Everything else is as `run`: the same group, limit and output. `stop.cancel()` ends it like a timeout
  /// does (the outcome says it was stopped); a `stop` already set never starts it.
  public static func runCommand(_ command: String, root: String, environment: [String: String] = [:],
                                timeout: TimeInterval = 30, stop: Stop? = nil) -> Outcome {
    execute(command, named: command.count > 60 ? String(command.prefix(60)) + "…" : command, root: root,
            environment: environment, timeout: timeout, stop: stop)
  }

  /// `zsh -lc <shell>` as a process group of its own; `name` is what the failure messages call it.
  private static func execute(_ shell: String, named script: String, root: String, environment: [String: String],
                              timeout: TimeInterval, stop: Stop?) -> Outcome {
    if stop?.isCancelled == true { return .failed("\(script) was stopped before it started.") }
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { return .failed("Couldn't run \(script): no pipe.") }
    let (readFD, writeFD) = (fds[0], fds[1])
    // Neither end leaks into the script except as its stdout and stderr (dup2 below clears the flag on those).
    _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
    defer { close(readFD) }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&actions, writeFD, 1)
    posix_spawn_file_actions_adddup2(&actions, writeFD, 2)
    posix_spawn_file_actions_addchdir_np(&actions, root)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t(), none = sigset_t()
    sigfillset(&defaults)
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setsigmask(&attributes, &none)
    posix_spawnattr_setpgroup(&attributes, 0)
    // CLOEXEC_DEFAULT (0x4000, as Foundation's Process uses): the script gets only 0-2, not every descriptor Studio has
    // open, so it can't hold another run's pipe (a `gh` call's) open from a server it leaves behind.
    let cloexecDefault: Int32 = 0x4000
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
      | cloexecDefault))

    let arguments = ["/bin/zsh", "-lc", shell]
    let merged = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = merged.map { strdup($0.key + "=" + $0.value) } + [nil]
    defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

    var pid: pid_t = 0
    let started = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv, envp)
    close(writeFD)
    guard started == 0 else {
      return .failed("Couldn't run \(script): \(String(cString: strerror(started))).")
    }
    _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)

    var data = Data()
    var status: Int32 = 0
    var exited = false
    let deadline = Date().addingTimeInterval(timeout)
    var open = true
    while !exited {
      if open {
        var watch = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        poll(&watch, 1, 50)
        open = drain(readFD, into: &data, limit: 256 * 1024)
      } else {
        usleep(20_000)
      }
      exited = reap(pid, &status, wait: false)
      if !exited, stop?.isCancelled == true {
        stopGroup(pid, &status)
        _ = drain(readFD, into: &data, limit: 1_048_576)
        return .failed("\(script) was stopped." + tail(of: data, prefix: "\n"))
      }
      if !exited, Date() >= deadline {
        stopGroup(pid, &status)
        _ = drain(readFD, into: &data, limit: 1_048_576)
        return .failed("\(script) took longer than \(Int(timeout)) s and was stopped." + tail(of: data, prefix: "\n"))
      }
    }
    _ = drain(readFD, into: &data, limit: 1_048_576)
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    if status & 0x7f != 0 {
      return .failed("\(script) was stopped by signal \(status & 0x7f)." + tail(of: data, prefix: "\n"))
    }
    let code = (status >> 8) & 0xff
    guard code == 0 else {
      return .failed("\(script) exited with \(code)" + (text.isEmpty ? "." : ":\n" + String(text.suffix(2000))))
    }
    return .output(text)
  }

  /// The URL a script printed: its last non-empty line that is an http(s) address, so a script that prints progress
  /// first, or a login shell that greets, still works. Nil when no line is one.
  public static func lastURL(in output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline).reversed() {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix("http://") || text.hasPrefix("https://"), !text.contains(where: \.isWhitespace),
            let url = URL(string: text), url.host?.isEmpty == false else { continue }
      return text
    }
    return nil
  }

  static func shellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  // MARK: - Process plumbing

  /// Reads what is there, at most `limit` bytes so a flood can't keep the caller from its deadline. False once the
  /// other end has closed. Keeps the last ~512 KB of what it reads.
  private static func drain(_ fd: Int32, into data: inout Data, limit: Int) -> Bool {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    var total = 0
    while total < limit {
      let n = read(fd, &buffer, buffer.count)
      if n > 0 {
        total += n
        data.append(contentsOf: buffer[0..<n])
        if data.count > 1_048_576 { data = data.suffix(524_288) }
      } else if n == 0 {
        return false
      } else if errno == EINTR {
        continue
      } else {
        return true  // EAGAIN: nothing more for now
      }
    }
    return true  // the limit: maybe more, so not closed
  }

  /// True when the process has ended (its wait status in `status`).
  private static func reap(_ pid: pid_t, _ status: inout Int32, wait: Bool) -> Bool {
    while true {
      let r = waitpid(pid, &status, wait ? 0 : WNOHANG)
      if r == pid { return true }
      if r == 0 { return false }
      if errno == EINTR { continue }
      return true  // ECHILD: gone already
    }
  }

  /// TERM to the group, then KILL after a short grace, children included.
  private static func stopGroup(_ pid: pid_t, _ status: inout Int32) {
    kill(-pid, SIGTERM)
    var ended = false
    for _ in 0..<40 where !ended {
      ended = reap(pid, &status, wait: false)
      if !ended { usleep(50_000) }
    }
    kill(-pid, SIGKILL)
    if !ended { _ = reap(pid, &status, wait: true) }
  }

  private static func tail(of data: Data, prefix: String) -> String {
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? "" : prefix + String(text.suffix(2000))
  }
}
