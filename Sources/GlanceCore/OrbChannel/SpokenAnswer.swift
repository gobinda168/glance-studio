import Foundation

/// Turns what the user said into a card's answer (spec "Voice"): a choice by its name, its number, or yes/no between
/// two; otherwise the words themselves when the card takes text. Permission cards take only a short, clear allow or
/// deny: anything mixed or longer is unclear, and the card keeps waiting.
public enum SpokenAnswer {
  public enum Match: Equatable, Sendable { case choice(Int), text(String), allow, deny, unclear }

  public static func match(_ spoken: String, choices: [String], allowText: Bool) -> Match {
    let original = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
    let said = stripFillers(normalize(spoken))
    guard !said.isEmpty else { return .unclear }
    let names = choices.map { stripFillers(normalize($0)) }
    if let exact = names.firstIndex(of: said) { return .choice(exact) }
    if let index = ordinal(said, count: choices.count) { return .choice(index) }
    if choices.count == 2 {
      if yes.contains(said) { return .choice(0) }
      if no.contains(said) { return .choice(1) }
    }
    // A name inside a longer phrase picks it only when exactly one is named, nothing negates or hedges it ("don't
    // ship it", "maybe revert"), and the name is not itself a bare yes/no ("no idea", "no problem" are not a No).
    let padded = " \(said) "
    let named = names.indices.filter { index in
      let name = names[index]
      guard !name.isEmpty, !yes.contains(name), !no.contains(name),
            let range = padded.range(of: " \(name) ") else { return false }
      return !padded[..<range.lowerBound].split(separator: " ").contains { blocksChoice(String($0)) }
    }
    if named.count == 1, said.split(separator: " ").count <= names[named[0]].split(separator: " ").count + 2 {
      return .choice(named[0])
    }
    return allowText ? .text(original) : .unclear
  }

  public static func permission(_ spoken: String) -> Match {
    let said = normalize(spoken)
    let words = said.split(separator: " ").map(String.init)
    guard !words.isEmpty, words.count <= 4 else { return .unclear }
    // "no problem" / "no worries" mean "fine", not "no": never a deny.
    guard !reassurances.contains(where: { said.contains($0) }) else { return .unclear }
    let padded = " \(said) "
    let allows = said == "sure" || allowWords.contains { padded.contains(" \($0) ") }
    let denies = denyWords.contains { padded.contains(" \($0) ") }
    // A negated or hedged allow ("not sure", "never allow", "are you sure", "maybe") is no allow at all.
    let hedged = padded.contains(" are you ") || words.contains { isNegator($0) || hedges.contains($0) }
    if allows && hedged { return .unclear }
    switch (allows, denies) {
    case (true, false): return .allow
    case (false, true): return .deny
    default: return .unclear
    }
  }

  // MARK: - Words

  static let yes: Set = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "correct", "right"]
  static let no: Set = ["no", "nope", "nah"]
  /// "sure" is an allow only as the whole utterance ("not sure", "are you sure" are not).
  static let allowWords = ["allow", "yes", "yeah", "yep", "approve", "go ahead", "do it", "okay", "ok"]
  static let denyWords = ["deny", "no", "nope", "dont", "don't", "do not", "stop", "reject", "cancel"]
  static let fillers = ["um", "uh", "er", "so", "well", "okay so", "ok so", "lets", "let's", "go with", "i'd say",
                        "id say", "i think", "please"]

  static let reassurances = ["no problem", "no worries", "not a problem"]
  static let hedges: Set = ["maybe", "perhaps", "wait", "hold"]
  static let negators: Set = ["not", "never", "cannot", "dont", "cant", "wont", "isnt", "arent", "doesnt", "didnt",
                              "wouldnt", "shouldnt", "couldnt"]

  static func isNegator(_ word: String) -> Bool { negators.contains(word) || word.hasSuffix("n't") }

  /// Words that, ahead of a choice's name, mean the user did not pick it.
  static func blocksChoice(_ word: String) -> Bool {
    isNegator(word) || hedges.contains(word) || no.contains(word)
  }

  /// Lower case, letters/digits/apostrophes/spaces only, single spaces.
  static func normalize(_ text: String) -> String {
    let kept = text.lowercased().replacingOccurrences(of: "’", with: "'").map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
    return String(kept).split(separator: " ").joined(separator: " ")
  }

  static func stripFillers(_ text: String) -> String {
    var words = text
    var changed = true
    while changed {
      changed = false
      for filler in fillers where words == filler || words.hasPrefix(filler + " ") {
        words = String(words.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
        changed = true
      }
    }
    for suffix in [" please", " thanks", " thank you"] where words.hasSuffix(suffix) {
      words = String(words.dropLast(suffix.count))
    }
    return words
  }

  /// "the second one", "option two", "2", "last" → an index within `count`.
  static func ordinal(_ said: String, count: Int) -> Int? {
    if said == "to" || said == "too" { return count > 1 ? 1 : nil }  // "two", misheard; only as the whole answer
    var words = said.split(separator: " ").map(String.init)
    let skippable: Set = ["the", "option", "choice", "number", "one"]
    while words.count > 1, let index = words.firstIndex(where: skippable.contains) { words.remove(at: index) }
    guard words.count == 1, let word = words.first else { return nil }
    let table: [String: Int] = ["1": 0, "first": 0, "one": 0, "2": 1, "second": 1, "two": 1, "3": 2, "third": 2,
                                "three": 2, "4": 3, "fourth": 3, "four": 3, "5": 4, "fifth": 4, "five": 4,
                                "6": 5, "sixth": 5, "six": 5]
    if word == "last" { return count > 0 ? count - 1 : nil }
    guard let index = table[word], index < count else { return nil }
    return index
  }
}
