import Foundation

/// The orb channel's state (spec 2026-10-09-orb-channel-design.md, "Cards and the queue"): the Claude sessions
/// connected through `glance mcp`, the cards waiting on the user, the tool calls blocked on them, answers not yet
/// collected, and what the orb shows. Pure: Studio's hub feeds it calls, clicks and the clock, and carries out the
/// effects it returns.
public struct ChannelBook: Sendable {
  public typealias SessionID = Int32

  /// `done` and `error` show this long, then the orb calms down.
  public static let fade: TimeInterval = 6

  public struct Session: Equatable, Sendable {
    public let id: SessionID
    public var label: String
    public var projectDir: String?
    /// The Studio split it runs in (a surface UUID), nil outside Studio.
    public var surface: String?
    /// Launched with the channel flag: Glance can message it first.
    public var channel: Bool
    /// The orb assistant's own `claude`.
    public var assistant: Bool
    public var state: ChannelOrbState?
    public var caption: String?
    public var stateSince: Date

    public init(id: SessionID, label: String, projectDir: String?, surface: String?, channel: Bool, assistant: Bool,
                now: Date) {
      self.id = id
      self.label = label
      self.projectDir = projectDir
      self.surface = surface
      self.channel = channel
      self.assistant = assistant
      self.stateSince = now
    }
  }

  public enum Kind: Equatable, Sendable {
    case nudge(actions: [String])
    case question(choices: [String], allowText: Bool)
    case permission(requestID: String, tool: String, input: String)
  }

  public struct Waiter: Equatable, Sendable {
    public let callID: String
    public let deadline: Date
  }

  public struct Card: Equatable, Identifiable, Sendable {
    public let id: String
    public let session: SessionID
    public let kind: Kind
    public let title: String
    public let body: String?
    public let created: Date
    /// The tool call blocked on this card, and when it stops waiting.
    public var waiter: Waiter?
    /// The call stopped waiting: the card says "Claude stopped waiting — answer anyway".
    public var stoppedWaiting = false

    public var isPermission: Bool { if case .permission = kind { true } else { false } }
  }

  public enum Answer: Equatable, Sendable {
    case action(String), choice(String), text(String), allow, deny, dismissed
  }

  public enum Via: String, Codable, Sendable { case click, text, voice }

  public enum Effect: Equatable, Sendable {
    /// Answer a blocked or finished tool call.
    case reply(SessionID, callID: String, value: JSONValue, isError: Bool)
    /// A nudge without actions: a notification card and a Notifications item.
    case notify(SessionID, id: String, title: String, body: String?)
    /// A message into the session (needs its channel).
    case push(SessionID, content: String, meta: [String: String])
    case verdict(SessionID, requestID: String, allow: Bool)
    /// For the Notifications page.
    case answered(Card, Answer, Via)
  }

  private struct Kept: Sendable {
    let session: SessionID
    let value: JSONValue
  }

  public private(set) var sessions: [SessionID: Session] = [:]
  /// Oldest first.
  public private(set) var cards: [Card] = []
  private var activeID: String?
  /// Answers given after their call stopped waiting, for `check_answer`.
  private var kept: [String: Kept] = [:]
  private var serial = 0

  public init() {}

  // MARK: - Sessions

  public mutating func open(_ session: Session) { sessions[session.id] = session }

  public mutating func update(_ id: SessionID, _ change: (inout Session) -> Void) {
    guard var session = sessions[id] else { return }
    change(&session)
    sessions[id] = session
  }

  /// A name that picks this session out: its label, or "label 2", "label 3"… when other sessions share the label
  /// (numbered by session id; the lowest keeps the plain label). The assistant's own `claude` never takes part.
  public func handle(of id: SessionID) -> String {
    guard let session = sessions[id] else { return "Claude" }
    guard !session.assistant else { return session.label }
    let same = sessions.values.filter { $0.label == session.label && !$0.assistant }.map(\.id).sorted()
    guard let index = same.firstIndex(of: id), index > 0 else { return session.label }
    return "\(session.label) \(index + 1)"
  }

  /// The (non-assistant) session with exactly this handle.
  public func session(handle: String) -> Session? {
    sessions.values.filter { !$0.assistant }.sorted { $0.id < $1.id }.first { self.handle(of: $0.id) == handle }
  }

  /// The session ended: its cards and kept answers go; nothing is sent to it.
  public mutating func close(_ id: SessionID) {
    sessions[id] = nil
    cards.removeAll { $0.session == id }
    kept = kept.filter { $0.value.session != id }
    if let activeID, !cards.contains(where: { $0.id == activeID }) { self.activeID = nil }
  }

  // MARK: - Cards

