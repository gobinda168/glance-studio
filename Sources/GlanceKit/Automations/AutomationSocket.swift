import Combine
import Darwin
import Foundation
import GlanceCore

/// The Unix socket between `glance automation mcp` and the engine (spec 2026-10-09-automations-design.md, "Claude:
/// skill + Glance MCP"): `automation_run` and `automation_runs` go through it. Newline-delimited JSON, one request
/// per connection (`AutomationSocketRequest` / `AutomationSocketResponse`). Only this user can connect: the folder
/// is 0700, the socket 0600, and the server checks the peer's uid.
public enum AutomationSocket {
  /// A sockaddr_un for `path`; nil when the path doesn't fit.
  static func address(_ path: String) -> sockaddr_un? {
    guard AutomationSocketWire.fits(path) else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return address
  }

  static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
  }

  /// Sends one request and waits up to `timeout` seconds for the answer (the CLI's side; blocking). Studio not
  /// listening is `AutomationSocketWire.notRunning`.
  public static func send(_ request: AutomationSocketRequest, path: String,
                          timeout: TimeInterval) -> AutomationSocketResponse {
    guard var address = address(path) else { return .failed("The socket path is too long: \(path)") }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return .failed("Couldn't open a socket (errno \(errno)).") }
    defer { close(descriptor) }
    var on: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    // A zero timeval means "wait forever": never less than a second, and the fraction goes in tv_usec.
    let seconds = max(timeout, 1)
    var wait = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
    guard withSockaddr(&address, { connect(descriptor, $0, $1) }) == 0 else {
      return .failed(AutomationSocketWire.notRunning)
    }
    guard writeAll(descriptor, Data((request.line + "\n").utf8), within: writeLimit) else {
      return .failed("Couldn't reach Glance Studio (errno \(errno)).")
    }
    var received = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = read(descriptor, &chunk, chunk.count)
      if count > 0 {
        received.append(contentsOf: chunk[0..<count])
        if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
          return .parse(String(decoding: received[received.startIndex..<newline], as: UTF8.self))
        }
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        return .failed("Glance Studio didn't answer within \(Int(seconds)) seconds.")
      }
      return .failed("Glance Studio closed the connection before it answered (did it quit?).")
    }
  }

  /// Whether something is listening at `path` (a connect that succeeds, or that would have to wait for room).
  static func accepts(_ path: String) -> Bool {
    guard var address = address(path) else { return false }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    if withSockaddr(&address, { connect(descriptor, $0, $1) }) == 0 { return true }
    return errno == EAGAIN || errno == EINPROGRESS
  }

  /// The most time a whole request or answer may take to write.
  static let writeLimit: TimeInterval = 10

  /// Writes all of `data`, giving up when `limit` seconds have passed in all (a reader that takes a byte at a time
  /// can't hold the writer: each write waits only for what is left of the limit).
  static func writeAll(_ descriptor: Int32, _ data: Data, within limit: TimeInterval = writeLimit) -> Bool {
    let end = DispatchTime.now().uptimeNanoseconds + UInt64(limit * 1_000_000_000)
    return data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return true }
      var offset = 0
      while offset < raw.count {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { return false }
        let left = Double(end - now) / 1_000_000_000
        var wait = timeval(tv_sec: Int(left), tv_usec: Int32(max((left - left.rounded(.down)) * 1_000_000, 1000)))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        let written = write(descriptor, base + offset, raw.count - offset)
        if written < 0, errno == EINTR { continue }
        guard written > 0 else { return false }
        offset += written
      }
      return true
    }
  }
}

/// How many clients are connected now. Touched only on the socket's queue.
private final class AutomationSocketCount: @unchecked Sendable {
  var open = 0
}

/// One client: its descriptor, the bytes so far, and one answer. Its state is touched only on the socket's queue.
private final class AutomationSocketConnection: @unchecked Sendable {
  let descriptor: Int32
  var buffer = Data()
  var source: DispatchSourceRead?
  /// A whole request line came (or was refused): anything after it is ignored (one request per connection).
  var requested = false
  private var closed = false
  /// The read source's cancel handler ran: closing the descriptor is up to `close()` now.
  private var readerGone = false
  private let queue: DispatchQueue
  private var deadline: DispatchSourceTimer?
  /// Tells the server this client is gone (on the socket's queue), for its count of open connections.
  var onClosed: (() -> Void)?

