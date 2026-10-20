import Foundation

/// A key Studio presses in a split (text is pasted).
public enum PromptKey: Equatable, Sendable { case up, down, enter, escape, space, tab, text(String) }

/// What the user picked on a prompt card. Options are by their on-screen number.
public enum PromptAnswer: Equatable, Sendable {
  case option(Int)
  case toggle(Int)
  case submit
  case note(String)
}

/// Turns an answer into the keys that give it in Claude Code's dialog. Selection moves with arrows from the row
/// that's selected now (number shortcuts differ between dialogs), then Enter. Checked against `Fixtures/prompts`.
/// Moves count navigation positions: a multi-select's unnumbered "Submit" row is a stop of its own.
public enum PromptKeys {
  /// Ticks a multi-select box (Fixtures/prompts/NOTES.md, `question-multiselect-space`).
  public static let toggleKey: PromptKey = .space

  public static func keys(_ answer: PromptAnswer, kind: PromptKind, screen: DialogScreen) -> [PromptKey]? {
    switch answer {
    case .option(let number):
      guard let index = screen.options.firstIndex(where: { $0.number == number }) else { return nil }
      return move(from: position(screen.selected, screen), to: position(index, screen)) + [.enter]
    case .toggle(let number):
      guard let index = screen.options.firstIndex(where: { $0.number == number }),
        screen.options[index].checked != nil else { return nil }
      return move(from: position(screen.selected, screen), to: position(index, screen)) + [toggleKey]
    case .submit:
      if let index = screen.options.firstIndex(where: { isSubmit($0.label) }) {
        return move(from: position(screen.selected, screen), to: position(index, screen)) + [.enter]
      }
      if let after = screen.submitAfter {
        return move(from: position(screen.selected, screen), to: after + 1) + [.enter]
      }
      return nil
    case .note(let text):
      let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !note.isEmpty else { return nil }
      switch kind {
      case .permission:
        return [.escape, .text(note), .enter]
      case .question:
        guard let index = screen.freeTextIndex else { return nil }
        return move(from: position(screen.selected, screen), to: position(index, screen)) + [.text(note), .enter]
      case .plan:
        guard let index = screen.options.firstIndex(where: { isKeepPlanning($0.label) }) else { return nil }
        return move(from: position(screen.selected, screen), to: position(index, screen)) + [.enter, .text(note), .enter]
      }
    }
  }

  /// The "No" option (⌥N).
  public static func denyNumber(_ screen: DialogScreen) -> Int? {
    screen.options.first { $0.label == "No" || $0.label.hasPrefix("No,") || $0.label.hasPrefix("No ") }?.number
  }

  /// The same dialog is still up: same question, same options (the selection may have moved).
  public static func sameDialog(_ a: DialogScreen, _ b: DialogScreen) -> Bool {
    a.question == b.question && a.labels == b.labels
  }

  public static func isSubmit(_ label: String) -> Bool {
    let lower = label.lowercased()
    return lower.hasPrefix("submit") || lower == "next"
  }

  static func isKeepPlanning(_ label: String) -> Bool {
    let lower = label.lowercased()
    return lower.contains("keep planning") || lower.contains("tell claude what to change") || label.hasPrefix("No")
  }

  /// Where an option sits when arrowing through the dialog (the unnumbered Submit row takes a stop after `submitAfter`).
  private static func position(_ index: Int, _ screen: DialogScreen) -> Int {
    guard let after = screen.submitAfter, index > after else { return index }
    return index + 1
  }

  private static func move(from: Int, to: Int) -> [PromptKey] {
    to >= from ? Array(repeating: .down, count: to - from) : Array(repeating: .up, count: from - to)
  }
}
