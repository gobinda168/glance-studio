import Foundation
import Testing
@testable import GlanceCore

private func comment(_ author: String, _ body: String = "ok", bot: Bool = false, pending: Bool = false)
  -> ReviewThreads.Comment {
  .init(id: "\(author)-\(body)", databaseID: 1, author: author, isBot: bot, body: body, createdAt: nil,
        reviewState: pending ? .pending : .commented, isPending: pending)
}

private func thread(_ id: String, _ comments: [ReviewThreads.Comment], resolved: Bool = false, path: String = "a.swift",
                    line: Int? = 3, fileLevel: Bool = false) -> ReviewThreads.Thread {
  .init(id: id, isResolved: resolved, isOutdated: false, path: path, line: line, startLine: nil, side: .right,
        resolvedBy: resolved ? "gobinda168" : nil, comments: comments, isFileLevel: fileLevel)
}

// Three pull requests, as the canvas's inbox has them:
// - #51 is the viewer's: two blocking threads from Claude Code Review (one answered), a nit, and a resolved thread.
// - #50 is mira-k's: the viewer asked something, and devon answered.
// - #48 is mira-k's too, with only a pending comment of the viewer's.
private let viewer = "gobinda168"
private let mine = PullRequests.PullRequest(number: 51, title: "Release: build", author: "gobinda168",
                                            head: "feat/release")
private let theirs = PullRequests.PullRequest(number: 50, title: "Sparkle updates", author: "mira-k", head: "sparkle")
private let quiet = PullRequests.PullRequest(number: 48, title: "Changes view", author: "mira-k", head: "changes")
private let threads: [Int: [ReviewThreads.Thread]] = [
  51: [thread("nit", [comment("claude", "Nit: say macOS asks once.", bot: true)]),
       thread("rollback", [comment("claude", "🔴 Important: roll back.", bot: true), comment("gobinda168")]),
       thread("order", [comment("claude", "**Blocking:** the order.", bot: true)]),
       thread("done", [comment("devon", "Blocking: quote it.")], resolved: true)],
  50: [thread("badge", [comment("gobinda168", "Badge?"), comment("devon", "Can the badge clear on dismiss?")])],
  48: [thread("draft", [comment("gobinda168", "Blocking: draft", pending: true)])],
]
/// Waiting on you, then Yours, as the side bar lists them; a pull request listed twice counts once.
private let open = [theirs, mine, quiet, mine]

@Test func theFiltersAreTheCanvasRows() {
  #expect(ReviewInbox.Filter.allCases.map(\.title)
    == ["Unresolved", "Blocking", "Waiting on you", "From people", "From review bots", "Resolved"])
}

@Test func eachFilterCountsItsThreads() {
  // On the viewer's own #51, every thread someone else spoke last in waits on them: the nit and "order".
  #expect(ReviewInbox.counts(open, threads: threads, viewer: viewer) == [
    .unresolved: 4, .blocking: 2, .waitingOnYou: 3, .fromPeople: 1, .fromBots: 3, .resolved: 1,
  ])
}

@Test func aThreadsPillIsBlockingOptionalOrWaitingOnYou() {
  let card = threads[51]!
  #expect(ReviewInbox.label(card[1], viewer: viewer, author: "gobinda168") == .blocking)
  #expect(ReviewInbox.label(card[2], viewer: viewer, author: "gobinda168") == .blocking)
  #expect(ReviewInbox.label(card[0], viewer: viewer, author: "gobinda168") == .optional) // a nit stays one, unanswered
  #expect(ReviewInbox.label(threads[50]![0], viewer: viewer, author: "mira-k") == .waitingOnYou)
  #expect(ReviewInbox.label(card[3], viewer: viewer, author: "gobinda168") == nil) // resolved
  let answered = thread("plain", [comment("devon", "Why this name?"), comment("gobinda168", "Because.")])
  #expect(ReviewInbox.label(answered, viewer: viewer, author: "gobinda168") == nil)
}

@Test func threadsGroupByPullRequestBlockingFirst() {
  let groups = ReviewInbox.groups(open, threads: threads, filter: .unresolved, viewer: viewer)
  #expect(groups.map(\.pullRequest.number) == [50, 51]) // #48's only thread is a pending draft
  #expect(groups[1].threads.map(\.id) == ["rollback", "order", "nit"])
  #expect(ReviewInbox.groups(open, threads: threads, filter: .resolved, viewer: viewer).map { $0.threads.map(\.id) }
    == [["done"]])
  #expect(ReviewInbox.groups(open, threads: threads, filter: .waitingOnYou, viewer: viewer)
    .flatMap { $0.threads.map(\.id) } == ["badge", "order", "nit"])
}

@Test func theHeadingCountsThreadsPullRequestsAndBlockers() {
  let groups = ReviewInbox.groups(open, threads: threads, filter: .unresolved, viewer: viewer)
  #expect(ReviewInbox.summaryLine(groups) == "4 threads across 2 pull requests · 2 block merging")
  #expect(ReviewInbox.summaryLine(ReviewInbox.groups(open, threads: threads, filter: .resolved, viewer: viewer))
    == "1 thread in 1 pull request")
  #expect(ReviewInbox.summaryLine([ReviewInbox.Group(pullRequest: mine, threads: [threads[51]![1]])])
    == "1 thread in 1 pull request · 1 blocks merging")
  #expect(ReviewInbox.summaryLine([]) == "No threads")
  #expect(ReviewInbox.statusLine(ReviewInbox.counts(open, threads: threads, viewer: viewer))
    == "4 unresolved · 2 blocking")
  #expect(ReviewInbox.statusLine([.unresolved: 3, .blocking: 0]) == "3 unresolved")
  #expect(ReviewInbox.statusLine([:]) == "No unresolved threads")
}

@Test func aThreadSaysWhereItIsAndWhoStartedIt() {
  #expect(ReviewInbox.place(threads[51]![0]) == "a.swift:3")
  #expect(ReviewInbox.place(thread("f", [comment("devon")], path: "README.md", line: nil, fileLevel: true))
    == "README.md")
  #expect(ReviewInbox.byline(threads[51]![0]) == "claude")
  #expect(ReviewInbox.byline(threads[51]![1]) == "claude · 1 reply")
  #expect(ReviewInbox.byline(thread("t", [comment("devon"), comment("a"), comment("b")])) == "devon · 2 replies")
  #expect(ReviewInbox.wontFixReply == "Won't fix.")
}

@Test func fixAllBlockingFixesTheCheckedOutPullRequestOrOffersTheOneWithTheMost() {
  let blocking = [threads[51]![1], threads[51]![2]]
  // #51 is checked out: its two blocking threads go to Claude.
  #expect(ReviewInbox.fixAll(open, threads: threads, branch: "feat/release") == .fix(mine, blocking))
  // Another branch: check out #51, which has the most.
  let more = threads.merging([50: [thread("x", [comment("devon", "Blocking: x")])]]) { $1 }
  #expect(ReviewInbox.fixAll(open, threads: more, branch: "main") == .checkOut(mine, blocking))
  // A tie goes to the first listed.
  let tie: [Int: [ReviewThreads.Thread]] = [50: [thread("x", [comment("devon", "Blocking: x")])],
                                            51: [thread("y", [comment("devon", "Blocking: y")])]]
  #expect(ReviewInbox.fixAll(open, threads: tie, branch: nil) == .checkOut(theirs, tie[50]!))
  // Nothing blocks, a pending draft aside: nothing to fix.
  #expect(ReviewInbox.fixAll(open, threads: [50: threads[50]!, 48: threads[48]!], branch: "sparkle") == .nothing)
}
