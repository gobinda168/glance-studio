import Testing
@testable import GlanceCore

private let style = "---\nname: Glance Humanize\nkeep-coding-instructions: true\n---\n\n# Glance Humanize\n\nLead with the outcome.\n"

@Test func bodyDropsTheFrontMatter() {
  #expect(HumanizeStyle.body(of: style) == "# Glance Humanize\n\nLead with the outcome.")
  #expect(HumanizeStyle.body(of: "Just text\n") == "Just text")
}

@Test func claudeDefaultChangesNothing() {
  let args = ChatSession.arguments(sessionID: "abc", resume: false)
  #expect(HumanizeStyle.apply(.claudeDefault, body: "B", to: args) == args)
  #expect(HumanizeStyle.apply(.humanize, body: "", to: args) == args)
}

@Test func humanizeAddsOneAppendedPrompt() {
  let args = HumanizeStyle.apply(.humanize, body: "B", to: ChatSession.arguments(sessionID: "abc", resume: false))
  #expect(args.suffix(2) == ["--append-system-prompt", "B"])
  #expect(args.filter { $0 == "--append-system-prompt" }.count == 1)
}

@Test func humanizeJoinsAnExistingAppendedPrompt() {
  let args = HumanizeStyle.apply(.humanize, body: "B", to: InlineAsk.arguments())
  #expect(args.filter { $0 == "--append-system-prompt" }.count == 1)
  let value = args[args.firstIndex(of: "--append-system-prompt")! + 1]
  #expect(value.hasPrefix(InlineAsk.rules))
  #expect(value.hasSuffix("\n\nB"))
}
