import Foundation
import Testing
@testable import GlanceCore

@Test func parsesPlainLines() {
  let entries = ZshHistory.parse(Data("cd 'Code'\ngit status\n\nls -la\n".utf8))
  #expect(entries.map(\.command) == ["cd 'Code'", "git status", "ls -la"])
  #expect(entries.allSatisfy { $0.start == nil && $0.duration == nil })
}

@Test func parsesExtendedLines() {
  let entries = ZshHistory.parse(Data(": 1696000000:0;git push\n: 1696000100:12;make test\n".utf8))
  #expect(entries.map(\.command) == ["git push", "make test"])
  #expect(entries[0].start == Date(timeIntervalSince1970: 1_696_000_000))
  #expect(entries[1].duration == 12)
}

@Test func parsesBackslashesAndContinuations() {
  // zsh writes a newline inside a command as backslash + newline, and reads it back the same way (hist.c).
  let text = "# Download and install nvm:\\\ncurl -o- https://x | bash\\\n\\\n# in lieu\nnext\n"
  let entries = ZshHistory.parse(Data(text.utf8))
  #expect(entries.map(\.command) == ["# Download and install nvm:\ncurl -o- https://x | bash\n\n# in lieu", "next"])
  let extended = ZshHistory.parse(Data(": 1:0;for x in 1 2; do\\\n  echo $x\\\ndone\n".utf8))
  #expect(extended.map(\.command) == ["for x in 1 2; do\n  echo $x\ndone"])
  // A backslash inside a line is just a character.
  #expect(ZshHistory.parse(Data("echo a\\b\n".utf8)).map(\.command) == ["echo a\\b"])
}

@Test func unmetafiesBytes() {
  // zsh stores its special bytes (0x83 to 0x9b and a few more) as 0x83 followed by the byte XOR 0x20: U+2002 is
  // E2 80 82 in UTF-8, and its 0x80 goes to the file as 83 A0.
  var data = Data("echo ".utf8)
  data.append(contentsOf: [0xE2, 0x83, 0x80 ^ 0x20, 0x82])
  data.append(contentsOf: Array("\n".utf8))
  let entries = ZshHistory.parse(data)
  #expect(entries.count == 1)
  #expect(entries[0].command.unicodeScalars.first?.value == "e".unicodeScalars.first?.value)
  #expect(Array(entries[0].command.utf8.suffix(3)) == [0xE2, 0x80, 0x82])
}

@Test func survivesBrokenInput() {
  #expect(ZshHistory.parse(Data()).isEmpty)
  let broken = ZshHistory.parse(Data([0x66, 0x6F, 0xFF, 0x6F, 0x0A, 0x83]))
  #expect(broken.count == 1)
  #expect(broken[0].command.hasPrefix("fo"))
}

@Test func importedRowsKeepTheFilesOrderBeforeTheFirstRecordedRun() {
  let base = Date(timeIntervalSince1970: 1_000)
  let entries = ZshHistory.parse(Data("ls\n export TOKEN_X=1\ngit status\nexport GH_TOKEN=ghp_x\nmake\n".utf8))
  let records = ZshHistory.records(entries, before: base)
  #expect(records.map(\.command) == ["ls", "git status", "make"])
  #expect(records.allSatisfy { $0.imported && $0.folder == nil && $0.exitCode == nil && $0.start < base })
  #expect(zip(records, records.dropFirst()).allSatisfy { $0.start < $1.start })
  let dated = ZshHistory.records(ZshHistory.parse(Data(": 500:3;ls\n".utf8)), before: base)
  #expect(dated.first?.start == Date(timeIntervalSince1970: 500) && dated.first?.duration == 3)
}
