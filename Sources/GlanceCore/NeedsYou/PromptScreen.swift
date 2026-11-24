import Foundation

/// One numbered entry of a Claude Code dialog ("❯ 1. Yes").
public struct PromptOption: Equatable, Sendable {
  public let number: Int
  public let label: String
  /// The indented lines under it: a question option's description, or a wrapped label's rest.
  public let note: String?
  /// Multi-select: whether its box is ticked; nil for a plain option.
  public let checked: Bool?

  public init(number: Int, label: String, note: String?, checked: Bool?) {
    self.number = number
    self.label = label
    self.note = note
    self.checked = checked
  }
}

/// A Claude Code dialog as a split shows it: the question, what it's about, and the numbered menu.
public struct DialogScreen: Equatable, Sendable {
  public let question: String?
  /// The lines between the dialog's top rule and its question ("Bash command", the command…).
  public let detail: [String]
  public let options: [PromptOption]
  /// The index (into `options`) of the row with the selection marker.
  public let selected: Int
  /// Multi-select: the index (into `options`) of the option the unnumbered "Submit" row directly follows.
  public let submitAfter: Int?
  /// `detail` reaches the dialog's top rule. False when it was cut at its line limit or the top is off screen: what it
  /// shows then starts part way through.
  public let detailIsWhole: Bool
  /// What kind of dialog this is by its own key hints (Fixtures/prompts/NOTES.md), whichever call `PromptBook` picked for
  /// it. Nil when they say nothing known: the answers' review screen has none at all.
  public let kind: PromptKind?

  public init(question: String?, detail: [String], options: [PromptOption], selected: Int, submitAfter: Int? = nil,
              detailIsWhole: Bool = false, kind: PromptKind? = nil) {
    self.question = question
    self.detail = detail
    self.options = options
    self.selected = selected
    self.submitAfter = submitAfter
    self.detailIsWhole = detailIsWhole
    self.kind = kind
  }

  public var labels: [String] { options.map(\.label) }
  public var freeTextIndex: Int? { options.firstIndex { PromptScreen.isFreeText($0.label) } }
}

