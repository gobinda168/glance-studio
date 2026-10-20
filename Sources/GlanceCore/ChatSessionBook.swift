import Foundation

/// One project's editor-chat sessions: the headless Claude Code sessions Glance started for it, newest first, and the
/// one the chat is on. A nil `active` is a blank chat: its session starts with the next message.
public struct ChatSessionBook: Equatable, Sendable {
  public static let limit = 20

  public private(set) var ids: [String]
  public private(set) var active: String?

  public init(ids: [String] = [], active: String? = nil) {
    self.ids = ids
    self.active = active
  }

  /// Reads what `stored` wrote, or the single id older builds kept per project.
  public init(stored: Any?) {
    if let id = stored as? String {
      self.init(ids: [id], active: id)
    } else if let dictionary = stored as? [String: Any] {
      let ids = (dictionary["ids"] as? [Any] ?? []).compactMap { $0 as? String }
      let active = (dictionary["active"] as? String).flatMap { ids.contains($0) ? $0 : nil }
      self.init(ids: ids, active: active)
    } else {
      self.init()
    }
  }

  public var stored: [String: Any] {
    var dictionary: [String: Any] = ["ids": ids]
    if let active { dictionary["active"] = active }
    return dictionary
  }

  /// A message went to this session: it moves to the front and is the one the chat is on.
  public mutating func use(_ id: String) {
    ids.removeAll { $0 == id }
    ids.insert(id, at: 0)
    if ids.count > Self.limit { ids.removeLast(ids.count - Self.limit) }
    active = id
  }

  /// Switches to a session in the list (the order stays; a send moves it up).
  public mutating func activate(_ id: String) {
    if ids.contains(id) { active = id }
  }

  public mutating func startBlank() { active = nil }

  /// Forgets the sessions `missing` says are gone (transcript deleted), except the active one: its transcript doesn't
  /// exist until Claude writes the first message.
  public mutating func prune(missing: (String) -> Bool) {
    ids.removeAll { $0 != active && missing($0) }
  }
}

/// A session as the picker lists it.
public struct ChatSessionEntry: Equatable, Sendable {
  public let id: String
  /// The first prompt; nil until one is written.
  public let title: String?
  public let updated: Date

  public init(id: String, title: String?, updated: Date) {
    self.id = id
    self.title = title
    self.updated = updated
  }
}