  /// Drops a card without answering it (another card covers it: Studio's prompt card for the same permission).
  public mutating func discard(_ id: String) {
    cards.removeAll { $0.id == id }
    if activeID == id { activeID = nil }
  }

  /// The card hold-fn and the card keys act on: the one chosen with `next()`, else the oldest.
  public var active: Card? { cards.first { $0.id == activeID } ?? cards.first }

  public mutating func next() {
    guard cards.count > 1, let active, let index = cards.firstIndex(where: { $0.id == active.id }) else { return }
    activeID = cards[(index + 1) % cards.count].id
  }

  public mutating func nudge(session: SessionID, callID: String, title: String, body: String?, actions: [String],
                             wait: Int, now: Date) -> (id: String, effects: [Effect]) {
    let id = newID()
    guard !actions.isEmpty else {
      return (id, [.notify(session, id: id, title: title, body: body),
                   .reply(session, callID: callID, value: ["id": .string(id), "shown": true], isError: false)])
    }
    cards.append(Card(id: id, session: session, kind: .nudge(actions: actions), title: title, body: body, created: now,
                      waiter: Waiter(callID: callID, deadline: now.addingTimeInterval(TimeInterval(wait)))))
    return (id, [])
  }

  public mutating func ask(session: SessionID, callID: String, question: String, choices: [String], allowText: Bool,
                           wait: Int, now: Date) -> (id: String, effects: [Effect]) {
    let id = newID()
    cards.append(Card(id: id, session: session, kind: .question(choices: choices, allowText: allowText),
                      title: question, body: nil, created: now,
                      waiter: Waiter(callID: callID, deadline: now.addingTimeInterval(TimeInterval(wait)))))
    return (id, [])
  }

  /// A permission prompt from the session; nil when that request already has a card.
  public mutating func permission(session: SessionID, request: ChannelWire.PermissionRequest, now: Date) -> String? {
    let exists = cards.contains {
      if case .permission(let requestID, _, _) = $0.kind { requestID == request.requestID && $0.session == session }
      else { false }
    }
    guard !exists else { return nil }
    let id = newID()
    let label = sessions[session]?.label ?? "Claude"
    cards.append(Card(id: id, session: session,
                      kind: .permission(requestID: request.requestID, tool: request.tool, input: request.input),
                      title: "\(label) wants to use \(request.tool)",
                      body: request.description.isEmpty ? nil : request.description, created: now))
    return id
  }

  public mutating func checkAnswer(session: SessionID, callID: String, id: String, wait: Int, now: Date) -> [Effect] {
    if let answer = kept[id], answer.session == session {
      kept[id] = nil
      return [.reply(session, callID: callID, value: answer.value, isError: false)]
    }
    guard let index = cards.firstIndex(where: { $0.id == id && $0.session == session && !$0.isPermission }) else {
      return [.reply(session, callID: callID, value: .string("No question or nudge with id \(id) is waiting."),
                     isError: true)]
    }
    var effects: [Effect] = []
    if let old = cards[index].waiter {
      effects.append(.reply(session, callID: old.callID, value: Self.pending(id), isError: false))
    }
    guard wait > 0 else {
      cards[index].waiter = nil
      effects.append(.reply(session, callID: callID, value: Self.pending(id), isError: false))
      return effects
    }
    cards[index].waiter = Waiter(callID: callID, deadline: now.addingTimeInterval(TimeInterval(wait)))
    cards[index].stoppedWaiting = false
    return effects
  }

  /// The user answered a card (click, typed, spoken, or ✕ as `.dismissed`).
  public mutating func answer(_ id: String, _ answer: Answer, via: Via) -> [Effect] {
    guard let index = cards.firstIndex(where: { $0.id == id }) else { return [] }
    if case .permission(let requestID, _, _) = cards[index].kind {
      // Only allow, deny or ✕ settle a permission card; anything else leaves it in place.
      let session = cards[index].session
      switch answer {
      case .allow, .deny, .dismissed:
        cards.remove(at: index)
        if activeID == id { activeID = nil }
        if answer == .dismissed { return [] }
        return [.verdict(session, requestID: requestID, allow: answer == .allow)]
      default: return []
      }
    }
    let card = cards.remove(at: index)
    if activeID == id { activeID = nil }
    var effects: [Effect] = []
    let value = Self.value(answer, via: via, id: card.id)
    if let waiter = card.waiter {
      effects.append(.reply(card.session, callID: waiter.callID, value: value, isError: false))
    } else if sessions[card.session]?.channel == true {
      if answer != .dismissed {
        effects.append(.push(card.session, content: Self.lateText(card, answer),
                             meta: ["from": "glance", "via": via.rawValue, "card": card.id]))
      }
    } else {
      kept[card.id] = Kept(session: card.session, value: value)
    }
    if answer != .dismissed { effects.append(.answered(card, answer, via)) }
    return effects
  }

