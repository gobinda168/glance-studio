import Foundation
import GlanceCore
import Testing
@testable import GlanceKit

// Make explainer's Claude step with an injected runner: no real `claude` is started here.

@MainActor
private func ask(events: [ClaudeRunner.Event], log: inout [String]) async -> Error? {
  var lines: [String] = []
  let session = ExplainerClaude.Session()
  let runner: ExplainerClaude.Runner = { _, _, _, _, onEvent in
    for event in events { onEvent(event) }
    return ClaudeOneShot.Run()
  }
  var failure: Error?
  do {
    try await ExplainerClaude.ask(arguments: ["-p"], prompt: "p", folder: "/tmp", session: session, runner: runner) { lines.append($0) }
  } catch {
    failure = error
  }
  log = lines
  return failure
}

@MainActor @Test func aFailedWriteKeepsWhatClaudeSaid() async {
  var log: [String] = []
  let failure = await ask(events: [.text("I couldn't write the scenes "), .tool("Using Skill…"),
                                   .text("because the folder is read only."), .failed("Claude stopped unexpectedly.")], log: &log)
  let said = log.joined(separator: "\n")
  #expect(said.contains("Using Skill…"))
  #expect(said.contains("Claude said:") && said.contains("I couldn't write the scenes because the folder is read only."))
  let error = failure as? ExplainerFailure
  #expect(error?.step == .writing && error?.message == "Claude stopped unexpectedly.")
}

@MainActor @Test func aFinishedWriteKeepsTheFinalAnswerToo() async {
  var log: [String] = []
  let failure = await ask(events: [.text("working"), .done("Both files are written.")], log: &log)
  #expect(failure == nil)
  #expect(log.joined(separator: "\n").contains("Both files are written."))
}

@MainActor @Test func whatClaudeSaidIsCappedAtItsTail() async {
  var log: [String] = []
  let long = String(repeating: "x", count: 20_000) + "THE END"
  _ = await ask(events: [.text(long), .failed("no")], log: &log)
  let said = log.joined(separator: "\n")
  #expect(said.contains("THE END"))
  #expect(said.count < 6_000)
}

@MainActor @Test func claudeSayingNothingAddsNoEmptyBlock() async {
  var log: [String] = []
  _ = await ask(events: [.failed("Claude took too long.")], log: &log)
  #expect(!log.joined(separator: "\n").contains("Claude said:"))
}

@MainActor @Test func cancelEndsTheStepWithoutAnAnswer() async {
  let session = ExplainerClaude.Session()
  let runner: ExplainerClaude.Runner = { _, _, _, _, _ in ClaudeOneShot.Run() }   // never answers
  Task { try? await Task.sleep(nanoseconds: 100_000_000); session.cancel() }
  do {
    try await ExplainerClaude.ask(arguments: [], prompt: "p", folder: "/tmp", session: session, runner: runner) { _ in }
    Issue.record("should have been cancelled")
  } catch {
    #expect(error is CancellationError)
  }
}
