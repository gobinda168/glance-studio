import Foundation
import Testing
@testable import GlanceCore

@Test func webLanguagesGoToPrettierWithTheRightParser() {
  #expect(CodeFormatter.plan(for: "/p/a.tsx") == .prettier(parser: "typescript"))
  #expect(CodeFormatter.plan(for: "/p/a.mjs") == .prettier(parser: "babel"))
  #expect(CodeFormatter.plan(for: "/p/a.SCSS") == .prettier(parser: "scss"))
  #expect(CodeFormatter.plan(for: "/p/README.md") == .prettier(parser: "markdown"))
  #expect(CodeFormatter.plan(for: "/p/ci.yml") == .prettier(parser: "yaml"))
  #expect(CodeFormatter.plan(for: "/p/package.json") == .prettier(parser: "json-stringify"))
  #expect(CodeFormatter.plan(for: "/p/tsconfig.json") == .prettier(parser: "json"))
}

@Test func otherLanguagesGoToTheirCommandLineFormatters() {
  let none: (String) -> Bool = { _ in false }
  guard case .tools(let python) = CodeFormatter.plan(for: "/p/a.py", exists: none) else { Issue.record(); return }
  #expect(python.map(\.name) == ["ruff", "black"])
  #expect(python[0].arguments == ["format", "--stdin-filename", "/p/a.py", "-"])
  guard case .tools(let go) = CodeFormatter.plan(for: "/p/main.go", exists: none) else { Issue.record(); return }
  #expect(go.map(\.name) == ["gofmt"])
  guard case .tools(let shell) = CodeFormatter.plan(for: "/p/x.sh", exists: none) else { Issue.record(); return }
  #expect(shell == [CodeFormatter.Tool(name: "shfmt", arguments: ["--filename", "/p/x.sh"])])
  #expect(CodeFormatter.plan(for: "/p/notes.txt", exists: none) == nil)
  #expect(CodeFormatter.plan(for: "/p/Makefile", exists: none) == nil)
}

@Test func aSwiftformatFilePicksNickLockwoodsSwiftFormat() {
  guard case .tools(let apple) = CodeFormatter.plan(for: "/p/Sources/a.swift", exists: { _ in false }) else { Issue.record(); return }
  #expect(apple.map(\.name) == ["swift-format", "swiftformat"])
  guard case .tools(let nick) = CodeFormatter.plan(for: "/p/Sources/a.swift", exists: { $0 == "/p/.swiftformat" }) else { Issue.record(); return }
  #expect(nick.map(\.name) == ["swiftformat", "swift-format"])
}

@Test func rustfmtGetsTheCratesEdition() {
  let cargo = "[package]\nname = \"x\"\nedition = \"2024\"\n"
  guard case .tools(let tools) = CodeFormatter.plan(for: "/p/src/main.rs", exists: { $0 == "/p/Cargo.toml" },
                                                    read: { $0 == "/p/Cargo.toml" ? cargo : nil }) else { Issue.record(); return }
  #expect(tools[0].arguments == ["--emit", "stdout", "--edition", "2024"])
  guard case .tools(let fallback) = CodeFormatter.plan(for: "/p/main.rs", exists: { _ in false }) else { Issue.record(); return }
  #expect(fallback[0].arguments.last == "2021")
}

@Test func theMissingMessageNamesWhatToInstall() {
  guard case .tools(let tools) = CodeFormatter.plan(for: "/p/a.py", exists: { _ in false }) else { Issue.record(); return }
  #expect(CodeFormatter.missing(tools, for: "/p/a.py") == .noFormatter("No formatter for Python files: install ruff or black."))
}

@Test func toolsAreLookedForInTheProjectFirst() {
  let folders = CodeFormatter.searchFolders(file: "/p/web/src/a.py", root: "/p", loginPath: "/usr/bin:/opt/homebrew/bin", home: "/h")
  #expect(Array(folders.prefix(3)) == ["/p/web/src/node_modules/.bin", "/p/web/src/.venv/bin", "/p/web/src/venv/bin"])
  #expect(folders.contains("/p/.venv/bin"))
  #expect(!folders.contains("/node_modules/.bin")) // not above the root
  #expect(folders.firstIndex(of: "/p/.venv/bin")! < folders.firstIndex(of: "/usr/bin")!)
  #expect(folders.filter { $0 == "/opt/homebrew/bin" }.count == 1)
  let tools = [CodeFormatter.Tool(name: "ruff", arguments: []), CodeFormatter.Tool(name: "black", arguments: [])]
  let found = CodeFormatter.find(tools, in: folders) { $0 == "/opt/homebrew/bin/black" || $0 == "/p/.venv/bin/black" }
  #expect(found?.0.name == "black")
  #expect(found?.1 == "/p/.venv/bin/black")
  #expect(CodeFormatter.find(tools, in: folders) { _ in false } == nil)
}

/// A fake formatter: a shell script given as `sh -c`.
private func runScript(_ script: String, text: String, timeout: TimeInterval = 10) -> Result<String, CodeFormatter.Failure> {
  CodeFormatter.run(executable: "/bin/sh", arguments: ["-c", script], text: text, directory: NSTemporaryDirectory(), path: nil, timeout: timeout)
}

@Test func runningAFormatterPipesTheTextThroughIt() {
  #expect(runScript("tr a-z A-Z", text: "hello\n") == .success("HELLO\n"))
  let big = String(repeating: "line of text\n", count: 40_000) // larger than a pipe's buffer, both ways
  #expect(runScript("cat", text: big) == .success(big))
}

@Test func aFailingFormatterReportsWhatItSaid() {
  #expect(runScript("echo 'line 3: unexpected token' >&2; exit 2", text: "x") == .failure(.failed("sh: line 3: unexpected token")))
  #expect(runScript("exit 1", text: "x") == .failure(.failed("sh: exited with status 1")))
  #expect(runScript("cat >/dev/null", text: "x = 1") == .failure(.failed("sh printed nothing.")))
}

@Test func aFormatterThatHangsIsStopped() {
  let started = Date()
  #expect(runScript("sleep 30", text: "x", timeout: 0.5) == .failure(.failed("sh took longer than 0 seconds.")))
  #expect(Date().timeIntervalSince(started) < 5)
}

@Test func theProjectsOwnPrettierIsFoundBetweenTheFileAndTheRoot() {
  let installed: Set<String> = ["/p/node_modules/.bin/prettier", "/node_modules/.bin/prettier"]
  #expect(CodeFormatter.projectPrettier(file: "/p/web/src/a.ts", root: "/p", isExecutable: installed.contains) == "/p/node_modules/.bin/prettier")
  let nearer = installed.union(["/p/web/node_modules/.bin/prettier"])
  #expect(CodeFormatter.projectPrettier(file: "/p/web/src/a.ts", root: "/p", isExecutable: nearer.contains) == "/p/web/node_modules/.bin/prettier")
  // Not above the root, and not a global install.
  #expect(CodeFormatter.projectPrettier(file: "/q/a.ts", root: "/q", isExecutable: installed.contains) == nil)
}

@Test func theProjectsPrettierGetsTheFileAndTheSelection() {
  #expect(CodeFormatter.prettierArguments(for: "/p/a.ts", range: nil) == ["--stdin-filepath", "/p/a.ts"])
  #expect(CodeFormatter.prettierArguments(for: "/p/a.ts", range: 4..<20)
    == ["--stdin-filepath", "/p/a.ts", "--range-start", "4", "--range-end", "20"])
}
