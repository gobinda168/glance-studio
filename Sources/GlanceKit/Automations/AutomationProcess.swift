import Darwin
import Foundation

/// A child process in a process group of its own (spec "Timeouts and cancel": a timeout or cancel ends everything the
/// step started — SIGTERM to the group, SIGKILL 3 s later), its stdout and stderr streamed as they come. Foundation's
/// `Process` can't start a new process group, hence posix_spawn. Callbacks arrive on background threads.
final class AutomationProcess: @unchecked Sendable {
  enum Failure: Error, CustomStringConvertible {
    case pipes
    case spawn(String, Int32)

    var description: String {
      switch self {
      case .pipes: "Couldn't open pipes for the process."
      case .spawn(let executable, let code): "Couldn't start \(executable): \(String(cString: strerror(code)))"
      }
    }
  }

  /// The executable first.
  let arguments: [String]
  let environment: [String: String]
  let directory: String
  private let lock = NSLock()
  private var pid: pid_t = 0
  private var exited = false

  init(arguments: [String], environment: [String: String], directory: String) {
    self.arguments = arguments
    self.environment = environment
    self.directory = directory
  }

  /// Starts it with `stdin` written then closed. `output` gets each chunk (`true` for stderr); `exit` gets the exit
  /// status (128 + the signal when killed) once both streams are drained — or 2 s after the process ended, when
  /// something it left running still holds them (that group is killed), or 3 s after that when something outside the group still holds them.
  func start(stdin: Data?, output: @escaping @Sendable (Data, Bool) -> Void,
             exit: @escaping @Sendable (Int32) -> Void) throws {
    var input: [Int32] = [-1, -1], out: [Int32] = [-1, -1], err: [Int32] = [-1, -1]
    guard pipe(&input) == 0, pipe(&out) == 0, pipe(&err) == 0 else {
      for fd in input + out + err where fd >= 0 { close(fd) }
      throw Failure.pipes
    }
    // Only the child's dup2'd copies (which don't carry the flag) may reach the process.
    for fd in input + out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, input[0], 0)
    posix_spawn_file_actions_adddup2(&actions, out[1], 1)
    posix_spawn_file_actions_adddup2(&actions, err[1], 2)
    posix_spawn_file_actions_addchdir_np(&actions, directory)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    // Its own group; nothing else inherited; default signal handling (Studio ignores SIGPIPE, a script mustn't).
    let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var noMask = sigset_t(0)
    posix_spawnattr_setsigmask(&attributes, &noMask)
    var everyDefault = sigset_t(UInt32.max)
    posix_spawnattr_setsigdefault(&attributes, &everyDefault)
    let argv = arguments.map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      argv.forEach { free($0) }
      envp.forEach { free($0) }
    }
    var child: pid_t = 0
    let code = posix_spawn(&child, arguments[0], &actions, &attributes, argv, envp)
    close(input[0])
    close(out[1])
    close(err[1])
    guard code == 0 else {
      close(input[1])
      close(out[0])
      close(err[0])
      throw Failure.spawn(arguments[0], code)
    }
    lock.withLock { pid = child }
    let streams = DispatchGroup()
    for (fd, isError) in [(out[0], false), (err[0], true)] {
      streams.enter()
      Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
          let count = read(fd, &buffer, buffer.count)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { break }
          output(Data(buffer[0..<count]), isError)
        }
        close(fd)
        streams.leave()
      }
    }
    let writer = input[1]
    _ = fcntl(writer, F_SETNOSIGPIPE, 1)
    Thread.detachNewThread {
      if let stdin, !stdin.isEmpty {
        stdin.withUnsafeBytes { bytes in
          var offset = 0
          while offset < bytes.count {
            let written = write(writer, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { break }
            offset += written
          }
        }
      }
      close(writer)
    }
    Thread.detachNewThread { [self] in
      var status: Int32 = 0
      while waitpid(child, &status, 0) == -1, errno == EINTR {}
      lock.withLock { exited = true }
      if streams.wait(timeout: .now() + 2) == .timedOut {
        killpg(child, SIGKILL)
        // Something outside the group (a daemon that started its own) may hold the pipes for good; don't wait for it.
        _ = streams.wait(timeout: .now() + 1)
      }
      let signal = status & 0x7f
      exit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }
  }

  /// SIGTERM to the whole group, then SIGKILL after 3 s if it's still there.
  func terminateGroup() {
    let target = lock.withLock { pid }
    guard target > 0 else { return }
    killpg(target, SIGTERM)
    // Even when the leader is gone: a member that ignored SIGTERM may still be running. A group id can't be reused
    // while any member exists, and an empty group just answers ESRCH.
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
      killpg(target, SIGKILL)
    }
  }

  /// SIGKILL to the whole group at once (what is left of it after `terminateGroup`'s grace, for a quitting app).
  func killGroup() {
    let target = lock.withLock { pid }
    guard target > 0 else { return }
    killpg(target, SIGKILL)
  }

  var hasExited: Bool { lock.withLock { exited } }
}
