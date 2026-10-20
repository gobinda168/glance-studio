import AppKit
import Darwin
import GlanceCore
import GlanceKit

/// The app's end of the editor bridge: a unix socket that the Glance extension in each editor tab's VS Code extension
/// host connects to, sending JSON lines (`EditorBridgeMessage`). Only this user can open it (mode 0600).
@MainActor
final class EditorBridgeServer {
    static let shared = EditorBridgeServer()

    private final class Client {
        var lines = JSONLines()
        var folder: String?
        var source: DispatchSourceRead?
        /// The extension's inline Claude box (Inline Ask), answered on this connection only.
        var asks: InlineAskSessions?
    }

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    /// Folders of the editor tabs whose extension host is connected now.
    var connectedFolders: [String] { clients.values.compactMap(\.folder) }

    /// Writes a command to every connection of that folder's extension host. False when none is connected.
    @discardableResult
    func send(_ command: EditorBridgeCommand, toFolder folder: String) -> Bool {
        var sent = false
        for (fd, client) in clients where client.folder == folder {
            sent = write(command, to: fd) || sent
        }
        return sent
    }

    private func write(_ command: EditorBridgeCommand, to fd: Int32) -> Bool {
        let bytes = Array((command.line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written > 0 { offset += written; continue }
            if written < 0 && errno == EAGAIN { usleep(1000); continue } // a full socket buffer drains quickly
            break
        }
        return offset == bytes.count
    }

    func start(socket url: URL) throws {
        guard listener < 0 else { return }
        unlink(url.path) // a socket file left by a crash
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EditorError("Couldn't create the editor bridge.") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw EditorError("The editor bridge's path is too long: \(url.path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in path.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw EditorError("Couldn't open the editor bridge: \(reason)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { EditorBridgeServer.shared.acceptClient() } }
        source.resume()
        acceptSource = source
    }

    private func acceptClient() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let client = Client()
        clients[fd] = client
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { EditorBridgeServer.shared.read(fd) } }
        source.setCancelHandler { close(fd) }
        client.source = source
        source.resume()
    }

    private func read(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(fd, &buffer, buffer.count)
        if count == 0 || (count < 0 && errno != EAGAIN) {
            client.asks?.stopAll()
            client.source?.cancel()
            clients[fd] = nil
            return
        }
        guard count > 0 else { return }
        for line in client.lines.append(Data(buffer[0..<count])) {
            guard let message = EditorBridgeMessage.decode(line) else { continue }
            switch message {
            case .hello(let folder):
                client.folder = folder
                EditorBridgeActions.handle(message, folder: folder)
            case .askStart(let request):
                asks(of: client, fd: fd).start(request)
            case .askFollowUp(let id, let question):
                client.asks?.followUp(id: id, question: question)
            case .askStop(let id):
                client.asks?.stop(id: id)
            default:
                EditorBridgeActions.handle(message, folder: client.folder)
            }
        }
    }
}

extension EditorBridgeServer {
    /// Claude runs in the editor tab's folder; its events go back on the connection that asked.
    private func asks(of client: Client, fd: Int32) -> InlineAskSessions {
        if let asks = client.asks { return asks }
        let asks = InlineAskSessions(folder: client.folder ?? NSHomeDirectory()) { [weak self, weak client] event, request in
            guard let self, let client, self.clients[fd] === client else { return }
            _ = self.write(.askEvent(event, request: request), to: fd)
        }
        client.asks = asks
        return asks
    }
}

/// What the app does with the extension's messages.
@MainActor
enum EditorBridgeActions {
    static func handle(_ message: EditorBridgeMessage, folder: String?) {
        let editor = GlanceTabHost.controllers(kind: EditorKind.studio.rawValue).first { $0.tabKey == folder }
        switch message {
        case .hello:
            (editor as? StudioWindowController)?.bridgeConnected()
        case .openTerminal(let cwd):
            openTerminalTab(cwd: cwd, near: editor?.window ?? NSApp.keyWindow)
        case .closeTab:
            editor?.window?.performClose(nil)
        case .askStart, .askFollowUp, .askStop:
            break // EditorBridgeServer answers these on the connection itself
        }
    }

    /// A terminal tab in `cwd`, in the same window as the editor tab; `input` is typed into its shell once it starts
    /// (Tickets' Work on this: `claude '…'` and a newline).
    static func openTerminalTab(cwd: String, near window: NSWindow?, input: String? = nil) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = cwd
        config.initialInput = input
        let tabs = window?.tabGroup?.windows ?? [window].compactMap { $0 }
        if let terminal = tabs.first(where: { $0.windowController is TerminalController }) {
            _ = TerminalController.newTab(app.ghostty, from: terminal, withBaseConfig: config)
        } else {
            TabSidebarModel.newTerminalTab(app.ghostty, joining: window, withBaseConfig: config)
        }
    }
}