/// Reads Claude Code's permission / question / plan dialogs from a split's visible text. The layout is Claude Code's
/// and undocumented: `Fixtures/prompts` holds real captures (`scripts/capture-prompt-screens.py` refreshes them).
public enum PromptScreen {
  /// A dialog's key hints; a numbered list in a reply has none of them.
  static let footers = ["Esc to cancel", "Enter to select", "Enter to confirm", "to navigate", "ctrl+g to edit in Vim"]
  static let markers: Set<Character> = ["❯", "›", ">"]
  /// Multi-select box glyphs, and whether each means ticked.
  static let checkboxes: [(String, Bool)] = [("[ ]", false), ("☐", false), ("◻", false), ("[✔]", true), ("[✓]", true), ("[x]", true),
                                             ("[X]", true), ("☒", true), ("◼", true), ("✔", true)]
  private static let row = try! NSRegularExpression(pattern: #"^\s*([❯›>])?\s*(\d{1,2})\.\s+(.+)$"#)

  public static func isFreeText(_ label: String) -> Bool {
    let lower = label.lowercased()
    return lower.hasPrefix("type something") || lower == "other" || lower.hasPrefix("other ")
  }

  public static func parse(_ text: String) -> DialogScreen? {
    let lines = text.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n")
      .map { String($0.reversed().drop { $0 == " " }.reversed()) }
    // The anchor: the last key-hint line; failing that (the review screen has none), the screen's last line if numbered.
    let footer: Int
    if let hint = lines.lastIndex(where: { line in footers.contains { line.contains($0) } }) {
      footer = hint
    } else if let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
      numbered(lines[last]) != nil {
      footer = last + 1
    } else {
      return nil
    }

    // Upwards from the footer: the numbered rows (counting down to 1) and the indented notes under each.
    var rows: [(line: Int, number: Int, label: String, marked: Bool, note: [String])] = []
    var notes: [String] = []
    var submitBelow: Int?   // the number of the row the unnumbered "Submit" row sits under
    var sawSubmit = false
    var index = footer - 1
    while index >= 0 {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let match = numbered(line) {
        if let last = rows.last, match.number != last.number - 1 { break }
        if rows.isEmpty, footer - index > 8 { return nil }
        rows.append((index, match.number, match.label, match.marked, notes.reversed()))
        if sawSubmit { submitBelow = match.number; sawSubmit = false }
        notes = []
        if match.number == 1 { break }
      } else if trimmed.isEmpty || isRule(line) {
        // spacing inside or under the menu
      } else if trimmed == "Submit", leadingSpaces(line) >= 4, !sawSubmit, submitBelow == nil {
        sawSubmit = true   // multi-select's own Submit row, not a note
      } else if leadingSpaces(line) >= 4 {
        notes.append(trimmed)
      } else if rows.isEmpty {
        notes = []   // a hint line between the menu and the footer
      } else {
        break
      }
      index -= 1
    }
    rows.reverse()
    guard rows.count >= 2, rows.first?.number == 1, rows.filter(\.marked).count == 1,
      let selected = rows.firstIndex(where: \.marked) else { return nil }

    let options = rows.map { row -> PromptOption in
      let (label, checked) = box(row.label)
      return PromptOption(number: row.number, label: label, note: row.note.isEmpty ? nil : row.note.joined(separator: " "),
                          checked: checked)
    }
    // The question: the nearest text above option 1; the detail: the text above it, up to the dialog's rule.
    var above = rows[0].line - 1
    while above >= 0, lines[above].trimmingCharacters(in: .whitespaces).isEmpty { above -= 1 }
    let question = above >= 0 && !isRule(lines[above]) ? lines[above].trimmingCharacters(in: .whitespaces) : nil
    var detail: [String] = []
    var cursor = above - 1
    // A permission's command or diff sits between two `╌` rules: a solid rule met inside them is its text, not the top.
    var framed = 0
    while cursor >= 0, !isSolidRule(lines[cursor]), detail.count < 12 {
      let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty, !isRule(lines[cursor]) { detail.append(trimmed) }
      if isRule(lines[cursor]), trimmed.allSatisfy({ $0 == "╌" }) { framed += 1 }
      cursor -= 1
    }
    return DialogScreen(question: question, detail: detail.reversed(), options: options, selected: selected,
                        submitAfter: submitBelow.flatMap { number in rows.firstIndex { $0.number == number } },
                        detailIsWhole: cursor >= 0 && isSolidRule(lines[cursor]) && framed.isMultiple(of: 2),
                        kind: footer < lines.count ? kind(hints: lines[footer]) : nil)
  }

  private static func kind(hints: String) -> PromptKind? {
    if hints.contains("ctrl+g to edit in Vim") { return .plan }
    if hints.contains("Enter to select") || hints.contains("to navigate") { return .question }
    if hints.contains("Esc to cancel") { return .permission }
    return nil
  }

  /// Claude Code is at its own input line: no dialog, and the last two rules on screen frame a line at its `❯` prompt
  /// (Fixtures/prompts/idle.txt, working.txt). It catches what `parse` can't, a picker or a screen with no numbered menu,
  /// by asking for what a reply needs instead of looking for each thing that could be in the way. It proves a frame is on
  /// screen, not that a live Claude is reading it: `inputBox`'s text does that.
  public static func atInput(_ text: String) -> Bool { inputBox(text) != nil }

  /// What's on Claude Code's input line, its prompt mark removed (more than one line when wrapped); nil when `atInput` is false.
  public static func inputBox(_ text: String) -> [String]? {
    guard parse(text) == nil else { return nil }
    let lines = text.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n")
    let rules = lines.indices.filter { isInputRule(lines[$0]) }
    guard rules.count >= 2, let bottom = rules.last else { return nil }
    let top = rules[rules.count - 2]
    guard top + 1 < bottom else { return nil }
    let first = lines[top + 1].trimmingCharacters(in: .whitespaces)
    guard let mark = first.first, markers.contains(mark),
      !lines[top...].contains(where: { line in footers.contains { line.contains($0) } }) else { return nil }
    return [String(first.dropFirst())] + lines[(top + 2)..<bottom]
  }

  private static func numbered(_ line: String) -> (number: Int, label: String, marked: Bool)? {
    let range = NSRange(line.startIndex..., in: line)
    guard let match = row.firstMatch(in: line, range: range),
      let numberRange = Range(match.range(at: 2), in: line), let number = Int(line[numberRange]),
      let labelRange = Range(match.range(at: 3), in: line) else { return nil }
    let marked = Range(match.range(at: 1), in: line).map { markers.contains(line[$0].first ?? " ") } ?? false
    return (number, String(line[labelRange]).trimmingCharacters(in: .whitespaces), marked)
  }

  private static func box(_ label: String) -> (String, Bool?) {
    for (glyph, ticked) in checkboxes where label.hasPrefix(glyph) {
      return (String(label.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces), ticked)
    }
    return (label, nil)
  }

  private static func isRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 10 && trimmed.allSatisfy { "─━╌═-".contains($0) }
  }

  /// A rule of the input box. Not all of it need be rule: Claude Code can write a label into it.
  private static func isInputRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 20 && Double(trimmed.filter { $0 == "─" }.count) >= Double(trimmed.count) * 0.8
  }

  private static func isSolidRule(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count >= 10 && trimmed.allSatisfy { "─━═".contains($0) }
  }

  private static func leadingSpaces(_ line: String) -> Int { line.prefix { $0 == " " }.count }
}
