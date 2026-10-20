import AppKit
import Combine
import GlanceCore

/// The orb channel's brain in Studio (spec 2026-10-09-orb-channel-design.md): listens on orb.sock, keeps the
/// `ChannelBook`, and carries out its effects — replies to the shims, notification cards, the orb's mode, speech,
/// Notifications items. Studio fills in what only it knows: which split a `claude` runs in, Open, typing into a split.
@MainActor
public final class OrbChannelHub: ObservableObject {
  public typealias SessionID = ChannelBook.SessionID
  public static let shared = OrbChannelHub()

  @Published public private(set) var book = ChannelBook()
  @Published public private(set) var running = false
  @Published public private(set) var failure: String?

  /// Studio's prompt cards: whether a split already shows this tool's permission as a prompt card.
  public var promptCovers: ((_ surface: String, _ tool: String) -> Bool)?

  /// A prompt card now covers this split's permission: drop the relay's card for it, without a verdict.
  public func dropPermissionCards(surface: String, tool: String) {
    let ids = book.cards.filter { card in
      guard case .permission(_, let cardTool, _) = card.kind else { return false }
      return cardTool == tool && book.sessions[card.session]?.surface == surface
    }.map(\.id)
    guard !ids.isEmpty else { return }
    ids.forEach { book.discard($0) }
    changed()
  }

  /// Studio: the split a `claude` (by pid) runs in, and whether it was started with the channel flag.
  public var resolve: (_ claudePID: Int32) -> (surface: String?, channel: Bool) = { _ in (nil, false) }
  /// The orb assistant's `claude` (Task 16), to give its shim the assistant tools.
  public var isAssistant: (_ claudePID: Int32) -> Bool = { _ in false }
  /// Assistant-mode calls the hub doesn't answer itself (Task 16).
  public var assistantCall: ((SessionID, String, ChannelCall) -> Void)?
  /// A card's Open: Studio focuses the session's split.
  public var onOpenSession: ((ChannelBook.Session) -> Void)?
  /// `tell`: Studio shows the markdown in Glance's card (session, markdown, size, read it aloud, and the question it
  /// answers, shown muted above it: the orb assistant's).
  public var onTell: ((ChannelBook.Session, String, TellCard.Size, Bool, String?) -> Void)?
  /// Studio: whether Feature.secrets is on.
  public var secretsEnabled: () -> Bool = { false }
  /// Each connection's peer pid (the shim, from the socket) and the folder Studio verified for its session.
  private var peerPIDs: [SessionID: pid_t] = [:]
  private var secretFolders: [SessionID: String] = [:]
  /// Which connection holds each id (ids are socket descriptors, reused once closed), so a secrets answer that comes
  /// after its session ended never goes to the next one.
  private var connections: [SessionID: Int] = [:]
  private var opened = 0

  /// The speech queue is talking.
  @Published var speaking = false { didSet { if speaking != oldValue { refreshOrb() } } }
  /// fn is held for a card or the assistant (the assistant's card shows Listening…).
  @Published var listening = false { didSet { if listening != oldValue { refreshOrb() } } }
  /// The orb assistant is thinking: the orb shows working.
  @Published var assistantWorking = false { didSet { if assistantWorking != oldValue { refreshOrb() } } }

  private let server = ChannelServer()
  private var clock: Timer?
  /// The permission card last read aloud.
  private var spokenPermissionID: String?
  /// An `approve` call of the assistant's waiting on its permission card.
  private struct Approval {
    let session: SessionID
    let callID: String
    let input: JSONValue
    let cardID: String?
    /// Unanswered by then: the card goes and the answer is no (Claude Code gives up on the call itself later).
    let deadline: Date
  }
  /// How long an assistant's Allow / Deny card waits.
  static let approvalTimeout: TimeInterval = 300
  /// The assistant's waiting `approve` calls, by request id ("approve-<session>-<call>").
  private var approvals: [String: Approval] = [:]

  private init() {}

