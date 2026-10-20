import Testing
@testable import GlanceCore

private let home = "/Users/me"

@Test func sameFolderMatchesWhateverTheSpelling() {
  #expect(SessionMatch.matches(sessionCwd: "/Users/me/Code/app", surfacePwd: "/Users/me/Code/app", home: home))
  #expect(SessionMatch.matches(sessionCwd: "/Users/me/Code/app", surfacePwd: "/Users/me/Code/app/", home: home))
  #expect(SessionMatch.matches(sessionCwd: "/Users/me/Code/app", surfacePwd: "~/Code/app", home: home))
  #expect(SessionMatch.matches(sessionCwd: "/Users/me/Code/app", surfacePwd: "/Users/me/Code/x/../app", home: home))
  #expect(SessionMatch.matches(sessionCwd: "/private/tmp/scratch", surfacePwd: "/tmp/scratch", home: home))
  #expect(SessionMatch.matches(sessionCwd: "~", surfacePwd: "/Users/me", home: home))
}

@Test func parentAndChildFoldersDontMatch() {
  #expect(!SessionMatch.matches(sessionCwd: "/Users/me/Code", surfacePwd: "/Users/me/Code/app", home: home))
  #expect(!SessionMatch.matches(sessionCwd: "/Users/me/Code/app/src", surfacePwd: "/Users/me/Code/app", home: home))
  #expect(!SessionMatch.matches(sessionCwd: "/Users/me/Code/app2", surfacePwd: "/Users/me/Code/app", home: home))
}

@Test func unknownFoldersNeverMatch() {
  #expect(!SessionMatch.matches(sessionCwd: nil, surfacePwd: "/Users/me", home: home))
  #expect(!SessionMatch.matches(sessionCwd: "/Users/me", surfacePwd: nil, home: home))
  #expect(!SessionMatch.matches(sessionCwd: "", surfacePwd: "", home: home))
}

@Test func onlyTheSystemPrivateFoldersLoseTheirPrefix() {
  #expect(SessionMatch.normalize("/private/var/folders/x", home: home) == "/var/folders/x")
  #expect(SessionMatch.normalize("/private/etc", home: home) == "/etc")
  #expect(SessionMatch.normalize("/private/tmpfoo", home: home) == "/private/tmpfoo")
  #expect(SessionMatch.normalize("/private/stuff", home: home) == "/private/stuff")
}