  init(descriptor: Int32, queue: DispatchQueue) {
    self.descriptor = descriptor
    self.queue = queue
  }

  /// A client that hasn't sent a whole request line within `seconds` of connecting is dropped (on the socket's queue),
  /// so one that stalls or trickles bytes can't hold a descriptor.
  func startDeadline(_ seconds: TimeInterval) {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler { [weak self] in
      guard let self, !self.requested else { return }
      self.close()
    }
    deadline = timer
    timer.resume()
  }

  /// The whole request line came (or the request was refused): the read deadline no longer applies.
  func requestArrived() {
    requested = true
    deadline?.cancel()
    deadline = nil
  }

  /// Writes the answer and closes (on the socket's queue). Once.
  func answer(_ response: AutomationSocketResponse) {
    queue.async {
      guard !self.closed else { return }
      _ = AutomationSocket.writeAll(self.descriptor, Data((response.line + "\n").utf8))
      self.close()
    }
  }

  /// The client finished writing after its request: stop reading, keep the descriptor for the answer.
  func stopReading() {
    source?.cancel()
    source = nil
  }

  /// The read source's cancel handler.
  func readerCancelled() {
    readerGone = true
    if closed { Darwin.close(descriptor) }
  }

  /// Done with this client. The descriptor closes once its read source is gone (dispatch's rule).
  func close() {
    guard !closed else { return }
    closed = true
    deadline?.cancel()
    deadline = nil
    onClosed?()
    onClosed = nil
    if readerGone { Darwin.close(descriptor) } else { stopReading() }
  }
}

/// The engine's end of the socket. Studio starts one at launch (`GlanceTerminalHost.startAutomations`), and
/// `glance automation serve --socket <path>` one of its own for the CLI checks.
@MainActor
public final class AutomationSocketServer {
  public let path: String
  private let engine: AutomationEngine
  private let queue = DispatchQueue(label: "dev.glance.automation-socket")
  private var listener: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var waits: [UUID: AnyCancellable] = [:]
  private var waiting: [UUID: AutomationSocketConnection] = [:]
  /// The longest a request line is (bytes, without its line break).
  nonisolated static let maxRequestBytes = 1_000_000
  /// Clients connected at once; the ones past it are closed right after accept, without a reply.
  nonisolated static let maxConnections = 32
  private let connections = AutomationSocketCount()
  /// How long a client has to send its request line after connecting.
  private let requestTimeout: TimeInterval

  public init(engine: AutomationEngine, path: String, requestTimeout: TimeInterval = 10) {
    self.engine = engine
    self.path = path
    self.requestTimeout = requestTimeout
  }

  /// Why `path` can't be listened on: it holds something that isn't a socket of ours, or a server that answers. nil
  /// when it is free or holds only a stale socket (which this removes). Never deletes anything but that.
  private func clearStaleSocket() -> String? {
    var info = stat()
    if lstat(path, &info) != 0 { return errno == ENOENT ? nil : "Couldn't look at \(path) (errno \(errno))." }
    guard (info.st_mode & S_IFMT) == S_IFSOCK else {
      return "\(path) exists and isn't a socket; Glance won't touch it."
    }
    guard info.st_uid == getuid() else { return "\(path) belongs to another user; Glance won't touch it." }
    if AutomationSocket.accepts(path) { return "Another Glance is already listening at \(path)." }
    unlink(path) // a socket left by a Studio that crashed
    return nil
  }

