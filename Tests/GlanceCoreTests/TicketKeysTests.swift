import Testing
@testable import GlanceCore

private let abc = Ticket(tracker: "jira", key: "ABC-123", title: "Login", status: "To Do", statusCategory: .todo,
                         transitions: [], group: .assigned)
private let issue = Ticket(tracker: "github", key: "acme/api#88", title: "Bug", status: "open", statusCategory: .todo,
                           repository: "acme/api", transitions: [], group: .assigned)

@Test func keysMatchInSubjectsAndBranchNames() {
  #expect(TicketKeys.mentioned(in: "ABC-123: fix login", tickets: [abc], repository: nil) == [abc])
  #expect(TicketKeys.mentioned(in: "feature/abc-123-login", tickets: [abc], repository: nil) == [abc])
  #expect(TicketKeys.mentioned(in: "Closes [ABC-123]", tickets: [abc], repository: nil) == [abc])
}

@Test func lookAlikeKeysDontMatch() {
  for text in ["Fix UTF-8 and ISO-8601 parsing", "abc-1234 is different", "XABC-123", "ABC-12", "nothing"] {
    #expect(TicketKeys.mentioned(in: text, tickets: [abc], repository: nil).isEmpty, "\(text)")
  }
}

@Test func gitHubIssueNumbersOnlyMatchInTheirRepository() {
  #expect(TicketKeys.mentioned(in: "fixes #88", tickets: [issue], repository: "acme/api") == [issue])
  #expect(TicketKeys.mentioned(in: "fixes #88", tickets: [issue], repository: "acme/web").isEmpty)
  #expect(TicketKeys.mentioned(in: "fixes #88", tickets: [issue], repository: nil).isEmpty)
  #expect(TicketKeys.mentioned(in: "see #880", tickets: [issue], repository: "acme/api").isEmpty)
}
