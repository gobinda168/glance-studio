import Foundation

/// The board's keyboard (spec §5 "Acting"): where each key moves the selection.
public enum BoardKeys {
  public enum Action: Equatable, Sendable {
    case next, previous, nextNeedingYou
    /// 0-based, left to right.
    case lane(Int)
  }

  public static func selection(for action: Action, current: String?, cards: [BoardCard]) -> String? {
    let order = SessionBoard.ordered(cards).map(\.id)
    let index = current.flatMap { order.firstIndex(of: $0) }
    switch action {
    case .next:
      guard let index else { return order.first }
      return order[min(index + 1, order.count - 1)]
    case .previous:
      guard let index else { return order.first }
      return order[max(index - 1, 0)]
    case .nextNeedingYou:
      let needs = SessionBoard.ordered(cards, in: .needsYou).map(\.id)
      guard !needs.isEmpty else { return current }
      let at = current.flatMap { needs.firstIndex(of: $0) }
      return at.map { needs[($0 + 1) % needs.count] } ?? needs[0]
    case .lane(let lane):
      guard BoardLane.allCases.indices.contains(lane),
            let first = SessionBoard.ordered(cards, in: BoardLane.allCases[lane]).first else { return current }
      return first.id
    }
  }

  // MARK: Whether a key is the board's

  /// Where the keyboard is. `page` is the board with nothing focused in it: the window itself or the tab's root view.
  /// Everything else is `elsewhere`: a web view, a terminal surface, the Glance pane, a list, another field.
  public enum Focus: Equatable, Sendable { case page, replyBox, elsewhere }

  public struct Context: Equatable, Sendable {
    /// This board's window is the key window and the event is for it.
    public var boardIsKey: Bool
    /// No command, control or option.
    public var plain: Bool
    public var focus: Focus
    public var replyOpen: Bool
    /// Tab can put the focus on a control. SwiftUI keeps that inside the root view, where the responder doesn't show it.
    public var fullKeyboardAccess: Bool

    public init(boardIsKey: Bool, plain: Bool, focus: Focus, replyOpen: Bool, fullKeyboardAccess: Bool) {
      self.boardIsKey = boardIsKey
      self.plain = plain
      self.focus = focus
      self.replyOpen = replyOpen
      self.fullKeyboardAccess = fullKeyboardAccess
    }
  }

  public enum Command: Equatable, Sendable {
    case move(Action)
    case open
    case startReply
    case closeReply
  }

  private static let returnKey: UInt16 = 36
  private static let escapeKey: UInt16 = 53

  /// What a key press does on the board, or nil to leave it to whoever has the keyboard. No key answers a prompt: 1-4 go
  /// to a lane on every card, and a prompt is answered only by clicking what it shows.
  public static func command(characters: String?, keyCode: UInt16, in context: Context) -> Command? {
    guard context.boardIsKey, context.plain else { return nil }
    switch context.focus {
    case .elsewhere:
      return nil
    case .replyBox:
      return keyCode == escapeKey && context.replyOpen ? .closeReply : nil
    case .page:
      // The reply box is up but doesn't have the keyboard yet (or lost it): the first letters of a reply aren't commands.
      if context.replyOpen { return keyCode == escapeKey ? .closeReply : nil }
    }
    switch characters {
    case "j": return .move(.next)
    case "k": return .move(.previous)
    case "n": return .move(.nextNeedingYou)
    case "1", "2", "3", "4": return characters.flatMap(Int.init).map { .move(.lane($0 - 1)) }
    case "r": return .startReply
    default: return keyCode == returnKey && !context.fullKeyboardAccess ? .open : nil
    }
  }
}