  /// The session takes its own card away.
  public mutating func dismiss(session: SessionID, callID: String, id: String) -> [Effect] {
    guard let index = cards.firstIndex(where: { $0.id == id && $0.session == session && !$0.isPermission }) else {
      return [.reply(session, callID: callID, value: .string("No card with id \(id)."), isError: true)]
    }
    let card = cards.remove(at: index)
    if activeID == id { activeID = nil }
    var effects: [Effect] = []
    if let waiter = card.waiter {
      effects.append(.reply(session, callID: waiter.callID, value: Self.value(.dismissed, via: .click, id: id),
                            isError: false))
    }
    effects.append(.reply(session, callID: callID, value: ["ok": true], isError: false))
    return effects
  }

  /// Calls whose time is up get "pending"; their cards stay.
  public mutating func tick(now: Date) -> [Effect] {
    var effects: [Effect] = []
    for index in cards.indices {
      guard let waiter = cards[index].waiter, waiter.deadline <= now else { continue }
      effects.append(.reply(cards[index].session, callID: waiter.callID, value: Self.pending(cards[index].id),
                            isError: false))
      cards[index].waiter = nil
      cards[index].stoppedWaiting = true
    }
    return effects
  }

  // MARK: - Status and the orb

  public mutating func status(session: SessionID, callID: String, state: ChannelOrbState?, caption: String?,
                              now: Date) -> [Effect] {
    guard sessions[session] != nil else { return [] }
    update(session) { session in
      if let state {
        session.state = state == .idle ? nil : state
        session.stateSince = now
      }
      if let caption { session.caption = caption }
    }
    return [.reply(session, callID: callID, value: ["ok": true], isError: false)]
  }

  /// Cards waiting on the user first, then the sessions' states: waiting, error, working, done (error and done fade).
  public func orbState(now: Date) -> ChannelOrbState? {
    if !cards.isEmpty { return .waiting }
    let live = sessions.values.compactMap { session -> ChannelOrbState? in
      guard let state = session.state else { return nil }
      if state == .done || state == .error, now.timeIntervalSince(session.stateSince) >= Self.fade { return nil }
      return state
    }
    return [ChannelOrbState.waiting, .error, .working, .done].first(where: live.contains)
  }

  /// Something will change on its own later: a waiter's deadline or a state fading.
  public func needsClock(now: Date) -> Bool {
    cards.contains { $0.waiter != nil }
      || sessions.values.contains { ($0.state == .done || $0.state == .error)
        && now.timeIntervalSince($0.stateSince) < Self.fade }
  }

  // MARK: - Words

  public static func label(projectDir: String?, cwd: String, home: String) -> String {
    let path = projectDir.flatMap { $0.isEmpty ? nil : $0 } ?? cwd
    if path == home { return "~" }
    let name = (path as NSString).lastPathComponent
    return name.isEmpty ? path : name
  }

  /// "Claude in glance asks: …? Revert, or Fix forward?"
  public static func spokenQuestion(label: String, question: String, choices: [String]) -> String {
    var text = "Claude in \(label) asks: \(question)"
    if !choices.isEmpty {
      let list = choices.count == 1 ? choices[0]
        : choices.dropLast().joined(separator: ", ") + ", or " + choices[choices.count - 1]
      text += " \(list)?"
    }
    return text
  }

  public static func pending(_ id: String) -> JSONValue {
    ["status": "pending", "id": .string(id),
     "note": "The card is still on the user's screen. Call check_answer later to collect the answer."]
  }

  static func value(_ answer: Answer, via: Via, id: String) -> JSONValue {
    switch answer {
    case .action(let title): ["id": .string(id), "action": .string(title), "via": .string(via.rawValue)]
    case .choice(let text), .text(let text): ["id": .string(id), "answer": .string(text), "via": .string(via.rawValue)]
    case .allow: ["id": .string(id), "answer": "allow", "via": .string(via.rawValue)]
    case .deny: ["id": .string(id), "answer": "deny", "via": .string(via.rawValue)]
    case .dismissed: ["id": .string(id), "dismissed": true]
    }
  }

  static func lateText(_ card: Card, _ answer: Answer) -> String {
    let said: String
    switch answer {
    case .action(let text), .choice(let text), .text(let text): said = text
    case .allow: said = "allow"
    case .deny: said = "deny"
    case .dismissed: said = "dismissed"
    }
    return "The user answered your earlier question \"\(card.title)\" (id \(card.id)): \(said)"
  }

  private mutating func newID() -> String {
    serial += 1
    return "g\(serial)"
  }
}
