import Darwin
import Foundation
import GlanceCore

/// Studio's end of the orb channel (spec 2026-10-09-orb-channel-design.md, "Parts"): the Unix socket each
/// `glance mcp` connects to, one JSON message per line both ways. Only this user can open it (folder 0700, socket
/// 0600). Writes are queued per connection and sent when the socket can take them, so the main thread never waits on
/// a shim. Built like Studio's shell bridge.
@MainActor
final class ChannelServer {
  typealias ConnectionID = Int32

  var onOpen: ((ConnectionID, pid_t) -> Void)?
  var onLine: ((ConnectionID, String) -> Void)?
  var onClose: ((ConnectionID) -> Void)?

  private final class Connection {
    var lines = ShellLines()
    var reader: DispatchSourceRead?
    var writer: DispatchSourceWrite?
    var outgoing = Data()
  }

  struct Failure: Error, CustomStringConvertible {
    let description: String
  }

  private var listener: Int32 = -1
  private var acceptSource: DispatchSourceRead?
  private var connections: [ConnectionID: Connection] = [:]
  private(set) var path: String?
  /// A shim that stops reading isn't waited for: past this much unsent data its connection is dropped.
  private static let outgoingLimit = 1 << 20

  /// The socket file this server made, to tell it from one another Studio made at the same path.
  private var fileID: (device: dev_t, inode: ino_t)?

  private static func address(for path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    return address
  }

  /// True when something is listening at `path`.
  private static func isLive(_ path: String) -> Bool {
    guard var address = address(for: path) else { return false }
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    guard probe >= 0 else { return false }
    defer { close(probe) }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    return connected == 0
  }

  func start(path: String) throws {
    guard listener < 0 else { return }
    guard var address = Self.address(for: path) else {
      throw Failure(description: "The orb channel's socket path is too long: \(path)")
    }
    let folder = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    chmod(folder, 0o700) // it may have existed with looser permissions
    if Self.isLive(path) { throw Failure(description: "Another Glance Studio already has the orb channel.") }
    unlink(path) // left by a crash
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw Failure(description: "Couldn't create the orb channel's socket.") }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      throw Failure(description: "Couldn't open the orb channel: \(reason)")
    }
    var info = stat()
    let made = stat(path, &info) == 0 ? (device: info.st_dev, inode: info.st_ino) : nil
    guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
      let reason = String(cString: strerror(errno))
      close(fd)
      if made != nil { unlink(path) }
      throw Failure(description: "Couldn't open the orb channel: \(reason)")
    }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    listener = fd
    self.path = path
    fileID = made
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptConnections() } }
    source.setCancelHandler { close(fd) }
    source.resume()
    acceptSource = source
  }

  func stop() {
    for id in Array(connections.keys) { drop(id) }
    acceptSource?.cancel()
    acceptSource = nil
    listener = -1
    // Only our own socket file goes: another Studio may have replaced it.
    if let path, let fileID {
      var info = stat()
      if stat(path, &info) == 0, info.st_dev == fileID.device, info.st_ino == fileID.inode { unlink(path) }
    }
    path = nil
    fileID = nil
  }

  private func acceptConnections() {
    while true {
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else { return }
      _ = fcntl(fd, F_SETFL, O_NONBLOCK)
      _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
      var noSigPipe: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      var pid: pid_t = 0
      var size = socklen_t(MemoryLayout<pid_t>.size)
      if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 { pid = 0 }
      let connection = Connection()
      connections[fd] = connection
      let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
      reader.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(fd) } }
      reader.setCancelHandler { close(fd) }
      connection.reader = reader
      reader.resume()
      onOpen?(fd, pid)
    }
  }

  private func read(_ id: ConnectionID) {
    guard let connection = connections[id] else { return }
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let count = Darwin.read(id, &buffer, buffer.count)
    if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
      drop(id)
      return
    }
    guard count > 0 else { return }
    for line in connection.lines.append(Data(buffer[0..<count])) {
      onLine?(id, line)
      guard connections[id] != nil else { return }
    }
  }

  /// Queues `line` (ending in "\n") for the shim on `id`. False when that connection is gone.
  @discardableResult
  func send(_ line: String, to id: ConnectionID) -> Bool {
    guard let connection = connections[id] else { return false }
    connection.outgoing.append(Data(line.utf8))
    if connection.outgoing.count > Self.outgoingLimit {
      drop(id)
      return false
    }
    flush(id)
    return connections[id] != nil
  }

  private func flush(_ id: ConnectionID) {
    guard let connection = connections[id] else { return }
    while !connection.outgoing.isEmpty {
      let written = connection.outgoing.withUnsafeBytes { Darwin.write(id, $0.baseAddress, $0.count) }
      if written > 0 {
        connection.outgoing.removeFirst(written)
        continue
      }
      if written < 0 && (errno == EAGAIN || errno == EINTR) {
        if connection.writer == nil {
          let writer = DispatchSource.makeWriteSource(fileDescriptor: id, queue: .main)
          writer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush(id) } }
          connection.writer = writer
          writer.resume()
        }
        return
      }
      drop(id)
      return
    }
    connection.writer?.cancel()
    connection.writer = nil
  }

  func drop(_ id: ConnectionID) {
    guard let connection = connections.removeValue(forKey: id) else { return }
    if let writer = connection.writer, let reader = connection.reader {
      writer.setCancelHandler { reader.cancel() }
      writer.cancel()
    } else {
      connection.reader?.cancel()
    }
    onClose?(id)
  }
}
