import AppKit
import Darwin
import Foundation
import GlanceCore

/// Glance's own headless Claude Code for the editor chat, used when no terminal runs Claude there. A project has
/// several sessions (`ChatSessionBook`), one process for the active one at a time. Each keeps a real session
/// (transcript, hooks), so the chat, the Glance pane and the Changes marks see its turns like a terminal session's.
/// Auto mode decides permissions. Events arrive on the main thread.
@MainActor
public final class ChatSessions {
  public enum Event: Equatable {
    /// The process is up; its transcript is `<id>.jsonl` once the first message is written.
    case started(sessionID: String)
    case finished
    case failed(String)
  }

  /// Where each project's session list lives: Glance's defaults (the editor chat, kept across launches), or this
  /// object only (the automation builder: a tab's chat ends with the tab).
  public enum Storage { case defaults, memory }

  public var onEvent: ((_ root: String, _ event: Event) -> Void)?
  private var runs: [String: ChatRun] = [:]
  /// A session's title is its first prompt, which never changes once written.
  private var titles: [String: String] = [:]
  private let storage: Storage
  private var memoryBooks: [String: ChatSessionBook] = [:]
  /// Added to every start of Claude Code (the builder's `--allowedTools`).
  private let extraArguments: [String]

  public init(storage: Storage = .defaults, extraArguments: [String] = []) {
    self.storage = storage
    self.extraArguments = extraArguments
  }

  private func book(_ root: String) -> ChatSessionBook {
    storage == .memory ? memoryBooks[root] ?? ChatSessionBook() : Prefs.chatBook(root: root)
  }

  private func setBook(_ book: ChatSessionBook, root: String) {
    if storage == .memory { memoryBooks[root] = book } else { Prefs.setChatBook(book, root: root) }
  }

  /// The session the chat is on; nil is a blank chat.
  public func sessionID(root: String) -> String? { book(root).active }

  public func isWorking(root: String) -> Bool { runs[root]?.working ?? false }

  public func send(_ text: String, root: String) {
    let run = runs[root] ?? ChatRun(root: root, extraArguments: extraArguments,
                                    readBook: { [weak self] in self?.book(root) ?? ChatSessionBook() },
                                    writeBook: { [weak self] book in self?.setBook(book, root: root) },
                                    emit: { [weak self] event in self?.onEvent?(root, event) })
    runs[root] = run
    run.send(text)
  }

  /// Interrupts the turn: the process ends, and the next message resumes the session.
  public func stop(root: String) { runs[root]?.interrupt() }

  /// A blank chat: the current session stays in the list, and the next message starts a new one.
  public func startBlank(root: String) {
    runs.removeValue(forKey: root)?.interrupt()
    var book = self.book(root)
    book.startBlank()
    setBook(book, root: root)
  }

  /// Switches the chat to one of the project's sessions: the next message resumes it.
  public func activate(_ id: String, root: String) {
    runs.removeValue(forKey: root)?.interrupt()
    var book = self.book(root)
    book.activate(id)
    setBook(book, root: root)
  }

  /// Takes a session Glance didn't start (one from a terminal) into the project's list and switches to it: the next
  /// message resumes it.
  public func adopt(_ id: String, root: String) {
    runs.removeValue(forKey: root)?.interrupt()
    var book = self.book(root)
    book.use(id)
    setBook(book, root: root)
  }

  /// The project's sessions for the picker, newest first. Sessions whose transcript was deleted are forgotten; the
  /// active one stays even before its first message is written.
  public func entries(root: String) -> [ChatSessionEntry] {
    let stored = self.book(root)
    var book = stored
    var found: [ChatSessionEntry] = []
    for id in stored.ids {
      if let path = ChatFeed.locate(id: id) {
        let date = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
        found.append(ChatSessionEntry(id: id, title: title(id: id, path: path), updated: date))
      } else if id == stored.active {
        found.append(ChatSessionEntry(id: id, title: nil, updated: Date()))
      }
    }
    let present = Set(found.map(\.id))
    book.prune { !present.contains($0) }
    if book != stored { setBook(book, root: root) }
    return found.sorted { $0.updated > $1.updated }
  }

  private func title(id: String, path: String) -> String? {
    if let known = titles[id] { return known }
    guard let title = ChatTranscript.title(jsonl: ChatFeed.head(path)) else { return nil }
    titles[id] = title
    return title
  }
}

/// One project's headless process.
@MainActor
private final class ChatRun {
  static let idleLimit: TimeInterval = 10 * 60

  let root: String
  private let extraArguments: [String]
  private let readBook: () -> ChatSessionBook
  private let writeBook: (ChatSessionBook) -> Void
  private let emit: (ChatSessions.Event) -> Void
  private var process: Process?
  private var input: FileHandle?
  private(set) var working = false
  private var interrupting = false
  private var errorTail = ""
  private var idleTimer: DispatchWorkItem?

  init(root: String, extraArguments: [String], readBook: @escaping () -> ChatSessionBook,
       writeBook: @escaping (ChatSessionBook) -> Void, emit: @escaping (ChatSessions.Event) -> Void) {
    self.root = root
    self.extraArguments = extraArguments
    self.readBook = readBook
    self.writeBook = writeBook
    self.emit = emit
  }

  func send(_ text: String) {
    guard !working else { return }
    working = true
    interrupting = false
    idleTimer?.cancel()
    if process != nil { write(text); return }
    ClaudeLocator.locate { [weak self] found in
      guard let self, self.working else { return }
      guard let found else { self.finish(.failed("Claude Code isn't installed or isn't on PATH.")); return }
      let saved = self.readBook().active
      let plan = ChatSession.launchPlan(saved: saved, transcriptExists: saved.flatMap { ChatFeed.locate(id: $0) } != nil,
                                        newID: { UUID().uuidString.lowercased() })
      do {
        try self.launch(found, plan: plan)
        var book = self.readBook()
        book.use(plan.id)
        self.writeBook(book)
        self.emit(.started(sessionID: plan.id))
        self.write(text)
      } catch {
        self.finish(.failed("Couldn't start Claude Code: \(error.localizedDescription)"))
      }
    }
  }

  func interrupt() {
    guard process != nil else { if working { finish(.finished) }; return }
    interrupting = true
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
    if working { finish(interrupting ? .finished : .failed(failureText())) }
  }

  private func launch(_ found: ClaudeLocator.Found, plan: (id: String, resume: Bool)) throws {
    errorTail = ""
    let process = Process()
    process.executableURL = URL(fileURLWithPath: found.executable)
    process.arguments = HumanizeStyle.apply(Prefs.responseStyle, body: Resources.humanizeBody,
                                            to: ChatSession.arguments(sessionID: plan.id, resume: plan.resume) + extraArguments)
    process.currentDirectoryURL = URL(fileURLWithPath: root)
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
      endProcess()
    }
  }

  private func received(_ lines: [String]) {
    for line in lines {
      switch ChatSession.outcome(line: line) {
      case .done: finish(.finished)
      case .failed(let detail): finish(.failed(detail))
      case nil: continue
      }
    }
  }

  private func ended(_ ended: Process) {
    LiveProcesses.remove(ended)
    guard ended === process else { return }
    endProcess()
  }

  private func failureText() -> String {
    let detail = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? "Claude stopped unexpectedly." : "Claude stopped unexpectedly: \(detail)"
  }

  private func finish(_ event: ChatSessions.Event) {
    guard working else { return }
    working = false
    emit(event)
    guard process != nil else { return }
    let timer = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { if let self, !self.working { self.endProcess() } }
    }
    idleTimer = timer
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleLimit, execute: timer)
  }
}