  public func start() {
    guard !running else { return }
    server.onLine = { [weak self] id, line in self?.received(id, line) }
    server.onClose = { [weak self] id in self?.closed(id) }
    server.onOpen = { [weak self] id, pid in
      guard let self else { return }
      peerPIDs[id] = pid
      opened += 1
      connections[id] = opened
    }
    do {
      try server.start(path: ChannelPaths.socket())
    } catch {
      failure = "\(error)"
      return
    }
    running = true
    failure = nil
    let hub = NotificationHub.shared
    hub.start()
    if hub.onNudge == nil { hub.onNudge = { NudgeStack.shared.show($0) } }
    SpeechQueue.shared.onSpeaking = { [weak self] on in self?.speaking = on }
    assistantCall = { [weak self] id, callID, call in self?.assistantCalled(id, callID, call) }
    isAssistant = { pid in OrbAssistant.shared.pid == pid }
    OrbAssistant.wireRestart()
  }

  /// Studio: whether Glance's panel (or the overlay's) is reading a reply; sessions' speech waits for it.
  public static func setOtherSpeech(_ check: @escaping () -> Bool) { SpeechQueue.shared.otherSpeech = check }

  public func stop() {
    guard running else { return }
    server.stop()
    SpeechQueue.shared.stopAll()
    running = false
    approvals.removeAll()
    OrbAssistant.shared.end()
    for id in Array(book.sessions.keys) { book.close(id) }
    changed()
  }

  // MARK: - From the shims

  private func received(_ id: SessionID, _ line: String) {
    guard let message = ChannelWire.ToStudio(line: line) else { return }
    switch message {
    case .hello(let hello): greet(id, hello)
    case .call(let callID, let tool, let arguments): call(id, callID, tool, arguments)
    case .permissionRequest(let request): permissionRequest(id, request)
    }
  }

  private func greet(_ id: SessionID, _ hello: ChannelWire.Hello) {
    let assistant = isAssistant(hello.ppid)
    let place = resolve(hello.ppid)
    let label = assistant ? "Glance" : ChannelBook.label(projectDir: hello.projectDir, cwd: hello.cwd,
                                                          home: NSHomeDirectory())
    book.open(.init(id: id, label: label, projectDir: hello.projectDir ?? hello.cwd, surface: place.surface,
                    channel: place.channel, assistant: assistant, now: Date()))
    // The folder secrets are fenced by: the real `claude`'s cwd, only when the socket's peer is that claude's child
    // (the shim's own word for it doesn't count). A parent of 0 or 1 is no parent. A second hello starts over.
    secretFolders[id] = nil
    if !assistant, hello.ppid > 1, let peer = peerPIDs[id], peer > 0, ProcessTable.parent(of: peer) == hello.ppid,
       let cwd = ProcessTable.cwd(of: hello.ppid) {
      secretFolders[id] = cwd
    }
    server.send(ChannelWire.ToShim.welcome(assistant: assistant, label: label).line, to: id)
    changed()
  }

  private func closed(_ id: SessionID) {
    approvals = approvals.filter { $0.value.session != id }
    peerPIDs[id] = nil
    secretFolders[id] = nil
    connections[id] = nil
    SecretsService.shared.sessionEnded(id)
    book.close(id)
    changed()
  }

  private func call(_ id: SessionID, _ callID: String, _ tool: String, _ arguments: JSONValue) {
    guard let session = book.sessions[id] else {
      return reply(id, callID, .string("Glance didn't get this session's hello."), isError: true)
    }
    switch ChannelTools.parse(name: tool, arguments: arguments, assistant: session.assistant) {
    case .failure(let failure): reply(id, callID, .string(failure.message), isError: true)
    case .success(let call): handle(id, callID, call)
    }
  }

