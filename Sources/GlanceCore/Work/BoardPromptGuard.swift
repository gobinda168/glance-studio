import Foundation

/// Whether a card on the board may answer a permission prompt. An answer approves a real command, so anything that can't
/// be established means no: the card offers "Open to answer" and nothing is pressed.
///
/// What a prompt really is: the dialog comes from reading the split's screen, and its tool call is `PromptBook`'s pick of
/// the newest unsettled call in that folder. Two sessions, or two parallel calls, in one folder can give it the wrong
/// call, so the call's id alone proves little: the transcript it came from and the screen's own text are checked as well.
public enum BoardPromptGuard {
  public enum Refusal: Equatable, Sendable {
    /// The prompt has no tool call id to hold on to.
    case noCall
    /// The card never offered this answer: what it would approve can't be shown or tied to this session.
    case notReadable
    /// The split no longer runs the card's session (/clear, a resume), or that can't be told.
    case sessionChanged
    case promptGone
    /// Another tool call, or the same id with another input.
    case callChanged
    case screenUnread
    /// The dialog on screen now isn't the one the card shows.
    case screenChanged
    /// The highlight isn't on the answer's row, or which row that is can't be told.
    case wrongRow
  }

  /// What to do about an answer's Enter, a moment after its arrows.
  public enum EnterGate: Equatable, Sendable {
    case press
    /// Nothing else is wrong and the highlight isn't on the row yet: Claude may still be drawing it. Read again shortly.
    case wait
    case refuse(Refusal)
  }

  /// The prompt a card shows: the one waiting in its split, while that split still runs the card's session.
  public static func prompt(in prompts: [PendingPrompt], surface: UUID, session: String, linked: String?) -> PendingPrompt? {
    guard linked == session else { return nil }
    return prompts.first { $0.surface == surface.uuidString }
  }

  /// The most options a card shows as buttons. Claude Code's Bash dialog has four once it offers auto mode.
  public static let maxOptions = 4

  /// Whether the card gets answer buttons rather than "Open to answer".
  public static func offersAnswers(_ prompt: PendingPrompt, session: String) -> Bool {
    let screen = prompt.screen
    guard !prompt.call.id.isEmpty, PromptDetail.belongs(prompt, to: session),
      let question = screen.question, !question.isEmpty,
      !screen.options.isEmpty, screen.options.count <= maxOptions,
      screen.submitAfter == nil, !screen.options.contains(where: { $0.checked != nil })
    else { return false }
    // The dialog on screen says what it is. A call the book picked for another kind of dialog says nothing about this one.
    guard let kind = screen.kind, kind == prompt.kind else { return false }
    switch kind {
    // A plan is too long for a card, and approving it unread is the thing to avoid.
    case .plan: return false
    // Nothing to approve: the question and its options are the whole of it, and the card shows both.
    case .question: return (screen.detail.isEmpty || screen.detailIsWhole) && callAsks(prompt.call, question)
    case .permission: return screen.detailIsWhole && !screen.detail.isEmpty && PromptDetail.callIsOnScreen(prompt.call, screen)
    }
  }

  /// The dialog's question is one this call asks. The parser keeps only a wrapped question's last line, so that much is matched.
  private static func callAsks(_ call: ToolCall, _ question: String) -> Bool {
    guard let questions = call.input["questions"]?.array else { return false }
    let shown = PromptDetail.squeezed(question)
    return questions.contains { asked in
      asked["question"]?.string.map { PromptDetail.squeezed($0).hasSuffix(shown) } ?? false
    }
  }

  /// How often Enter reads the highlight while it waits, and for how long, from the first read. A pty doesn't lose keys, but
  /// Claude can: two arrows taken as one while its event loop stalls, or a keybind on an arrow. Row 1 is Yes and the arrows
  /// go down, so a lost arrow lands nearer to yes. Half a second covers a slow redraw; the arrows may still arrive later, and
  /// then all that's left in the tab is a moved highlight.
  public static let enterRetry: TimeInterval = 0.05
  public static let enterPatience: TimeInterval = 0.5

  /// Just before Enter: all of `refusal` again, and the highlight on the row the answer means. A card sends only options, so
  /// anything else has no row to compare and refuses. `waited`: seconds since the first read.
  public static func enterGate(_ answer: PromptAnswer, shown: PendingPrompt, session: String, linked: String?, live: PendingPrompt?,
                               screen: DialogScreen?, waited: TimeInterval) -> EnterGate {
    if let refused = refusal(shown: shown, session: session, linked: linked, live: live, screen: screen) { return .refuse(refused) }
    guard let screen, case .option(let number) = answer,
      let row = screen.options.firstIndex(where: { $0.number == number }) else { return .refuse(.wrongRow) }
    if screen.selected == row { return .press }
    return waited < enterPatience ? .wait : .refuse(.wrongRow)
  }

  /// Checked at the click, against the book and a fresh read of the screen, and again by `enterGate`. Nil: answer.
  public static func refusal(shown: PendingPrompt, session: String, linked: String?, live: PendingPrompt?,
                             screen: DialogScreen?) -> Refusal? {
    guard !shown.call.id.isEmpty else { return .noCall }
    guard offersAnswers(shown, session: session) else { return .notReadable }
    guard linked == session else { return .sessionChanged }
    guard let live, live.surface == shown.surface else { return .promptGone }
    guard live.call == shown.call else { return .callChanged }
    guard let screen else { return .screenUnread }
    // The selection may move; everything the user read may not. The option text is its whole scope, notes included.
    guard screen.question == shown.screen.question, screen.detail == shown.screen.detail,
      screen.options == shown.screen.options, screen.detailIsWhole == shown.screen.detailIsWhole, screen.kind == shown.screen.kind
    else { return .screenChanged }
    return nil
  }
}
