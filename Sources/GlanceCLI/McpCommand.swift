import Darwin
import Foundation
import GlanceCore

/// `glance mcp` (spec 2026-10-09-orb-channel-design.md, "Parts"): the stdio MCP server Claude Code starts for each
/// session. It answers the MCP handshake and the tool list itself, and relays tool calls, permission requests,
/// pushes and verdicts to and from Glance Studio over `orb.sock`. Without Studio every tool says so at once.
enum McpCommand {
  static func run() -> Never {
    let shim = OrbShim(socketPath: ChannelPaths.socket())
    shim.start()
    dispatchMain()
  }
}

/// All state lives on `queue`; stdin is read on its own thread; stdout writes are serialized on `queue` too.
final class OrbShim: @unchecked Sendable {
  private let socketPath: String
  private let queue = DispatchQueue(label: "dev.glance.mcp")
  private var fd: Int32 = -1
  private var reader: DispatchSourceRead?
  private var lines = ShellLines()
  private var assistant = false
  private var welcomed = false
  /// tools/list asked before Studio's welcome: answered when it comes (or after 1.5 s).
  private var listWaiting: [JSONValue] = []
  /// Our call id → the MCP request id.
  private var pending: [String: JSONValue] = [:]
  private var serial = 0
  private var reconnect: DispatchSourceTimer?

  static let notRunning = "Glance Studio isn't running, so the user can't see this. Carry on in the terminal."
  static let closed = "Glance Studio closed before the user answered."

  init(socketPath: String) { self.socketPath = socketPath }

  func start() {
    signal(SIGPIPE, SIG_IGN)
    queue.async { self.connect() }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.setEventHandler { [weak self] in if let self, self.fd < 0 { self.connect() } }
    timer.resume()
    reconnect = timer
    Thread.detachNewThread { [self] in
      while let line = readLine(strippingNewline: true) {
        queue.async { self.handle(line) }
      }
      // Claude Code closed stdin: the session is over.
      queue.async { exit(0) }
    }
  }

  // MARK: - MCP side

  private func handle(_ line: String) {
    switch MCP.parse(line) {
    case .request(let id, let method, let params):
      request(id: id, method: method, params: params)
    case .notification(let method, let params):
      if method == MCP.permissionRequestMethod { permissionRequest(params) }
    case .response, .invalid:
      break
    }
  }

  private func request(id: JSONValue, method: String, params: JSONValue) {
    switch method {
    case "initialize":
      let version = AppVersion.current.version ?? "dev"
      write(MCP.result(id: id, MCP.initializeResult(clientVersion: params["protocolVersion"]?.string,
                                                    serverVersion: version)))
    case "ping":
      write(MCP.result(id: id, [:]))
    case "tools/list":
      if fd >= 0 && !welcomed {
        listWaiting.append(id)
        queue.asyncAfter(deadline: .now() + 1.5) { self.answerLists() }
      } else {
        write(MCP.result(id: id, ["tools": .array(ChannelTools.definitions(assistant: assistant))]))
      }
    case "tools/call":
      call(id: id, name: params["name"]?.string ?? "", arguments: params["arguments"] ?? [:])
    default:
      write(MCP.error(id: id, code: -32601, message: "Unknown method \(method)"))
    }
  }

  private func answerLists() {
    let waiting = listWaiting
    listWaiting = []
    for id in waiting { write(MCP.result(id: id, ["tools": .array(ChannelTools.definitions(assistant: assistant))])) }
  }

  private func call(id: JSONValue, name: String, arguments: JSONValue) {
    // Checked here too, so a bad call is answered even without Studio.
    if case .failure(let failure) = ChannelTools.parse(name: name, arguments: arguments, assistant: assistant) {
      write(MCP.result(id: id, MCP.toolResult(.string(failure.message), isError: true)))
      return
    }
    guard fd >= 0 else {
      write(MCP.result(id: id, MCP.toolResult(.string(Self.notRunning), isError: true)))
      return
    }
    serial += 1
    let callID = "m\(serial)"
    pending[callID] = id
    send(.call(callID: callID, tool: name, arguments: arguments))
  }

  private func permissionRequest(_ params: JSONValue) {
    guard fd >= 0, let requestID = params["request_id"]?.string else { return }
    send(.permissionRequest(.init(requestID: requestID, tool: params["tool_name"]?.string ?? "a tool",
                                  description: params["description"]?.string ?? "",
                                  input: params["input_preview"]?.string ?? "")))
  }

  private func write(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }

  // MARK: - Studio side

  private func connect() {
    let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard socket >= 0 else { return }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { close(socket); return }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { close(socket); return }
    var noSigPipe: Int32 = 1
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    fd = socket
    welcomed = false
    lines = ShellLines()
    let reader = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
    reader.setEventHandler { [weak self] in self?.readSocket() }
    reader.setCancelHandler { close(socket) }
    reader.resume()
    self.reader = reader
    let env = ProcessInfo.processInfo.environment
    send(.hello(.init(pid: getpid(), ppid: getppid(), projectDir: env["CLAUDE_PROJECT_DIR"],
                      cwd: FileManager.default.currentDirectoryPath)))
  }

  private func readSocket() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    let count = Darwin.read(fd, &buffer, buffer.count)
    if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) { return disconnect() }
    guard count > 0 else { return }
    for line in lines.append(Data(buffer[0..<count])) {
      guard let message = ChannelWire.ToShim(line: line) else { continue }
      switch message {
      case .welcome(let assistant, _):
        self.assistant = assistant
        welcomed = true
        answerLists()
      case .result(let callID, let value, let isError):
        guard let id = pending.removeValue(forKey: callID) else { continue }
        write(MCP.result(id: id, MCP.toolResult(value, isError: isError)))
      case .push(let content, let meta):
        write(MCP.notification(method: MCP.channelMethod,
                               params: ["content": .string(content), "meta": .object(meta.mapValues(JSONValue.string))]))
      case .verdict(let requestID, let allow):
        write(MCP.notification(method: MCP.permissionVerdictMethod,
                               params: ["request_id": .string(requestID), "behavior": allow ? "allow" : "deny"]))
      }
    }
  }

  private func send(_ message: ChannelWire.ToStudio) {
    guard fd >= 0 else { return }
    let data = Array(message.line.utf8)
    var offset = 0
    while offset < data.count {
      let written = data[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written > 0 { offset += written; continue }
      if written < 0 && errno == EINTR { continue }
      return disconnect()
    }
  }

  private func disconnect() {
    reader?.cancel()
    reader = nil
    fd = -1
    welcomed = false
    for (_, id) in pending { write(MCP.result(id: id, MCP.toolResult(.string(Self.closed), isError: true))) }
    pending.removeAll()
  }
}