  private func handle(_ id: SessionID, _ callID: String, _ call: ChannelCall) {
    let now = Date()
    switch call {
    case .nudge(let title, let body, let actions, let wait):
      perform(book.nudge(session: id, callID: callID, title: title, body: body, actions: actions, wait: wait,
                         now: now).effects)
    case .ask(let question, let choices, let allowText, let speak, let wait):
      perform(book.ask(session: id, callID: callID, question: question, choices: choices, allowText: allowText,
                       wait: wait, now: now).effects)
      if speak, Prefs.orbChannelReadQuestions, let label = book.sessions[id]?.label {
        SpeechQueue.shared.say(ChannelBook.spokenQuestion(label: label, question: question, choices: choices),
                               interrupt: false) { _ in }
      }
    case .checkAnswer(let cardID, let wait):
      perform(book.checkAnswer(session: id, callID: callID, id: cardID, wait: wait, now: now))
    case .speak(let text, let interrupt):
      if !Prefs.orbChannelSessionsSpeak {
        reply(id, callID, ["skipped": "The user turned off speech from sessions."], isError: false)
      } else if let reason = SpeechQueue.quietReason() {
        reply(id, callID, ["skipped": .string(reason)], isError: false)
      } else {
        SpeechQueue.shared.say(text, interrupt: interrupt) { [weak self] spoken in
          self?.reply(id, callID, spoken ? ["spoken": true] : ["skipped": "It couldn't be said now."], isError: false)
        }
      }
    case .tell(let markdown, let size, let speak):
      guard let session = book.sessions[id], let onTell else {
        reply(id, callID, "Glance can't show this right now.", isError: true)
        break
      }
      let spoken = speak && Prefs.orbChannelSessionsSpeak && SpeechQueue.quietReason() == nil
      onTell(session, markdown, size, spoken, nil)
      reply(id, callID, ["shown": true, "spoken": .bool(spoken)], isError: false)
    case .status(let text, let state):
      perform(book.status(session: id, callID: callID, state: state, caption: text, now: now))
    case .dismiss(let cardID):
      perform(book.dismiss(session: id, callID: callID, id: cardID))
    case .secretsList, .httpRequest:
      // Sessions only: the parser already refuses these to the orb assistant; refuse here too, the same way.
      guard book.sessions[id]?.assistant == false else {
        if case .httpRequest = call { reply(id, callID, "Unknown tool http_request.", isError: true) }
        else { reply(id, callID, "Unknown tool secrets_list.", isError: true) }
        break
      }
      guard secretsEnabled() else {
        reply(id, callID, "Secrets are off in Glance Studio.", isError: true)
        break
      }
      let caller = SecretCaller(session: id, label: book.sessions[id]?.label ?? "Claude", folder: secretFolders[id])
      let connection = connections[id]
      Task { @MainActor [weak self] in
        let answer: (JSONValue, Bool)
        if case .httpRequest(let request) = call {
          answer = await SecretsService.shared.request(request, caller: caller)
        } else {
          answer = await SecretsService.shared.list(caller: caller)
        }
        guard let self, let connection, connections[id] == connection else { return }
        reply(id, callID, answer.0, isError: answer.1)
      }
    case .approve, .notifications, .calendar, .sessions, .meetingNotes, .tickets, .open, .messageSession, .startSession:
      if let assistantCall { assistantCall(id, callID, call) }
      else { reply(id, callID, "The orb assistant isn't running.", isError: true) }
    }
    changed()
  }

  /// The orb assistant's own calls: `approve` (its permission prompt tool) passes a read straight through and puts
  /// anything that acts on an Allow / Deny card; the rest are its Glance tools.
  private func assistantCalled(_ id: SessionID, _ callID: String, _ call: ChannelCall) {
    if case .approve(let tool, let input) = call {
      guard AssistantPolicy.needsConfirmation(tool: tool) else {
        return reply(id, callID, AssistantPolicy.approveResult(allow: true, input: input), isError: false)
      }
      let requestID = "approve-\(id)-\(callID)"
      let request = ChannelWire.PermissionRequest(requestID: requestID, tool: AssistantPolicy.describe(tool: tool),
                                                  description: "", input: input.text)
      // Read aloud when it's the active card (`speakActivePermission`), as sessions' prompts are.
      let now = Date()
      let cardID = book.permission(session: id, request: request, now: now)
      approvals[requestID] = Approval(session: id, callID: callID, input: input, cardID: cardID,
                                      deadline: now.addingTimeInterval(Self.approvalTimeout))
      return changed()
    }
    let (value, isError) = OrbAssistantTools.run(call, hub: self)
    reply(id, callID, value, isError: isError)
  }

