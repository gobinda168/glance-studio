import Foundation
import Testing
@testable import GlanceCore

@Test func replayCountsWhatTheGhostWouldHaveGotRight() {
  var records: [CommandRecord] = []
  for i in 0..<5 {
    let base = Date(timeIntervalSince1970: 1_000_000 + Double(i) * 600)
    records.append(CommandRecord(command: "git add -A", folder: "/p", start: base, duration: 1, exitCode: 0, tab: "T",
                                 gitRoot: nil, branch: nil, imported: false))
    records.append(CommandRecord(command: "git commit -m \"step \(i)\"", folder: "/p", start: base.addingTimeInterval(30),
                                 duration: 1, exitCode: 0, tab: "T", gitRoot: nil, branch: nil, imported: false))
  }
  let report = SuggestionReplay.run(records)
  #expect(report.runs == 10 && report.recorded == 10)
  // Once a commit has been followed by an add (indexed in round 1), "git add -A" is right after one character: rounds
  // 2, 3 and 4. A commit's ghost is an older message, offered but not right.
  #expect(report.ghost[1]?.right == 3)
  #expect((report.ghost[1]?.offered ?? 0) > 3)
  // After four adds were followed by a commit, the next command is predicted (3 times seen first, by round 4).
  #expect(report.next.offered >= 1 && report.next.right >= 1)
  let text = SuggestionReplay.describe(report)
  #expect(text.contains("Replayed 10 commands") && text.contains("Next command"))
}
