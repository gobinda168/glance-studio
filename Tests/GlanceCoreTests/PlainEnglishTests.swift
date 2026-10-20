import Testing
@testable import GlanceCore

private let known: Set<String> = ["git", "ls", "find", "make", "echo", "cd", "grep"]
private func request(_ line: String) -> Bool { PlainEnglish.isRequest(line) { known.contains($0) } }

@Test func sentencesAreRequests() {
  #expect(request("create a directory"))
  #expect(request("show me the biggest files"))
  #expect(request("how do I undo the last commit?"))
  #expect(request("delete folder"))
  #expect(request("Create a folder called notes"))
}

@Test func commandsAreNot() {
  #expect(!request("git status"))
  #expect(!request("ls -la"))
  #expect(!request("find the biggest files"))      // `find` is a command
  #expect(!request("make build"))
  #expect(!request("echo hello world"))
  #expect(!request("cd src"))
}

@Test func typosAndOneWordsAreNot() {
  #expect(!request("gti status"))                  // two words, the first not a verb
  #expect(!request("create"))
  #expect(!request("dokcer ps"))
}

@Test func anythingThatLooksLikeShellIsNot() {
  #expect(!request("create a file > notes.txt"))
  #expect(!request("show me ./build/out"))
  #expect(!request("delete the 'old' folder"))
  #expect(!request("open $HOME now"))
  #expect(!request("start a -v run"))
  #expect(!request("# create a directory"))
  #expect(!request("create a\ndirectory"))
}