  /// Listens at `path`, replacing a stale socket there. nil when it listens; otherwise why not.
  public func start() -> String? {
    guard listener < 0 else { return nil }
    guard var address = AutomationSocket.address(path) else { return "The socket path is too long: \(path)" }
    let folder = (path as NSString).deletingLastPathComponent
    // The folder is 0700 when this makes it, and when it is Glance's own (`.../Glance`); any other folder the CLI is
    // pointed at keeps its permissions (the socket itself is 0600 and the server checks the peer's uid either way).
    let made = !FileManager.default.fileExists(atPath: folder)
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    var folderInfo = stat()
    let ours = stat(folder, &folderInfo) == 0 && folderInfo.st_uid == getuid()
    if ours, made || (folder as NSString).lastPathComponent == "Glance" { chmod(folder, 0o700) }
    if let problem = clearStaleSocket() { return problem }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return "Couldn't open a socket (errno \(errno))." }
    // In a private folder (Studio's own) bind then chmod 0600 is enough: nobody else can reach the file in between,
    // and the process-wide umask stays alone. In any other folder (the CLI's custom paths) the umask makes it 0600
    // from the moment it exists, and is put back right after.
    let privateFolder = ours && stat(folder, &folderInfo) == 0 && folderInfo.st_mode & 0o077 == 0
    let previousMask = privateFolder ? nil : umask(0o177)
    let bound = AutomationSocket.withSockaddr(&address) { bind(descriptor, $0, $1) }
    if let previousMask { umask(previousMask) }
    guard bound == 0 else {
      let reason = "Couldn't listen at \(path) (errno \(errno))."
      close(descriptor)
      return reason
    }
    guard chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else {
      let reason = "Couldn't listen at \(path) (errno \(errno))."
      close(descriptor)
      unlink(path)
      return reason
    }
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    listener = descriptor
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    let queue = self.queue
    let requestTimeout = self.requestTimeout
    let count = self.connections
    source.setEventHandler { [weak self] in
      while true {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else {
          if errno == EMFILE || errno == ENFILE {
            // Out of descriptors: the listener would fire again at once. Rest a second, then go on.
            source.suspend()
            queue.asyncAfter(deadline: .now() + 1) { source.resume() }
          }
          return
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), count.open < Self.maxConnections else {
          close(client)
          continue
        }
        count.open += 1
        // Accepted sockets inherit O_NONBLOCK: reads happen when the source says there's data, writes block.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connection = AutomationSocketConnection(descriptor: client, queue: queue)
        connection.onClosed = { count.open -= 1 }
        let reader = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        connection.source = reader
        reader.setEventHandler { [weak self] in Self.readable(connection, server: self) }
        reader.setCancelHandler { connection.readerCancelled() }
        reader.resume()
        connection.startDeadline(requestTimeout)
      }
    }
    source.setCancelHandler { Darwin.close(descriptor) }
    source.resume()
    acceptSource = source
    return nil
  }

  /// Stops listening; runs being waited for get an answer saying so.
  public func stop() {
    acceptSource?.cancel()
    acceptSource = nil
    if listener >= 0 { unlink(path) }
    listener = -1
    waits.removeAll()
    for connection in waiting.values { connection.answer(.failed("Glance Studio stopped automations.")) }
    waiting.removeAll()
  }

  /// On the socket's queue: reads what came, and hands a whole line to the main thread.
  private nonisolated static func readable(_ connection: AutomationSocketConnection,
                                           server: AutomationSocketServer?) {
    var chunk = [UInt8](repeating: 0, count: 65536)
    let count = read(connection.descriptor, &chunk, chunk.count)
    guard count > 0 else {
      // End of input: after a request the client may still read the answer; before one, it went away.
      if connection.requested { connection.stopReading() } else { connection.close() }
      return
    }
    guard !connection.requested else { return }
    // Never more than the cap plus one chunk is held: a longer request is refused as soon as it passes the cap.
    connection.buffer.append(contentsOf: chunk[0..<count])
    let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n"))
    let length = (newline ?? connection.buffer.endIndex) - connection.buffer.startIndex
    guard length <= maxRequestBytes else {
      connection.requestArrived()
      connection.buffer = Data()
      connection.answer(.failed("The request is too long."))
      return
    }
    guard let newline else { return }
    let line = String(decoding: connection.buffer[connection.buffer.startIndex..<newline], as: UTF8.self)
    connection.requestArrived()
    connection.buffer = Data()
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        guard let server else { return connection.answer(.failed(AutomationSocketWire.notRunning)) }
        server.handle(line, connection)
      }
    }
  }

  private func handle(_ line: String, _ connection: AutomationSocketConnection) {
    // A request that was already on its way to the main thread when `stop()` ran.
    guard listener >= 0 else { return connection.answer(.failed(AutomationSocketWire.notRunning)) }
    switch AutomationSocketRequest.parse(line) {
    case .failure(let refusal):
      connection.answer(.failed(refusal.message))
    case .success(.status):
      connection.answer(.ok(.object([
        "version": .string(AppVersion.current.full),
        "live": .array(engine.live.map { run in
          .object(["automation": .string(run.ref.automation), "run": .string(run.ref.run),
                   "step": run.step.map(AutomationValue.string) ?? .null, "parked": .bool(run.parked)])
        }),
      ])))
    case .success(.runs(let id, let run, let limit)):
      guard engine.entry(id) != nil else { return connection.answer(.failed(AutomationMCPText.notFound(id))) }
      if let run {
        guard let record = engine.runs(id, limit: 200).first(where: { $0.id == run }) else {
          return connection.answer(.failed("\(id) has no run \(run)."))
        }
        connection.answer(.ok(AutomationSocketWire.runDetail(record)))
      } else {
        connection.answer(.ok(AutomationSocketWire.runsResult(engine.runs(id, limit: limit))))
      }
    case .success(.run(let id, let inputs, let wait)):
      run(id, inputs: inputs, wait: wait, connection)
    }
  }

  /// A run from Claude: like a manual run (approved version, outward steps park unless trusted), and only while the
  /// automation is switched on.
  private func run(_ id: String, inputs: [String: AutomationValue], wait: Bool,
                   _ connection: AutomationSocketConnection) {
    guard let entry = engine.entry(id) else { return connection.answer(.failed(AutomationMCPText.notFound(id))) }
    guard entry.enabled else {
      return connection.answer(.failed("\(entry.name) is switched off in Glance Studio. Ask the user to switch it on."))
    }
    let started = engine.run(id, inputs: inputs, fire: AutomationFire(summary: AutomationSocketWire.trigger))
    switch started {
    case .refused(let reason):
      connection.answer(.failed(reason))
    case .queued(let place):
      connection.answer(.ok(AutomationSocketWire.queued(place)))
    case .started(let ref):
      guard wait else { return connection.answer(.ok(AutomationSocketWire.running(ref))) }
      // Already over, or parked on its first outward step: say so now (parking answers at once, never after the wait).
      if engine.live.first(where: { $0.ref == ref })?.parked != false {
        return finishNow(ref, connection)
      }
      let token = UUID()
      waiting[token] = connection
      waits[token] = engine.activity.sink { [weak self] activity in
        guard case .logged(let logged, let event) = activity, logged == ref else { return }
        switch event {
        case .runEnd, .runPark:
          // After the engine has written the line and updated its state.
          DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(token, ref) } }
        default:
          break
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + AutomationMCP.waitLimit) { [weak self] in
        MainActor.assumeIsolated { self?.timedOut(token, ref) }
      }
    }
  }

  private func finishNow(_ ref: AutomationRunRef, _ connection: AutomationSocketConnection) {
    if let record = engine.runs(ref.automation, limit: 200).first(where: { $0.id == ref.run }) {
      connection.answer(.ok(AutomationSocketWire.runResult(record)))
    } else {
      connection.answer(.ok(AutomationSocketWire.running(ref)))
    }
  }

  private func finish(_ token: UUID, _ ref: AutomationRunRef) {
    guard let connection = waiting.removeValue(forKey: token) else { return }
    waits[token] = nil
    if let record = engine.runs(ref.automation, limit: 200).first(where: { $0.id == ref.run }) {
      connection.answer(.ok(AutomationSocketWire.runResult(record)))
    } else {
      connection.answer(.ok(AutomationSocketWire.running(ref)))
    }
  }

  private func timedOut(_ token: UUID, _ ref: AutomationRunRef) {
    guard let connection = waiting.removeValue(forKey: token) else { return }
    waits[token] = nil
    connection.answer(.ok(AutomationSocketWire.running(ref)))
  }
}
