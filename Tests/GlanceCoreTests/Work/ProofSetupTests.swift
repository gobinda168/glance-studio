import Foundation
import Testing
@testable import GlanceCore

@Suite struct ProofSetupTests {
  static let good = """
  {
    "version": 1,
    "environments": [
      { "name": "Local", "url": "http://localhost:3000", "match": ["localhost:*", "127.0.0.1:*"] },
      { "name": "Preview", "urlScript": ".glance/scripts/preview-url.sh", "match": ["*--pr-*.web.app"] }
    ],
    "checks": [
      { "name": "Unit", "match": "^(npm|pnpm) (run )?test\\\\b", "env": "Local" },
      { "name": "E2E", "match": "playwright test", "envFrom": "BASE_URL" }
    ],
    "required": ["Unit@Local", "E2E@Preview"],
    "sections": ["Migrations"]
  }
  """

  @Test func parsesGoodSetup() {
    guard case .valid(let setup, let root) = ProofSetupFile.parse(Self.good, root: "/r") else { Issue.record("not valid"); return }
    #expect(root == "/r")
    #expect(setup.environments.map(\.name) == ["Local", "Preview"])
    #expect(setup.checks[1].envFrom == "BASE_URL")
    #expect(setup.required == ["Unit@Local", "E2E@Preview"])
    #expect(setup.sections == ["Migrations"])
  }

  @Test func invalidJSONReportsLine() {
    let text = "{\n  \"version\": 1,\n  \"environments\": [,]\n}"
    guard case .invalid(let issues, _) = ProofSetupFile.parse(text, root: "/r") else { Issue.record("expected invalid"); return }
    #expect(issues.first?.line == 3)
  }

  @Test func unknownEnvironmentNamesTheLine() {
    let text = Self.good.replacingOccurrences(of: "\"env\": \"Local\"", with: "\"env\": \"Locl\"")
    guard case .invalid(let issues, _) = ProofSetupFile.parse(text, root: "/r") else { Issue.record("expected invalid"); return }
    #expect(issues.contains { $0.message == "check Unit names environment Locl, which isn't defined." && $0.line == 8 })
  }

  @Test func badRegexAndRequiredAreReported() {
    let text = Self.good
      .replacingOccurrences(of: "\"playwright test\"", with: "\"playwright (test\"")
      .replacingOccurrences(of: "\"E2E@Preview\"", with: "\"E2E@Staging\"")
    guard case .invalid(let issues, _) = ProofSetupFile.parse(text, root: "/r") else { Issue.record("expected invalid"); return }
    #expect(issues.contains { $0.message.hasPrefix("check E2E's match isn't a valid regular expression") })
    #expect(issues.contains { $0.message == "required E2E@Staging names environment Staging, which isn't defined." })
  }

  @Test func environmentNeedsURLOrScriptAndCheckNeedsEnv() {
    let text = """
    { "version": 1, "environments": [ { "name": "Local" } ], "checks": [ { "name": "Unit", "match": "test" } ] }
    """
    guard case .invalid(let issues, _) = ProofSetupFile.parse(text, root: "/r") else { Issue.record("expected invalid"); return }
    #expect(issues.contains { $0.message == "environment Local needs url or urlScript." })
    #expect(issues.contains { $0.message == "check Unit needs env or envFrom." })
  }

