import Testing
@testable import GlanceCore

@Suite struct ProofMatcherTests {
  let setup = ProofSetup(
    environments: [
      .init(name: "Local", url: "http://localhost:3000", match: ["localhost:*", "127.0.0.1:*"]),
      .init(name: "Preview", urlScript: "x.sh", match: ["*--pr-*.web.app"]),
      .init(name: "Staging", url: "https://staging.example.com", match: ["staging.example.com"]),
    ],
    checks: [
      .init(name: "Unit", match: #"^(npm|pnpm) (run )?test\b"#, env: "Local"),
      .init(name: "E2E", match: "playwright test", envFrom: "BASE_URL"),
    ])

  @Test func fixedEnvironment() {
    #expect(ProofMatcher.check(for: "pnpm test --silent", in: setup) == ProofCheckMatch(name: "Unit", environment: "Local", exitIsReliable: true, isLastSegment: true))
    #expect(ProofMatcher.check(for: "git status", in: setup) == nil)
  }

  @Test func envFromVariableAssignment() {
    let m = ProofMatcher.check(for: "BASE_URL=https://app--pr-12-abc.web.app npx playwright test", in: setup)
    #expect(m == ProofCheckMatch(name: "E2E", environment: "Preview", exitIsReliable: true, isLastSegment: true))
  }

  @Test func envFromQuotedVariableAssignment() {
    let double = ProofMatcher.check(for: #"BASE_URL="http://localhost:3000" npx playwright test"#, in: setup)
    #expect(double == ProofCheckMatch(name: "E2E", environment: "Local", exitIsReliable: true, isLastSegment: true))
    let single = ProofMatcher.check(for: "BASE_URL='https://staging.example.com/x' npx playwright test", in: setup)
    #expect(single == ProofCheckMatch(name: "E2E", environment: "Staging", exitIsReliable: true, isLastSegment: true))
    let flag = ProofMatcher.check(for: #"npx playwright test --base-url="http://127.0.0.1:5173""#, in: setup)
    #expect(flag?.environment == "Local")
  }

  @Test func envFromFlag() {
    let m = ProofMatcher.check(for: "npx playwright test --base-url=http://localhost:3000", in: setup)
    #expect(m?.environment == "Local")
    let m2 = ProofMatcher.check(for: "npx playwright test --base_url https://staging.example.com/x", in: setup)
    #expect(m2?.environment == "Staging")
  }

  @Test func envFromMissingIsUnclassified() {
    #expect(ProofMatcher.check(for: "npx playwright test", in: setup) == ProofCheckMatch(name: "E2E", environment: nil, exitIsReliable: true, isLastSegment: true))
  }

  @Test func classifiesURLs() {
    #expect(ProofMatcher.environment(forURL: "http://127.0.0.1:5173/login", in: setup) == "Local")
    #expect(ProofMatcher.environment(forURL: "https://staging.example.com", in: setup) == "Staging")
    #expect(ProofMatcher.environment(forURL: "https://example.org", in: setup) == nil)
  }

  @Test func countsFromCommonRunners() {
    #expect(ProofMatcher.counts(in: "Tests:       2 failed, 40 passed, 42 total") == (40, 2))
    #expect(ProofMatcher.counts(in: "  12 passed (3.1s)") == (12, nil))
    #expect(ProofMatcher.counts(in: "==== 1 failed, 9 passed in 0.52s ====") == (9, 1))
    #expect(ProofMatcher.counts(in: "Executed 42 tests, with 2 failures (0 unexpected)") == (40, 2))
    #expect(ProofMatcher.counts(in: "✔ Test run with 2303 tests in 120 suites passed after 9.1 seconds.") == (2303, nil))
    #expect(ProofMatcher.counts(in: "nothing here") == (nil, nil))
  }

  @Test func exitCodeFromError() {
    #expect(ProofMatcher.exitCode(fromError: "Exit code 2\nboom") == 2)
    // Not an "Exit code N" error (interrupted, timed out, refused): unknown, never guessed.
    #expect(ProofMatcher.exitCode(fromError: "command not found") == nil)
    #expect(ProofMatcher.exitCode(fromError: "") == nil)
  }

  @Test func tailKeepsLastLines() {
    let text = (1...100).map(String.init).joined(separator: "\n")
    #expect(ProofMatcher.tail(text, lines: 3) == "98\n99\n100")
  }

  // MARK: shell-aware matching

  @Test func textInsideQuotesIsNotACheck() {
    #expect(ProofMatcher.check(for: #"git commit -m "pnpm test""#, in: setup) == nil)
    #expect(ProofMatcher.check(for: #"echo "run playwright test""#, in: setup) == nil)
    #expect(ProofMatcher.check(for: #"grep -rn "playwright test" docs/"#, in: setup) == nil)
    #expect(ProofMatcher.check(for: "echo 'pnpm test'", in: setup) == nil)
    #expect(ProofMatcher.check(for: #"git commit -m "fix \"x\"; pnpm test""#, in: setup) == nil)
  }

  @Test func heredocBodyIsNotACheck() {
    let command = "cat > notes.md <<'EOF'\nBASE_URL=http://localhost:3000 npx playwright test\npnpm test\nEOF\nls"
    #expect(ProofMatcher.check(for: command, in: setup) == nil)
    let dashed = "cat <<-EOF\n\tpnpm test\n\tEOF"
    #expect(ProofMatcher.check(for: dashed, in: setup) == nil)
    let after = "cat <<\"EOF\"\nhello\nEOF\npnpm test"
    #expect(ProofMatcher.check(for: after, in: setup)?.name == "Unit")
  }

  @Test func checkAfterOtherCommandsAndWrappers() {
    #expect(ProofMatcher.check(for: "cd app && pnpm test", in: setup)?.name == "Unit")
    #expect(ProofMatcher.check(for: "CI=1 pnpm test", in: setup)?.name == "Unit")
    #expect(ProofMatcher.check(for: "time pnpm test", in: setup)?.name == "Unit")
    #expect(ProofMatcher.check(for: "env CI=1 FOO=bar npm run test", in: setup)?.name == "Unit")
    #expect(ProofMatcher.check(for: "cd app\npnpm test", in: setup)?.name == "Unit")
  }

  @Test func envFromReadsOnlyTheMatchedSegment() {
    let m = ProofMatcher.check(
      for: "curl --base-url http://localhost:3000/health; BASE_URL=https://staging.example.com npx playwright test", in: setup)
    #expect(m?.environment == "Staging")
    let other = ProofMatcher.check(
      for: "BASE_URL=http://localhost:3000 echo hi && npx playwright test", in: setup)
    #expect(other == ProofCheckMatch(name: "E2E", environment: nil, exitIsReliable: true, isLastSegment: true))
  }

  @Test func exitIsReliableOnlyThroughAnds() {
    #expect(ProofMatcher.check(for: "pnpm test | tail -20", in: setup)?.exitIsReliable == false)
    #expect(ProofMatcher.check(for: "pnpm test; echo done", in: setup)?.exitIsReliable == false)
    #expect(ProofMatcher.check(for: "pnpm test || true", in: setup)?.exitIsReliable == false)
    #expect(ProofMatcher.check(for: "pnpm test\necho done", in: setup)?.exitIsReliable == false)
    #expect(ProofMatcher.check(for: "echo start | pnpm test", in: setup)?.exitIsReliable == false)
    #expect(ProofMatcher.check(for: "pnpm test && pnpm build", in: setup)?.exitIsReliable == true)
    #expect(ProofMatcher.check(for: "cd a && pnpm test", in: setup)?.exitIsReliable == true)
    #expect(ProofMatcher.check(for: "pnpm test\n", in: setup)?.exitIsReliable == true)
    #expect(ProofMatcher.check(for: "pnpm test;", in: setup)?.exitIsReliable == true)
  }

  @Test func lastSegmentIsTheCheckBeingTheFinalCommand() {
    #expect(ProofMatcher.check(for: "pnpm test", in: setup)?.isLastSegment == true)
    #expect(ProofMatcher.check(for: "cd a && pnpm test", in: setup)?.isLastSegment == true)
    #expect(ProofMatcher.check(for: "pnpm test\n", in: setup)?.isLastSegment == true)
    #expect(ProofMatcher.check(for: "pnpm test | tail -20", in: setup)?.isLastSegment == false)
    #expect(ProofMatcher.check(for: "pnpm test && pnpm build", in: setup)?.isLastSegment == false)
    #expect(ProofMatcher.check(for: "pnpm test; echo done", in: setup)?.isLastSegment == false)
    #expect(ProofMatcher.check(for: "echo start | pnpm test", in: setup)?.isLastSegment == true)
  }

  // MARK: pass or fail (spec §3: "Seen by Glance" never claims what was not seen)

  /// What Glance records for `command` that ended with `exit` and printed `output`: nil when it would record nothing.
  private func result(_ command: String, exit: Int?, _ output: String) -> ProofResult? {
    guard let match = ProofMatcher.check(for: command, in: setup) else { return nil }
    return ProofMatcher.result(of: match, exitCode: exit, counts: ProofMatcher.counts(in: output))
  }

  private let jestFailing = """
  FAIL src/cart.test.ts
    ● cart › totals › applies the discount

      expect(received).toBe(expected)

  Test Suites: 1 failed, 1 passed, 2 total
  Tests:       2 failed, 38 passed, 40 total
  Snapshots:   3 passed, 3 total
  Time:        4.187 s
  """
  private let jestPassing = """
  PASS src/cart.test.ts
  Test Suites: 2 passed, 2 total
  Tests:       40 passed, 40 total
  Snapshots:   3 passed, 3 total
  """
  /// `pnpm test | tail` cut the summary off: only per-file lines and a stack remain.
  private let jestNoSummary = """
    at Object.<anonymous> (src/cart.test.ts:31:5)

  PASS src/checkout.test.ts
  """

  @Test func reliableZeroExitPassed() {
    #expect(result("pnpm test", exit: 0, jestPassing) == .passed)
    #expect(result("pnpm test", exit: 0, "") == .passed) // no summary needed: the exit code is the truth
    #expect(result("cd app && pnpm test", exit: 0, jestNoSummary) == .passed)
  }

  @Test func reliableNonZeroExitOfTheLastCommandFailed() {
    #expect(result("pnpm test", exit: 1, jestFailing) == .failed)
    #expect(result("pnpm test", exit: 1, "") == .failed)
    #expect(result("cd app && pnpm test", exit: 2, jestNoSummary) == .failed)
  }

  @Test func aNonZeroExitOfALaterAndCommandDoesNotFailTheCheck() {
    // `pnpm test && pnpm build` exited 1: the build may be what failed, so the test summary decides.
    #expect(result("pnpm test && pnpm build", exit: 1, jestPassing) == .passed)
    #expect(result("pnpm test && pnpm build", exit: 1, jestFailing) == .failed)
    #expect(result("pnpm test && pnpm build", exit: 1, jestNoSummary) == nil)
    #expect(result("pnpm test && pnpm build", exit: 0, jestPassing) == .passed)
  }

  @Test func aPipeLetsTheSummaryDecide() {
    // tail exits 0 whatever the tests did.
    #expect(result("pnpm test 2>&1 | tail -20", exit: 0, jestFailing) == .failed)
    #expect(result("pnpm test 2>&1 | tail -20", exit: 0, jestPassing) == .passed)
    #expect(result("pnpm test | tail", exit: 0, jestNoSummary) == nil)
    #expect(result("pnpm test | tail", exit: 0, "") == nil)
  }

  @Test func semicolonAndOrConnectorsLetTheSummaryDecide() {
    #expect(result("pnpm test; echo done", exit: 0, jestFailing) == .failed)
    #expect(result("pnpm test; echo done", exit: 0, jestNoSummary) == nil)
    #expect(result("pnpm test || true", exit: 0, jestFailing) == .failed)
    #expect(result("pnpm test || true", exit: 0, jestPassing) == .passed)
  }

  @Test func anUnknownExitFallsBackOnTheSummaryEvenWhenTheCommandIsPlain() {
    // The failure event had no "Exit code N" (interrupted, timed out): never guessed.
    #expect(result("pnpm test", exit: nil, jestFailing) == .failed)
    #expect(result("pnpm test", exit: nil, jestPassing) == .passed)
    #expect(result("pnpm test", exit: nil, jestNoSummary) == nil)
  }

  @Test func passesWithNoFailuresCountAsPassedButZeroPassesDoNot() {
    #expect(result("pnpm test | tail", exit: 0, "Tests:       0 passed, 0 total") == nil)
    #expect(result("pnpm test | tail", exit: 0, "Tests:       0 failed, 12 passed, 12 total") == .passed)
  }

  @Test func invalidRegexIsSkipped() {
    let broken = ProofSetup(checks: [
      .init(name: "Broken", match: "(unclosed"),
      .init(name: "Unit", match: "pnpm test"),
    ])
    #expect(ProofMatcher.check(for: "pnpm test", in: broken)?.name == "Unit")
    #expect(ProofMatcher.check(for: "ls", in: broken) == nil)
  }

  // MARK: counts

  @Test func jestSummaryBeatsSnapshotsLine() {
    let jest = """
      FAIL src/app.test.ts
        ● adds › wrongly

    Test Suites: 1 failed, 5 passed, 6 total
    Tests:       2 failed, 40 passed, 42 total
    Snapshots:   3 passed, 3 total
    Time:        4.512 s
    Ran all test suites.
    """
    #expect(ProofMatcher.counts(in: jest) == (40, 2))
  }

  @Test func vitestSummary() {
    let vitest = """
     Test Files  1 failed | 3 passed (4)
          Tests  2 failed | 40 passed (42)
       Start at  10:00:00
       Duration  1.23s (transform 20ms, setup 0ms)
    """
    #expect(ProofMatcher.counts(in: vitest) == (40, 2))
  }

  @Test func pytestSummary() {
    #expect(ProofMatcher.counts(in: "FAILED tests/a.py::t - assert 0\n=========== 2 failed, 40 passed, 1 skipped in 3.10s ===========") == (40, 2))
  }

  @Test func playwrightSplitsFailedAndPassedLines() {
    let playwright = """
    Running 14 tests using 2 workers

      1) [chromium] › login.spec.ts:5:1 › logs in ──────

        Error: expect(received).toBe(expected)

      1 failed
        [chromium] › login.spec.ts:5:1 › logs in
      12 passed (3.1s)
    """
    #expect(ProofMatcher.counts(in: playwright) == (12, 1))
  }

  @Test func onlyTheTailOfHugeOutputIsScanned() {
    let filler = String(repeating: "x\n", count: 60_000)
    #expect(ProofMatcher.counts(in: "Tests: 1 failed, 1 passed, 2 total\n" + filler) == (nil, nil))
    #expect(ProofMatcher.counts(in: filler + "Tests: 1 failed, 1 passed, 2 total\n") == (1, 1))
  }
}
