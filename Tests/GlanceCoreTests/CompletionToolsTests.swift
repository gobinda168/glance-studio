import Foundation
import Testing
@testable import GlanceCore

@Test func locatesTheFirstExecutableOnPath() {
  let executables: Set<String> = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "/usr/bin/git"]
  let found = { (path: String) in executables.contains(path) }
  #expect(CompletionTools.locate("uv", path: "/usr/bin:/opt/homebrew/bin:/usr/local/bin", isExecutable: found)
    == "/opt/homebrew/bin/uv")
  #expect(CompletionTools.locate("uv", path: "/usr/bin", isExecutable: found) == nil)
  #expect(CompletionTools.locate("uv", path: "", isExecutable: found) == nil)
  #expect(CompletionTools.locate("git", path: "::/usr/bin:", isExecutable: found) == "/usr/bin/git")
  #expect(CompletionTools.locate("../evil", path: "/usr/bin", isExecutable: { _ in true }) == nil)
}

@Test func stampsChangeWithTheTool() {
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let stamp = CompletionTools.stamp(path: "/a/uv", size: 10, modified: date)
  #expect(stamp == CompletionTools.stamp(path: "/a/uv", size: 10, modified: date))
  #expect(stamp != CompletionTools.stamp(path: "/a/uv", size: 11, modified: date))
  #expect(stamp != CompletionTools.stamp(path: "/a/uv", size: 10, modified: date.addingTimeInterval(1)))
  #expect(stamp != CompletionTools.stamp(path: "/b/uv", size: 10, modified: date))
}

@Test func tellsCompletionScriptsFromErrors() {
  #expect(CompletionTools.isCompletionScript("#compdef uv\n\nautoload -U is-at-least\n_uv() {\n}\n"))
  #expect(!CompletionTools.isCompletionScript("error: unrecognized subcommand 'completion'\n"))
  #expect(!CompletionTools.isCompletionScript(""))
  #expect(!CompletionTools.isCompletionScript("Usage: tool [options]\n  compdef is not here\n"))
}

@Test func namesAutoloadableAndSourcedScripts() {
  // clap and cobra scripts define _<command>: autoloaded from fpath.
  #expect(CompletionTools.fileName(for: "uv", script: "#compdef uv\n_uv() {\n  :\n}\n") == "_uv")
  #expect(CompletionTools.fileName(for: "kubectl", script: "#compdef kubectl\ncompdef _kubectl kubectl\n_kubectl()\n{\n}\n")
    == "_kubectl")
  #expect(CompletionTools.fileName(for: "deno", script: "#compdef deno\n\n_deno() {\n}\n") == "_deno")
  // tabtab (pnpm) defines another function and registers it itself: sourced.
  #expect(CompletionTools.fileName(for: "pnpm", script: "#compdef pnpm\n###-begin-pnpm-completion-###\n"
    + "if type compdef &>/dev/null; then\n  _pnpm_completion () {\n  }\n  compdef _pnpm_completion pnpm\nfi\n")
    == "pnpm.zsh")
}

@Test func theToolListIsSane() {
  let commands = CompletionTools.tools.map(\.command)
  #expect(Set(commands).count == commands.count)
  #expect(commands.contains("pnpm") && commands.contains("kubectl") && commands.contains("cargo"))
  #expect(CompletionTools.tools.allSatisfy { !$0.arguments.isEmpty })
}