  @Test func wrongVersionIsInvalid() {
    guard case .invalid(let issues, _) = ProofSetupFile.parse(#"{"version": 2}"#, root: "/r") else { Issue.record("expected invalid"); return }
    #expect(issues.first?.message == "version must be 1.")
  }

  @Test func findsRootWalkingUpAndStopsAtGit() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let repo = base.appendingPathComponent("repo"), deep = repo.appendingPathComponent("a/b")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    #expect(ProofSetupFile.load(cwd: deep.path) == .missing)
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".glance"), withIntermediateDirectories: true)
    try Self.good.write(to: repo.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    #expect(ProofSetupFile.root(from: deep.path) == repo.path)
    #expect(ProofSetupFile.load(cwd: deep.path).setup?.checks.count == 2)
  }

  // MARK: Line numbers. The panel shows them, so each issue must land on its own entry.

  private func issues(_ text: String) -> [ProofSetupIssue] {
    guard case .invalid(let issues, _) = ProofSetupFile.parse(text, root: "/r") else { Issue.record("expected invalid"); return [] }
    return issues
  }

  @Test func repeatedReferencesReportTheirOwnLines() {
    let text = """
    {
      "version": 1,
      "environments": [
        { "name": "Local", "url": "http://localhost:3000" },
        { "name": "Local", "url": "http://localhost:3001" }
      ],
      "checks": [
        { "name": "Unit", "match": "test", "env": "Locl" },
        { "name": "Lint", "match": "lint", "env": "Locl" }
      ],
      "required": [
        "Unit@Local",
        "Nope@Local",
        "Nope@Local"
      ]
    }
    """
    let found = issues(text)
    #expect(found.contains { $0.message == "environment Local is defined twice." && $0.line == 5 })
    #expect(found.contains { $0.message == "check Unit names environment Locl, which isn't defined." && $0.line == 8 })
    #expect(found.contains { $0.message == "check Lint names environment Locl, which isn't defined." && $0.line == 9 })
    let required = found.filter { $0.message == "required Nope@Local names check Nope, which isn't defined." }
    #expect(required.map(\.line) == [13, 14])
    #expect(required.first?.excerpt == "\"Nope@Local\",")
  }

  @Test func compactJSONStillHasLines() {
    let text = "{\n\"version\":1,\n\"environments\":[{\"name\":\"Local\",\"url\":\"u\"}],\n\"checks\":[\n"
      + "{\"name\":\"A\",\"match\":\"t\",\"env\":\"Locl\"},\n{\"name\":\"B\",\"match\":\"t\",\"env\":\"Locl\"}\n]\n}"
    let found = issues(text)
    #expect(found.contains { $0.message == "check A names environment Locl, which isn't defined." && $0.line == 5 })
    #expect(found.contains { $0.message == "check B names environment Locl, which isn't defined." && $0.line == 6 })
  }

  @Test func wrongTypeInASecondEntryKeepsItsPath() {
    let text = """
    {
      "version": 1,
      "environments": [
        { "name": "Local", "url": "u", "match": ["x"] }
      ],
      "checks": [
        { "name": "Unit", "match": "t", "env": "Local" },
        { "name": "Lint", "match": "l", "env": 5 }
      ]
    }
    """
    let found = issues(text)
    #expect(found.count == 1)
    #expect(found.first?.message == #"check "Lint"'s env has the wrong type."#)
    #expect(found.first?.line == 8)
    let entry = issues(text.replacingOccurrences(of: "\"env\": 5", with: "\"env\": \"Local\"")
      .replacingOccurrences(of: "\"match\": [\"x\"]", with: "\"match\": [1]"))
    #expect(entry.first?.message == #"environment "Local"'s match entry 1 has the wrong type."#)
    #expect(entry.first?.line == 4)
  }

  @Test func missingKeyNamesTheOwnerAndItsLine() {
    let text = """
    {
      "version": 1,
      "environments": [ { "name": "Local", "url": "u" } ],
      "checks": [
        { "name": "Unit", "match": "t", "env": "Local" },
        {
          "name": "E2E",
          "env": "Local"
        }
      ]
    }
    """
    let found = issues(text)
    #expect(found.first?.message == #"check "E2E" needs "match"."#)
    #expect(found.first?.line == 6)
    let unnamed = issues(text.replacingOccurrences(of: "\"name\": \"E2E\",", with: "\"match\": \"x\","))
    #expect(unnamed.first?.message == #"check 2 needs "name"."#)
    #expect(unnamed.first?.line == 6)
  }

  // MARK: Linked worktrees. An untracked proof.json lives only in the main worktree.

  /// A real linked-worktree layout: `main/.git/` is a directory holding `worktrees/feature/{gitdir,commondir,HEAD}`,
  /// and `feature/.git` is a file `gitdir: <main>/.git/worktrees/feature`.
  private func makeLinkedWorktree() throws -> (base: URL, main: URL, linked: URL) {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("setup-wt-\(UUID().uuidString)")
    let main = base.appendingPathComponent("main"), linked = base.appendingPathComponent("feature")
    let admin = main.appendingPathComponent(".git/worktrees/feature")
    try fm.createDirectory(at: admin, withIntermediateDirectories: true)
    try fm.createDirectory(at: linked.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
    try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    try "\(linked.path)/.git\n".write(to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
    try "gitdir: \(admin.path)\n".write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    return (base, main, linked)
  }

  @Test func linkedWorktreeFallsBackToTheMainWorktreesSetup() throws {
    let (base, main, linked) = try makeLinkedWorktree()
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(ProofSetupFile.load(cwd: linked.path) == .missing)
    try FileManager.default.createDirectory(at: main.appendingPathComponent(".glance"), withIntermediateDirectories: true)
    try Self.good.write(to: main.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    let deep = linked.appendingPathComponent("src/deep").path
    #expect(ProofSetupFile.root(from: deep) == main.path)
    let load = ProofSetupFile.load(cwd: deep)
    #expect(load.setup?.checks.count == 2)
    #expect(load.root == main.path)
  }

  @Test func linkedWorktreesOwnSetupWinsOverTheMainOne() throws {
    let (base, main, linked) = try makeLinkedWorktree()
    defer { try? FileManager.default.removeItem(at: base) }
    for dir in [main, linked] { try FileManager.default.createDirectory(at: dir.appendingPathComponent(".glance"), withIntermediateDirectories: true) }
    try Self.good.write(to: main.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    try Self.good.write(to: linked.appendingPathComponent(".glance/proof.json"), atomically: true, encoding: .utf8)
    #expect(ProofSetupFile.root(from: linked.appendingPathComponent("src").path) == linked.path)
  }

  @Test func brokenGitFileMeansMissingNotACrash() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("setup-bad-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: base) }
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    try "gitdir: /nonexistent/\(UUID().uuidString)\n".write(to: base.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    #expect(ProofSetupFile.load(cwd: base.path) == .missing)
  }
}
