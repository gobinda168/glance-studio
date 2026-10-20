import Foundation
import Testing
@testable import GlanceCore

private func candidate(_ row: String) -> CompletionCandidate? {
  CompletionCandidate(fields: ShellWire.fields(row)[...])
}

@Test func readsZshDisplayIntoNameAndDetail() throws {
  let checkout = try #require(candidate("1\tmain porcelain command\tmain-porcelain-commands\tcheckout\t"
    + "checkout         -- checkout branch or paths to working tree\t\t4\t"))
  #expect(checkout.index == 1)
  #expect(checkout.group == "main porcelain command")
  #expect(checkout.word == "checkout")
  #expect(checkout.name == "checkout")
  #expect(checkout.detail == "checkout branch or paths to working tree")
  #expect(checkout.start == 4)
  #expect(checkout.kind == .command)
  #expect(!checkout.isFile && !checkout.isDirectory && !checkout.isOrdered)

  let option = try #require(candidate("3\toption\toptions\t-a\t-a  -- list entries starting with .\to\t3\t"))
  #expect(option.name == "-a")
  #expect(option.detail == "list entries starting with .")
  #expect(option.isOrdered)
  #expect(option.kind == .option)

  let bare = try #require(candidate("1\toption\toptions\t-@\t-@\to\t3\t"))
  #expect(bare.name == "-@" && bare.detail.isEmpty)
}

@Test func unquotesFileNamesForDisplay() throws {
  // On the wire the shell's backslash is escaped: `my\\ file.txt`.
  let file = try #require(candidate("1\tfile\tglobbed-files\tmy\\\\ file.txt\t\tf\t4\t"))
  #expect(file.word == #"my\ file.txt"#)
  #expect(file.name == "my file.txt")
  #expect(file.kind == .file)
  let folder = try #require(candidate("2\tfile\tglobbed-files\tshare\t\tfd\t3\t/usr/"))
  #expect(folder.isDirectory && folder.isFile)
  #expect(folder.kind == .folder)
  #expect(folder.hidden == "/usr/")
}

@Test func kindsFollowZshTags() throws {
  let cases: [(String, CompletionCandidate.Kind)] = [
    ("commands", .command), ("builtins", .command), ("aliases", .command), ("functions", .command),
    ("main-porcelain-commands", .command), ("reserved-words", .command),
    ("options", .option), ("directories", .folder), ("local-directories", .folder), ("named-directories", .folder),
    ("heads-local", .branch), ("remote-branch-names-noprefix", .branch), ("tags", .branch), ("commits", .branch),
    ("hosts", .host), ("users", .user), ("processes", .process), ("jobs", .process), ("parameters", .variable),
    ("values", .value), ("", .value),
  ]
  for (tag, kind) in cases {
    let row = "1\tgroup\t\(tag)\tword\t\t\t0\t"
    #expect(try #require(candidate(row)).kind == kind, "\(tag)")
  }
}

@Test func rejectsRowsWithMissingFields() {
  #expect(candidate("1\tgroup\ttag") == nil)
  #expect(candidate("x\tg\tt\tw\td\t\t0\t") == nil)
  #expect(candidate("1\tg\tt\tw\td\t\tnope\t") == nil)
}
