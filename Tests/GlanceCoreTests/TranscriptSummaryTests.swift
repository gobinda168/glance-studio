import Foundation
import Testing
@testable import GlanceCore

private func record(bytes: Int = 100, head: String = "h", version: Int = TranscriptSummaryPrompt.version) -> SummaryRecord {
  SummaryRecord(sessionID: "s", transcriptPath: "/t/s.jsonl", cwd: "/a", title: "t", coveredBytes: bytes,
                coveredTurns: 2, headHash: head, promptVersion: version, summary: "S", updatedAt: Date(timeIntervalSince1970: 0))
}

@Test func freshnessFollowsTheFile() {
  let v = TranscriptSummaryPrompt.version
  #expect(SummaryCache.freshness(record(), fileSize: 100, headHash: "h", promptVersion: v) == .fresh)
  #expect(SummaryCache.freshness(record(), fileSize: 150, headHash: "h", promptVersion: v) == .stale)
  #expect(SummaryCache.freshness(record(), fileSize: 90, headHash: "h", promptVersion: v) == .rebuild)
  #expect(SummaryCache.freshness(record(), fileSize: 150, headHash: "other", promptVersion: v) == .rebuild)
  #expect(SummaryCache.freshness(record(version: 0), fileSize: 100, headHash: "h", promptVersion: v) == .rebuild)
}

@Test func headHashIsStable() {
  #expect(SummaryCache.headHash(Data("abc".utf8)) == SummaryCache.headHash(Data("abc".utf8)))
  #expect(SummaryCache.headHash(Data("abc".utf8)) != SummaryCache.headHash(Data("abd".utf8)))
}

@Test func manualOnlyCallsWhenAsked() {
  #expect(SummaryPolicy.step(mode: .manual, trigger: .opened, freshness: nil) == .none)
  #expect(SummaryPolicy.step(mode: .manual, trigger: .turnFinished, freshness: .stale) == .none)
  #expect(SummaryPolicy.step(mode: .manual, trigger: .userAsked, freshness: nil) == .generate(incremental: false))
  #expect(SummaryPolicy.step(mode: .manual, trigger: .userAsked, freshness: .stale) == .generate(incremental: true))
  #expect(SummaryPolicy.step(mode: .manual, trigger: .userAsked, freshness: .fresh) == .show)
  #expect(SummaryPolicy.step(mode: .manual, trigger: .opened, freshness: .stale) == .show)
}

@Test func oncePerSessionGeneratesOnFirstOpenThenReuses() {
  #expect(SummaryPolicy.step(mode: .oncePerSession, trigger: .opened, freshness: nil) == .generate(incremental: false))
  #expect(SummaryPolicy.step(mode: .oncePerSession, trigger: .opened, freshness: .stale) == .show)
  #expect(SummaryPolicy.step(mode: .oncePerSession, trigger: .turnFinished, freshness: .stale) == .none)
}

@Test func alwaysUpdatesAfterTurns() {
  #expect(SummaryPolicy.step(mode: .always, trigger: .turnFinished, freshness: nil) == .generate(incremental: false))
  #expect(SummaryPolicy.step(mode: .always, trigger: .turnFinished, freshness: .stale) == .generate(incremental: true))
  #expect(SummaryPolicy.step(mode: .always, trigger: .turnFinished, freshness: .rebuild) == .generate(incremental: false))
  #expect(SummaryPolicy.step(mode: .always, trigger: .turnFinished, freshness: .fresh) == .none)
  #expect(SummaryPolicy.step(mode: .always, trigger: .opened, freshness: .stale) == .show)
}

@Test func aRefreshDuringARunRerunsOnce() {
  var jobs = SummaryJobs()
  let first = jobs.start("s")
  let duringRun = jobs.start("s")      // queued behind the run
  let askedAgain = jobs.start("s")     // still one rerun, not two
  let other = jobs.start("other")      // other sessions run alongside
  #expect(first && !duringRun && !askedAgain && other)
  let rerun = jobs.finish("s")         // the queued rerun starts now
  #expect(rerun)
  #expect(jobs.isRunning("s"))
  let again = jobs.finish("s")
  #expect(!again)
  #expect(!jobs.isRunning("s"))
}

@Test func theSummarizerHasNoToolsAndOneAppendedPrompt() {
  let args = TranscriptSummaryPrompt.arguments(style: "STYLE")
  #expect(args.contains("--no-session-persistence"))
  #expect(args[args.firstIndex(of: "--tools")! + 1] == "")
  #expect(args[args.firstIndex(of: "--model")! + 1] == "claude-haiku-4-5")
  #expect(args.filter { $0 == "--append-system-prompt" }.count == 1)
  #expect(args.last!.hasPrefix("STYLE\n\n"))
  #expect(args.last!.hasSuffix(TranscriptSummaryPrompt.outline))
  #expect(TranscriptSummaryPrompt.revisePrompt(previous: "OLD", digest: "NEW").contains("<summary>\nOLD\n</summary>"))
}
