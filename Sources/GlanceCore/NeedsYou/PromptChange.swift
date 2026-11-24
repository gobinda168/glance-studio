import Foundation

/// The file and lines an Edit / MultiEdit / Write call would change, from the pending call's own input.
public struct PromptChange: Equatable, Sendable {
  public let path: String?
  public let lines: [DiffLine]

  public init?(call: ToolCall) {
    let input = call.input
    switch call.name {
    case "Edit":
      guard let old = input["old_string"]?.string, let new = input["new_string"]?.string else { return nil }
      lines = TextDiff.lines(old: old, new: new)
    case "MultiEdit":
      guard let edits = input["edits"]?.array else { return nil }
      lines = edits.flatMap { edit -> [DiffLine] in
        guard let old = edit["old_string"]?.string, let new = edit["new_string"]?.string else { return [] }
        return TextDiff.lines(old: old, new: new)
      }
    case "Write":
      guard let content = input["content"]?.string else { return nil }
      lines = content.components(separatedBy: "\n").map { DiffLine(mark: .added, text: $0) }
    default:
      return nil
    }
    guard !lines.isEmpty else { return nil }
    path = input["file_path"]?.string
  }
}

/// What a prompt card shows a permission approves. The dialog comes from this split's screen, so its text is what Yes
/// approves. The diff comes from the tool call `PromptBook` picked, by folder: with two sessions or two parallel calls there
/// it can be someone else's or another change.
public enum PromptDetail: Equatable, Sendable {
  case change(PromptChange)
  /// The dialog's own lines.
  case dialog([String])
  case none

  /// The Glance view's: the diff once it is known to be this session's and the one on screen, for its "Show all", else the
  /// dialog. `session`: the one the split runs, nil when that isn't known.
  public static func of(_ prompt: PendingPrompt, session: String?) -> PromptDetail {
    if let change = PromptChange(call: prompt.call), let session, belongs(prompt, to: session),
      callIsOnScreen(prompt.call, prompt.screen) { return .change(change) }
    return onScreen(prompt)
  }

  /// The board's: the dialog's own lines and nothing from the book's call, so Yes can only approve what's drawn.
  /// `BoardPromptGuard.offersAnswers` already wants them whole.
  public static func onScreen(_ prompt: PendingPrompt) -> PromptDetail {
    prompt.screen.detail.isEmpty ? .none : .dialog(prompt.screen.detail)
  }

  /// `of` falls back to a dialog cut to its last lines: the card must say it is only the end of something longer.
  public static func showsOnlyTheEnd(_ prompt: PendingPrompt, session: String?) -> Bool {
    guard case .dialog = of(prompt, session: session) else { return false }
    return !prompt.screen.detailIsWhole
  }

  /// The words under a detail too tall for its box, so its end can't sit unseen below the fold above Yes; nil when it all
  /// fits. A scroller can't say this: macOS hides it until scrolling unless the user set it otherwise. `height` 0 is not yet
  /// measured, which could be anything. `lines`: the dialog's, as a narrow card wraps them into more.
  public static func overflowCue(height: Double, limit: Double, lines: Int) -> String? {
    guard lines > 0, height <= 0 || height > limit else { return nil }
    return lines > 1 ? "\(lines) lines. Scroll to see the end." : "Scroll to see the end."
  }

  /// The call's transcript is this session's. A subagent's transcript has a name of its own, so it answers to no session.
  static func belongs(_ prompt: PendingPrompt, to session: String) -> Bool {
    guard let path = prompt.transcript, path.hasSuffix(".jsonl") else { return false }
    return (path as NSString).lastPathComponent.dropLast(".jsonl".count) == session
  }

  /// The tools whose dialog repeats their input: the call must be the one the dialog is about. Any other tool has nothing
  /// to compare, and a card shows only the screen's own text for it, which is the dialog whichever call the book picked.
  static func callIsOnScreen(_ call: ToolCall, _ screen: DialogScreen) -> Bool {
    let seen = squeezed(([screen.question ?? ""] + screen.detail).joined())
    switch call.name {
    case "Bash":
      guard let command = call.input["command"]?.string.map(squeezed), !command.isEmpty else { return false }
      return seen.contains(command)
    case "Edit", "MultiEdit", "Write":
      guard let change = PromptChange(call: call), let path = change.path,
        seen.contains(squeezed((path as NSString).lastPathComponent)) else { return false }
      let changed = change.lines.filter { $0.mark != .context }.map { squeezed($0.text) }.filter { !$0.isEmpty }
      if screen.detailIsWhole { return changed.allSatisfy(seen.contains) }
      return endIsOnScreen(changed, seen)
    default:
      return true
    }
  }

  /// The screen keeps only the dialog's last lines, so the end of the change is all that can be there: its last lines, in
  /// order, and enough of them that a closing brace alone doesn't count.
  private static func endIsOnScreen(_ changed: [String], _ seen: String) -> Bool {
    let end = changed.suffix(3)
    guard end.joined().count >= 20 else { return false }
    var from = seen.startIndex
    for line in end {
      guard let found = seen.range(of: line, range: from..<seen.endIndex) else { return false }
      from = found.upperBound
    }
    return true
  }

  /// The screen wraps long lines and the parser trims them, so text is compared without its white space.
  static func squeezed(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
  }
}