  /// The orb assistant's answer in Glance's card, the way a `tell` shows (its question muted above it), sized to fit.
  /// Not read aloud here: the assistant speaks only the part before `---`.
  func showAssistantReply(asked: String, markdown: String) {
    let session = book.sessions.values.first { $0.assistant }
      ?? ChannelBook.Session(id: -1, label: "Glance", projectDir: nil, surface: nil, channel: false, assistant: true,
                             now: Date())
    if let onTell {
      onTell(session, markdown, .auto, false, asked)
    } else {
      NotificationHub.shared.post(ChannelNotices.message(
        id: "orb-" + UUID().uuidString, label: "Glance", surface: nil, cwd: nil, title: TellCard.headline(markdown),
        body: nil, date: Date()))
    }
  }

  /// A permission prompt becomes an Allow/Deny card (the terminal's own prompt runs in parallel; whichever answer
  /// comes first wins inside Claude Code, and Claude Code tells nobody when the terminal wins, so the card stays
  /// until it is answered, ✕, or the session ends).
  private func permissionRequest(_ id: SessionID, _ request: ChannelWire.PermissionRequest) {
    if let surface = book.sessions[id]?.surface, promptCovers?(surface, request.tool) == true { return }
    guard Prefs.orbChannelApprovals || book.sessions[id]?.assistant == true,
          book.permission(session: id, request: request, now: Date()) != nil else { return }
    changed()
  }

  /// The permission card the keys act on, once it is the active one: read it aloud (once per card).
  private func speakActivePermission() {
    guard let card = book.active, card.id != spokenPermissionID, case .permission(_, let tool, _) = card.kind else {
      return
    }
    spokenPermissionID = card.id
    guard Prefs.orbChannelReadQuestions, SpeechQueue.quietReason() == nil,
          let label = book.sessions[card.session]?.label else { return }
    SpeechQueue.shared.say("\(label) wants to use \(tool). Allow?", interrupt: false) { _ in }
  }

  // MARK: - From the user

  /// A card was answered (button, typed, spoken, ✕).
  public func answer(_ cardID: String, _ answer: ChannelBook.Answer, via: ChannelBook.Via) {
    // ✕ on the assistant's Allow / Deny card is a no.
    if answer == .dismissed, let card = book.cards.first(where: { $0.id == cardID }),
       case .permission(let requestID, _, _) = card.kind, approvals[requestID]?.session == card.session,
       let approval = approvals.removeValue(forKey: requestID) {
      reply(approval.session, approval.callID, AssistantPolicy.approveResult(allow: false, input: approval.input),
            isError: false)
    }
    perform(book.answer(cardID, answer, via: via))
    changed()
  }

  /// The next waiting card becomes the active one.
  public func next() {
    book.next()
    changed()
  }

  /// A message into a session (its channel). False when it has none.
  @discardableResult
  public func push(to id: SessionID, text: String, via: ChannelBook.Via) -> Bool {
    guard book.sessions[id]?.channel == true else { return false }
    return server.send(ChannelWire.ToShim.push(content: text, meta: ["from": "glance", "via": via.rawValue]).line, to: id)
  }

  /// Studio: types a message into a session's split (for sessions without a channel).
  public var typeIntoSession: ((ChannelBook.Session, String) -> Bool)?

