import Foundation

/// An ask step's question as the user sees it, rendered (spec 2026-10-10-agents-design.md): the run waits for the
/// answer, which becomes the step's output.
public struct AutomationQuestion: Codable, Equatable, Sendable {
  public var step: String
  public var question: String
  public var body: String?
  public var choices: [String]
  /// A typed or spoken answer outside the choices is allowed.
  public var allowsText: Bool

  public init(step: String, question: String, body: String? = nil, choices: [String], allowsText: Bool) {
    self.step = step
    self.question = question
    self.body = body
    self.choices = choices
    self.allowsText = allowsText
  }
}

/// How the user answered: the words, which choice (1-based) when it was one, and how.
public struct AutomationAnswer: Equatable, Sendable {
  public enum Via: String, Codable, Sendable { case click, text, voice }

  public var answer: String
  public var choice: Int?
  public var via: Via

  public init(answer: String, choice: Int? = nil, via: Via) {
    self.answer = answer
    self.choice = choice
    self.via = via
  }

  /// A choice by its index (0-based) in `question`, or nil when there's no such choice.
  public static func choice(_ index: Int, of question: AutomationQuestion, via: Via) -> AutomationAnswer? {
    guard question.choices.indices.contains(index) else { return nil }
    return AutomationAnswer(answer: question.choices[index], choice: index + 1, via: via)
  }

  /// Words the user typed or said: the choice they match (same text, any case), else free text when the question
  /// takes it; nil when it doesn't.
  public static func text(_ words: String, for question: AutomationQuestion, via: Via) -> AutomationAnswer? {
    let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let index = question.choices.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
      return AutomationAnswer(answer: question.choices[index], choice: index + 1, via: via)
    }
    return question.allowsText ? AutomationAnswer(answer: trimmed, via: via) : nil
  }

  /// The step's JSON output: {"answer": …, "choice": 1 | null, "via": …}.
  public var json: AutomationValue {
    .object(["answer": .string(answer), "choice": choice.map { .number(Double($0)) } ?? .null,
             "via": .string(via.rawValue)])
  }
}

extension AutomationAsk {
  /// Renders the question, body and choices. Choices given as one template must render to a JSON list of strings
  /// (an empty render is no choices); at most `maxChoices`, none empty; at least one unless `text`.
  public func render(step: String, _ context: AutomationTemplateContext) throws(AutomationTemplateError)
    -> AutomationQuestion {
    let question = try AutomationTemplate.render(self.question, context)
    let body = try body.map { (template: String) throws(AutomationTemplateError) -> String in
      try AutomationTemplate.render(template, context)
    }
    var rendered: [String] = []
    switch choices {
    case .list(let templates):
      for template in templates { rendered.append(try AutomationTemplate.render(template, context)) }
    case .template(let template):
      let text = try AutomationTemplate.render(template, context).trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        guard case .array(let items) = AutomationValue.decode(Data(text.utf8)) ?? .null else {
          throw .invalid("choices should render to a JSON list of strings, got: \(Self.clip(text))")
        }
        for item in items {
          guard case .string(let choice) = item else {
            throw .invalid("choices should render to a JSON list of strings, got: \(Self.clip(text))")
          }
          rendered.append(choice)
        }
      }
    case nil:
      break
    }
    rendered = rendered.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    if rendered.contains(where: \.isEmpty) { throw .invalid("a choice rendered empty") }
    if rendered.count > Self.maxChoices { throw .invalid("more than \(Self.maxChoices) choices") }
    if rendered.isEmpty, !allowsText { throw .invalid("no choices to offer, and the question takes no typed answer") }
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { throw .invalid("the question rendered empty") }
    let shownBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
    return AutomationQuestion(step: step, question: trimmed, body: shownBody?.isEmpty == false ? shownBody : nil,
                              choices: rendered, allowsText: allowsText)
  }

  /// Its templates read an earlier step or the trigger (a dry run only has placeholders for those).
  public var readsRunData: Bool {
    var templates = [question] + [body].compactMap { $0 }
    switch choices {
    case .list(let list): templates += list
    case .template(let template): templates.append(template)
    case nil: break
    }
    return templates.contains { template in
      ((try? AutomationTemplate.references(in: template)) ?? []).contains { reference in
        switch reference {
        case .trigger, .stepText, .stepJSON: true
        default: false
        }
      }
    }
  }

  static func clip(_ text: String) -> String { text.count > 200 ? String(text.prefix(200)) + "…" : text }
}
