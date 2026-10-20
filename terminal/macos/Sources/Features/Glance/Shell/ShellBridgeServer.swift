import Darwin
import Foundation
import GlanceCore

/// Studio's end of the shell bridge (spec 2026-10-08-terminal-suggestions-design.md, "The bridge"): a unix socket the
/// Glance zsh plugin in each Studio shell connects to. Lines in the wire format both ways; only this user can open it
/// (folder 0700, socket 0600). Writes are queued per connection and sent when the socket can take them, so the main
/// thread never waits on a shell.
@MainActor
final class ShellBridgeServer {
    typealias ConnectionID = Int32

    /// A connection opened (with the connecting process's pid), sent an event, or closed.
    var onOpen: ((ConnectionID, pid_t) -> Void)?
    var onEvent: ((ConnectionID, ShellEvent) -> Void)?
    var onClose: ((ConnectionID) -> Void)?

    private final class Connection {
        var lines = ShellLines()
        var reader: DispatchSourceRead?
        var writer: DispatchSourceWrite?
        var outgoing = Data()
        /// Close once `outgoing` is sent (`finish`).
        var closesWhenSent = false
    }

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ConnectionID: Connection] = [:]
    private(set) var path: String?
    /// A shell that stops reading isn't kept waiting for: past this much unsent data its connection is dropped.
    private static let outgoingLimit = 1 << 20

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func start(path: String) throws {
        guard listener < 0 else { return }
        let folder = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(folder, 0o700)
        unlink(path) // left by a crash
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "Couldn't create the shell bridge.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw Failure(description: "The shell bridge's path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "Couldn't open the shell bridge: \(reason)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        self.path = path
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptConnections() } }
        source.resume()
        acceptSource = source
    }

    func stop() {
        for id in Array(connections.keys) { drop(id) }
        acceptSource?.cancel()
        acceptSource = nil
        if listener >= 0 { close(listener) }
        listener = -1
        if let path { unlink(path) }
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
            guard let event = ShellEvent(line: line) else { continue }
            onEvent?(id, event)
            // A handler may have dropped the connection (a refused hello).
            guard connections[id] != nil else { return }
        }
    }

    /// Queues `command` for the shell on `id`. False when that connection is gone.
    @discardableResult
    func send(_ command: ShellCommand, to id: ConnectionID) -> Bool {
        guard let connection = connections[id] else { return false }
        connection.outgoing.append(Data(command.line.utf8))
        if connection.outgoing.count > Self.outgoingLimit {
            drop(id)
            return false
        }
        flush(id)
        return connections[id] != nil
    }

    /// Sends `command` as the last message on `id`, then closes it.
    func finish(_ command: ShellCommand, to id: ConnectionID) {
        guard let connection = connections[id] else { return }
        connection.closesWhenSent = true
        send(command, to: id)
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
                // The shell's side is full: finish when it can take more.
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
        // Dropping cancels the writer before the reader closes the descriptor.
        if connection.closesWhenSent { return drop(id) }
        connection.writer?.cancel()
        connection.writer = nil
    }

    /// Closes a connection (the shell went away, or Studio refused it).
    func drop(_ id: ConnectionID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        // The reader's cancel handler closes the descriptor: only once the writer, if any, no longer watches it.
        if let writer = connection.writer, let reader = connection.reader {
            writer.setCancelHandler { reader.cancel() }
            writer.cancel()
        } else {
            connection.reader?.cancel()
        }
        onClose?(id)
    }
}