  /// A message to the session with this handle (`ChannelBook.handle(of:)`: its label, numbered when two share one).
  /// Through its channel when it has one; otherwise Studio types it into its split. False when neither works.
  @discardableResult
  public func message(handle: String, text: String, via: ChannelBook.Via) -> Bool {
    guard let session = book.session(handle: handle) else { return false }
    if session.channel { return push(to: session.id, text: text, via: via) }
    return typeIntoSession?(session, text) ?? false
  }

  // MARK: - Effects

  func perform(_ effects: [ChannelBook.Effect]) {
    for effect in effects {
      switch effect {
      case .reply(let id, let callID, let value, let isError):
        reply(id, callID, value, isError: isError)
      case .notify(let id, _, let title, let body):
        let session = book.sessions[id]
        NotificationHub.shared.post(ChannelNotices.message(
          id: "orb-" + UUID().uuidString, label: session?.label ?? "Claude", surface: session?.surface,
          cwd: session?.projectDir, title: title, body: body, date: Date()))
      case .push(let id, let content, let meta):
        server.send(ChannelWire.ToShim.push(content: content, meta: meta).line, to: id)
      case .verdict(let id, let requestID, let allow):
        if approvals[requestID]?.session == id, let approval = approvals.removeValue(forKey: requestID) {
          reply(approval.session, approval.callID, AssistantPolicy.approveResult(allow: allow, input: approval.input),
                isError: false)
        } else {
          server.send(ChannelWire.ToShim.verdict(requestID: requestID, allow: allow).line, to: id)
        }
      case .answered(let card, let answer, _):
        let session = book.sessions[card.session]
        NotificationHub.shared.add(ChannelNotices.answered(
          id: "orb-" + UUID().uuidString, label: session?.label ?? "Claude", surface: session?.surface,
          cwd: session?.projectDir, question: card.title, said: ChannelNotices.said(answer), date: Date()))
      }
    }
  }

  public func reply(_ id: SessionID, _ callID: String, _ value: JSONValue, isError: Bool) {
    server.send(ChannelWire.ToShim.result(callID: callID, value: value, isError: isError).line, to: id)
  }

  /// After every change: the orb, and the clock that times waiting calls and fading states.
  func changed() {
    ChannelCards.shared.update(book: book)
    speakActivePermission()
    let now = Date()
    refreshOrb(now: now)
    let needsClock = book.needsClock(now: now) || !approvals.isEmpty
    if needsClock, clock == nil {
      let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tickClock() }
      }
      RunLoop.main.add(timer, forMode: .common)
      clock = timer
    } else if !needsClock {
      clock?.invalidate()
      clock = nil
    }
  }

  private func tickClock() {
    expireApprovals(now: Date())
    perform(book.tick(now: Date()))
    changed()
  }

  /// The assistant's Allow / Deny cards left unanswered past their deadline: the card goes, the answer is no.
  private func expireApprovals(now: Date) {
    for (requestID, approval) in approvals where approval.deadline <= now {
      approvals[requestID] = nil
      reply(approval.session, approval.callID, ["behavior": "deny", "message": "No answer in time."], isError: false)
      // ✕ on a permission card only removes it (no verdict).
      if let cardID = approval.cardID { _ = book.answer(cardID, .dismissed, via: .click) }
    }
  }

  private func refreshOrb(now: Date = Date()) {
    var state = book.orbState(now: now)
    if assistantWorking, state == nil || state == .done { state = .working }
    let mode = ChannelBook.orbMode(state: state, listening: listening, speaking: speaking)
    // Only sessions whose state is still live (done and error fade, as in `orbState`).
    let latest = book.sessions.values.filter { session in
      guard let state = session.state else { return false }
      return !((state == .done || state == .error) && now.timeIntervalSince(session.stateSince) >= ChannelBook.fade)
    }.max { $0.stateSince < $1.stateSince }
    let caption = latest.map { session in [session.label, session.caption].compactMap { $0 }.joined(separator: ": ") }
      ?? (assistantWorking ? "Glance: Thinking…" : nil)
    OrbAttention.setChannel(mode: mode, caption: caption)
  }
}
