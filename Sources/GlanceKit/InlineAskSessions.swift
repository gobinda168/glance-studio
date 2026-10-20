import AppKit
import Darwin
import Foundation
import GlanceCore

/// The inline boxes of one editor (a Razor Code tab, or a GS Code tab's extension host): one `claude -p` process
/// per box, in the project folder, taking the box's first question and its follow-ups on stdin. Boxes run side by side;
/// starting one again (same id) replaces its process. Events go to `send` on the main thread; none come after a stop.
/// The owner calls `stopAll()` when its editor goes away; quitting the app stops every process anyway, and a process
/// left idle for `Run.idleLimit` exits by itself (the next follow-up starts a new one).
@MainActor
public final class InlineAskSessions {
  private let folder: String
  private let rules: String
  private let send: (InlineAsk.Event, InlineAsk.Request) -> Void
  private var runs: [String: Run] = [:]

  public init(folder: String, rules: String = InlineAsk.rules,
              send: @escaping (InlineAsk.Event, InlineAsk.Request) -> Void) {
    self.folder = folder
    self.rules = rules
    self.send = send
  }

  /// `message` makes the first message from a question (the diff boxes' review mode); nil is the editors' own.
  public func start(_ request: InlineAsk.Request, message: ((String) -> String)? = nil) {
    runs.removeValue(forKey: request.id)?.stop()
    let first = message ?? { InlineAsk.firstMessage(request.asking($0)) }
    let run = Run(request: request, folder: folder, rules: rules, firstMessage: first) { [weak self] event in
      self?.send(event, request)
    }
    runs[request.id] = run
    run.ask(first(request.question), question: request.question)
  }

  public func followUp(id: String, question: String) {
    runs[id]?.ask(question, question: question)
  }

  public func stop(id: String) {
    runs.removeValue(forKey: id)?.stop()
  }

  public func stopAll() {
    runs.values.forEach { $0.stop() }
    runs.removeAll()
  }
}

/// Every running Claude process of every editor, so quitting the app ends them all at once (Claude would otherwise
/// finish its current answer first, unseen).
@MainActor
enum LiveProcesses {
  private static var processes: [ObjectIdentifier: Process] = [:]
  private static var observer: NSObjectProtocol?

  static func add(_ process: Process) {
    processes[ObjectIdentifier(process)] = process
    observer = observer ?? NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in MainActor.assumeIsolated { LiveProcesses.terminateAll() } }
  }

  static func remove(_ process: Process) { processes[ObjectIdentifier(process)] = nil }

  private static func terminateAll() {
    for process in processes.values where process.isRunning { process.terminate() }
    processes.removeAll()
  }
}

/// One box's Claude process.
@MainActor
private final class Run {
  /// An idle process (an answered box) holds a node runtime: it exits after this long without a question.
  static let idleLimit: TimeInterval = 10 * 60

  private let request: InlineAsk.Request
  private let folder: String
  private let rules: String
  private let firstMessage: (String) -> String
  private let emit: (InlineAsk.Event) -> Void
  private var parser: InlineAsk.Parser
  private var process: Process?
  private var input: FileHandle?
  private var turnRunning = false
  private var asked = false
  private var stopped = false
  private var errorTail = ""
  private var idleTimer: DispatchWorkItem?

  init(request: InlineAsk.Request, folder: String, rules: String, firstMessage: @escaping (String) -> String,
       emit: @escaping (InlineAsk.Event) -> Void) {
    self.request = request
    self.folder = folder
    self.rules = rules
    self.firstMessage = firstMessage
    self.emit = emit
    parser = InlineAsk.Parser(folder: folder)
  }

  /// Sends a message. A follow-up after the process ended starts a new one, with the first message's code and the new
  /// question (the earlier answers are gone with it).
  func ask(_ message: String, question: String) {
    guard !stopped, !turnRunning else { return }
    turnRunning = true
    idleTimer?.cancel()
    let text = process == nil && asked ? firstMessage(question) : message
    asked = true
    if process != nil { write(text); return }
    ClaudeLocator.locate { [weak self] found in
      guard let self, !self.stopped else { return }
      guard let found else { self.finishTurn(.failed("Claude Code isn't installed or isn't on PATH.")); return }
      do {
        try self.launch(found)
        self.write(text)
      } catch {
        self.finishTurn(.failed("Couldn't start Claude Code: \(error.localizedDescription)"))
      }
    }
  }

