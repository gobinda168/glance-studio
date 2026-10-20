import Foundation
import Testing
@testable import GlanceCore

@Test func whatEachLineAsks() {
  #expect(TerminalAsk.kind(line: "# find files over 100 MB here", lastFailed: false) == .request("find files over 100 MB here"))
  #expect(TerminalAsk.kind(line: "#list ports", lastFailed: true) == .request("list ports"))
  #expect(TerminalAsk.kind(line: "#", lastFailed: false) == nil)
  #expect(TerminalAsk.kind(line: "", lastFailed: true) == .failure)
  #expect(TerminalAsk.kind(line: "   ", lastFailed: false) == nil)
  #expect(TerminalAsk.kind(line: "tar -xzvf a.tgz -C out", lastFailed: true) == .explain("tar -xzvf a.tgz -C out"))
}

private func context(failure: Failure? = nil) -> TerminalAsk.Context {
  TerminalAsk.Context(folder: "~/Code/app", system: "macOS 27.0, zsh 5.9", branch: "main",
                      recent: [("git status", 0), ("npm test", 1)], scripts: ["build", "test"], makeTargets: ["all"],
                      failure: failure)
}

@Test func thePromptCarriesTheContextWithoutSecrets() {
  let failure = Failure(command: "curl -H 'Authorization: Bearer abc.def' https://x", exitCode: 6,
                        output: "curl: (6) Could not resolve host: x\nexport API_TOKEN=s3cr3t", folder: "/x")
  let prompt = TerminalAsk.prompt(.failure, context(failure: failure))
  #expect(prompt.contains("Folder: ~/Code/app"))
  #expect(prompt.contains("Git branch: main"))
  #expect(prompt.contains("npm test") && prompt.contains("exit 1"))
  #expect(prompt.contains("package.json scripts: build, test"))
  #expect(prompt.contains("Could not resolve host"))
  #expect(!prompt.contains("abc.def") && !prompt.contains("s3cr3t"))
  // A request doesn't send the failure's output.
  let request = TerminalAsk.prompt(.request("list big files"), context(failure: failure))
  #expect(request.hasPrefix("Request: list big files"))
  #expect(!request.contains("Could not resolve host"))
}

@Test func theBranchLineCountsTheChanges() {
  var counted = context()
  counted.changes = TerminalAsk.changeCounts([.init(path: "a.swift", status: .modified), .init(path: "b", status: .untracked),
                                              .init(path: "c.md", status: .added)])
  #expect(TerminalAsk.prompt(.request("x"), counted).contains("Git branch: main (2 files changed, 1 untracked)"))
  counted.changes = (1, 0)
  #expect(TerminalAsk.prompt(.request("x"), counted).contains("Git branch: main (1 file changed, 0 untracked)"))
  counted.changes = (0, 0)
  #expect(TerminalAsk.prompt(.request("x"), counted).contains("Git branch: main (no uncommitted changes)"))
  // Not counted (git was slow): the branch alone.
  #expect(TerminalAsk.prompt(.request("x"), context()).contains("Git branch: main\n"))
}

private func runGit(_ dir: URL, _ args: String...) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
  process.arguments = ["-C", dir.path, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
}

@Test func countsARealRepositorysChanges() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  #expect(TerminalAsk.changeCounts(root: dir.path, timeout: 5) == nil)
  try runGit(dir, "init", "-q")
  try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  try runGit(dir, "add", ".")
  try runGit(dir, "commit", "-q", "-m", "first")
  #expect(TerminalAsk.changeCounts(root: dir.path, timeout: 5).map { [$0.changed, $0.untracked] } == [0, 0])
  try "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
  try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
  // An untracked folder counts once.
  let folder = dir.appendingPathComponent("notes")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  for name in ["x", "y", "z"] {
    try name.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
  #expect(TerminalAsk.changeCounts(root: dir.path, timeout: 5).map { [$0.changed, $0.untracked] } == [1, 2])
  // The index wasn't locked or rewritten by it.
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git/index.lock").path))
}

@Test func readsTheAnswerEvenInAFence() {
  let fenced = "```json\n{\"explanation\": \"Lists by size.\", \"commands\": [{\"command\": \"ls -lhS\", \"note\": \"largest first\"}, {\"command\": \"rm -rf build\", \"note\": \"clean\"}]}\n```"
  let answer = TerminalAsk.answer(fenced)
  #expect(answer.explanation == "Lists by size.")
  #expect(answer.commands.map(\.command) == ["ls -lhS", "rm -rf build"])
  #expect(answer.commands.map(\.risky) == [false, true])
  let plain = TerminalAsk.answer("Sorry, I can't tell from here.")
  #expect(plain.explanation == "Sorry, I can't tell from here." && plain.commands.isEmpty)
  let structured = TerminalAsk.answer(#"{"explanation":"x","commands":[]}"#)
  #expect(structured.explanation == "x" && structured.commands.isEmpty)
}

@Test func riskyCommandsAreFlagged() {
  for command in ["rm -rf node_modules", "git reset --hard HEAD~1", "git push --force", "git push -f origin x",
                  "git clean -fd", "chmod -R 777 .", "sudo ls", "dd if=/dev/zero of=x", "kill -9 123",
                  "docker system prune -a", "psql -c 'DROP TABLE users'", "mkfs.ext4 /dev/sda"] {
    #expect(TerminalAsk.isRisky(command), "\(command)")
  }
  for command in ["ls -la", "git status", "git push", "npm run build", "rm file.txt", "chmod +x run.sh"] {
    #expect(!TerminalAsk.isRisky(command), "\(command)")
  }
}

@Test func makefileTargets() {
  let makefile = "VAR = 1\n.PHONY: all test\nall: build\n\tcc x\nbuild:\n\tcc y\ntest: all\n%.o: %.c\n\tcc\n"
  #expect(TerminalAsk.makeTargets(makefile) == ["all", "build", "test"])
}
