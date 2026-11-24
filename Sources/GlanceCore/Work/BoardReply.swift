import Foundation

/// A reply from a card is typed into a real terminal. These decide what is typed and whether it may go: when anything is
/// unknown, it doesn't.
public enum BoardReply {
  /// One split, as it is the moment the reply goes.
  public struct Split: Equatable, Sendable {
    public var surface: UUID
    public var linkedSession: String?
    /// Its foreground process is `claude`.
    public var runsClaude: Bool
    /// Glance's book holds a prompt for it.
    public var hasPrompt: Bool
    /// Its visible text, read now; nil when it couldn't be read.
    public var screen: String?
    /// Bracketed paste is on in its terminal; nil when that can't be told.
    public var bracketedPaste: Bool?
    /// `BoardReply.callJustStarted`: a dialog may be about to open.
    public var callJustStarted: Bool

    public init(surface: UUID, linkedSession: String?, runsClaude: Bool, hasPrompt: Bool, screen: String?, bracketedPaste: Bool?,
                callJustStarted: Bool = false) {
      self.surface = surface
      self.linkedSession = linkedSession
      self.runsClaude = runsClaude
      self.hasPrompt = hasPrompt
      self.screen = screen
      self.bracketedPaste = bracketedPaste
      self.callJustStarted = callJustStarted
    }
  }

  /// The sessions whose reply was pasted and its Return held back: that text may still be on the line, and a second paste
  /// would double it. Clearing the line takes another key into a terminal already found not to be safe, so a retry is
  /// refused until the user has opened the tab and can see.
  public struct HeldReplies: Equatable, Sendable {
    private var surfaces: [String: UUID] = [:]
    public init() {}
    public func isHeld(_ session: String) -> Bool { surfaces[session] != nil }
    /// The split the text went to: with two tabs on one session, it's the one to open.
    public func surface(of session: String) -> UUID? { surfaces[session] }
    public mutating func hold(_ session: String, on surface: UUID) { surfaces[session] = surface }
    public mutating func opened(_ session: String) { surfaces[session] = nil }
  }

  /// What to do about the Return, a moment after the paste.
  public enum ReturnGate: Equatable, Sendable {
    case press
    /// Nothing else is wrong, and the text isn't on the line yet (Claude may still be drawing it) or a call was just made.
    /// Ask again shortly.
    case wait
    case hold
  }

  /// How much of a reply's end has to be on the input line: enough to tell it from anything else, and short enough to fit
  /// on screen however long the reply. A short reply is matched whole.
  static let matchedEnd = 40
  /// Longer than this, or on several lines, Claude Code may draw `[Pasted text #1 +N lines]` instead of the text.
  static let collapsedFrom = 200

  /// The text as it is pasted: one kind of newline and no way out of the paste. An escape sequence goes whole, so nothing
  /// of `ESC [ 201 ~` (the paste's end marker) is left to act, and no other control character can submit or edit the line.
  public static func sanitized(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    let scalars = Array(text.unicodeScalars)
    var index = 0
    while index < scalars.count {
      let scalar = scalars[index]
      index += 1
      switch scalar.value {
      case 0x0D:
        if index < scalars.count, scalars[index].value == 0x0A { index += 1 }
        out.append("\n")
      case 0x0A, 0x85, 0x2028, 0x2029:
        out.append("\n")
      case 0x09:
        out.append(" ")
      case 0x1B:
        index = afterEscape(scalars, from: index)
      case 0x9B:
        index = afterCSI(scalars, from: index)
      case 0x00...0x1F, 0x7F...0x9F:
        break
      default:
        out.append(scalar)
      }
    }
    return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The split to type into, of `splits` given best first (`BoardEntries.targets`), or nil to refuse. A split with a dialog
  /// is not passed over for another: the session is waiting on the user, and the reply would answer nothing.
  public static func target(for session: String, text: String, among splits: [Split]) -> UUID? {
    guard let split = splits.first(where: { $0.linkedSession == session && $0.runsClaude }),
      mayPressReturn(session: session, split: split) else { return nil }
    // Without bracketed paste the terminal turns each LF into CR, and the first line would submit by itself.
    if text.contains("\n"), split.bracketedPaste != true { return nil }
    return split.surface
  }

  /// Just before Return, all of it again: a Return that lands in a shell runs the text, and one that lands in a dialog
  /// approves its selected option. Without it the text stays on the line, which is harmless.
  public static func mayPressReturn(session: String, split: Split?) -> Bool {
    guard let split, split.linkedSession == session, split.runsClaude, !split.hasPrompt, let screen = split.screen else { return false }
    return PromptScreen.atInput(screen)
  }

  /// Just before Return. `mayPressReturn` proves a frame is on screen, and a frame can outlive whoever drew it: with
  /// `claude -p` in front of an old input box, the text and the Return sit in the tty queue and reach the shell when it
  /// exits. Only a live Claude reading its input draws the reply on that line, so a Return follows only that, and not
  /// while a call just made may be opening a dialog.
  public static func returnGate(session: String, split: Split?, text: String) -> ReturnGate {
    guard mayPressReturn(session: session, split: split), let split, let screen = split.screen, let box = PromptScreen.inputBox(screen),
      !PromptDetail.squeezed(text).isEmpty else { return .hold }
    return !split.callJustStarted && inputHolds(text, box: box) ? .press : .wait
  }

  /// The paste lands at the cursor, at the end of what's on the line, so the line must end with the reply. White space
  /// goes first, as the box wraps.
  private static func inputHolds(_ text: String, box: [String]) -> Bool {
    if text.contains("\n") || text.count >= collapsedFrom, box.contains(where: { $0.contains("[Pasted text") }) { return true }
    return PromptDetail.squeezed(box.joined()).hasSuffix(String(PromptDetail.squeezed(text).suffix(matchedEnd)))
  }

  /// How long a tool call that may open a dialog is waited out.
  static let callLead: TimeInterval = 1

  /// This session has a call under a second old that may open a dialog. The call should reach the transcript before its
  /// dialog is drawn, and a Return in that gap approves the dialog's selected row, so it waits. This narrows the window and
  /// doesn't close it. A subagent's transcript sits under its parent's id, and its dialog comes up in the parent's terminal.
  public static func callJustStarted(waiting: [PromptBook.Waiting], session: String, now: Date) -> Bool {
    waiting.contains {
      $0.file.contains(session) && !ChangeTracker.readOnlyTools.contains($0.call.name) && now.timeIntervalSince($0.since) < callLead
    }
  }

  /// Past an ESC: a CSI or string sequence to its end, anything else one character.
  private static func afterEscape(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
    guard start < scalars.count else { return start }
    switch scalars[start] {
    case "[":
      return afterCSI(scalars, from: start + 1)
    case "]", "P", "X", "^", "_":
      var index = start + 1
      while index < scalars.count {
        if scalars[index].value == 0x07 || scalars[index].value == 0x9C { return index + 1 }
        if scalars[index].value == 0x1B, index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
        index += 1
      }
      // Never ended, so it wasn't one: only the ESC and its introducer go, and the reply isn't cut short.
      return start + 1
    default:
      return start + 1
    }
  }

  /// Past a CSI's parameters and its final byte.
  private static func afterCSI(_ scalars: [Unicode.Scalar], from start: Int) -> Int {
    var index = start
    while index < scalars.count, (0x20...0x3F).contains(scalars[index].value) { index += 1 }
    if index < scalars.count, (0x40...0x7E).contains(scalars[index].value) { index += 1 }
    return index
  }
}