  func stop() {
    stopped = true
    turnRunning = false
    endProcess()
  }

  private func endProcess() {
    idleTimer?.cancel()
    idleTimer = nil
    try? input?.close()
    input = nil
    if let process {
      LiveProcesses.remove(process)
      if process.isRunning { process.terminate() }
    }
    process = nil
    parser = InlineAsk.Parser(folder: folder)
  }

  private func launch(_ found: ClaudeLocator.Found) throws {
    errorTail = ""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = HumanizeStyle.apply(Prefs.responseStyle, body: Resources.humanizeBody, to: InlineAsk.arguments(rules: rules))
    process.currentDirectoryURL = URL(fileURLWithPath: folder)
    var environment = ProcessInfo.processInfo.environment
    if let path = found.path { environment["PATH"] = path }
    environment["CLAUDECODE"] = nil
    process.environment = environment

    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    // A write after Claude exits must fail, not kill the app with SIGPIPE.
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    let lines = LineSplitter()
    stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      let complete = lines.append(data)
      guard !complete.isEmpty else { return }
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(complete) } }
    }
    stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      let text = String(decoding: data, as: UTF8.self)
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.errorTail = String(((self?.errorTail ?? "") + text).suffix(600)) } }
    }
    process.terminationHandler = { [weak self] ended in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(ended) } }
    }
    do {
      try process.run()
    } catch {
      // Nothing will ever reach EOF on these pipes: let go of them now.
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      throw error
    }
    LiveProcesses.add(process)
    self.process = process
    input = stdin.fileHandleForWriting
  }

  private func write(_ text: String) {
    do {
      try input?.write(contentsOf: Data((InlineAsk.userLine(text) + "\n").utf8))
    } catch {
      finishTurn(.failed("Claude stopped unexpectedly."))
    }
  }

  private func received(_ lines: [String]) {
    guard !stopped else { return }
    for line in lines {
      for event in parser.feed(line) {
        switch event {
        case .done, .failed: finishTurn(event)
        default: emit(event)
        }
      }
    }
  }

  private func ended(_ ended: Process) {
    LiveProcesses.remove(ended)
    guard ended === process else { return }
    endProcess()
    guard !stopped, turnRunning else { return }
    let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
    finishTurn(.failed(detail.isEmpty ? "Claude stopped unexpectedly." : "Claude stopped unexpectedly: \(detail)"))
  }

  private func finishTurn(_ event: InlineAsk.Event) {
    turnRunning = false
    guard !stopped else { return }
    emit(event)
    guard process != nil else { return }
    let timer = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { if let self, !self.turnRunning { self.endProcess() } }
    }
    idleTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit, execute: timer)
  }
}

private extension InlineAsk.Request {
  func asking(_ question: String) -> InlineAsk.Request {
    InlineAsk.Request(id: id, path: path, start: start, end: end, text: text, before: before, after: after,
                      question: question)
  }
}

/// Stdout's bytes into lines; the pipe's handler runs on one queue at a time.
final class LineSplitter: @unchecked Sendable {
  private var lines = JSONLines()
  private let lock = NSLock()
  func append(_ data: Data) -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines.append(data)
  }
}

/// Where `claude` is, and the login shell's PATH it needs (an npm install is a node script: `node` must be on PATH).
/// Looked up once, off the main thread; a miss is looked up again next time, in case it was installed since.
enum ClaudeLocator {
  struct Found: Sendable {
    let executable: String
    let path: String?
  }

  @MainActor private static var cached: Found?

  @MainActor static func locate(_ completion: @escaping @MainActor (Found?) -> Void) {
    if let cached { completion(cached); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let path = loginPath()
      let executable = InlineAsk.findClaude(path: path, home: NSHomeDirectory()) { FileManager.default.isExecutableFile(atPath: $0) }
      let found = executable.map { Found(executable: $0, path: path) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if found != nil { cached = found }
          completion(found)
        }
      }
    }
  }

  static func loginPath() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lic", "printf '\(EditorServer.pathMarker)%s\(EditorServer.pathMarker)' \"$PATH\""]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    return EditorServer.pathFromShellOutput(String(decoding: data, as: UTF8.self))
  }
}
