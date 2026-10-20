import Testing
@testable import GlanceCore

private let home = "/Users/me"

@Test func lineAndColumnSuffixesAreSplitOff() {
  #expect(PathLinks.parse("src/App.swift:12:5") == PathLink(path: "src/App.swift", line: 12, column: 5))
  #expect(PathLinks.parse("src/App.swift:12") == PathLink(path: "src/App.swift", line: 12, column: nil))
  #expect(PathLinks.parse("src/App.swift:12:") == PathLink(path: "src/App.swift", line: 12, column: nil))
  #expect(PathLinks.parse("src/App.swift") == PathLink(path: "src/App.swift", line: nil, column: nil))
}

@Test func githubAnchorsAreLinesToo() {
  // Claude's markdown links name lines the way GitHub does.
  #expect(PathLinks.parse("Sources/A.swift#L12") == PathLink(path: "Sources/A.swift", line: 12, column: nil))
  #expect(PathLinks.parse("Sources/A.swift#L12C5") == PathLink(path: "Sources/A.swift", line: 12, column: 5))
  #expect(PathLinks.parse("Sources/A.swift#L12-L20") == PathLink(path: "Sources/A.swift", line: 12, column: nil))
  #expect(PathLinks.parse("file:///Users/me/A.swift#L3") == PathLink(path: "/Users/me/A.swift", line: 3, column: nil))
  #expect(PathLinks.parse("notes#todo.md").path == "notes#todo.md")
}

@Test func fileURLsLoseTheirScheme() {
  #expect(PathLinks.parse("file:///Users/me/a.txt:3") == PathLink(path: "/Users/me/a.txt", line: 3, column: nil))
}

@Test func hyperlinkFileURLsAreDecoded() {
  // Claude Code's OSC 8 links are percent-encoded file URLs, sometimes naming localhost.
  #expect(PathLinks.parse("file:///Users/me/My%20App/a.swift").path == "/Users/me/My App/a.swift")
  #expect(PathLinks.parse("file://localhost/Users/me/a.swift") == PathLink(path: "/Users/me/a.swift", line: nil, column: nil))
}

@Test func colonsThatAreNotPositionsStayInThePath() {
  #expect(PathLinks.parse("notes:final.txt").path == "notes:final.txt")
  #expect(PathLinks.parse("a:b:12:5") == PathLink(path: "a:b", line: 12, column: 5))
  #expect(PathLinks.parse("x.txt:abc").path == "x.txt:abc")
}

@Test func lineZeroIsNotALine() {
  #expect(PathLinks.parse("a.txt:0") == PathLink(path: "a.txt", line: nil, column: nil))
}

@Test func pathsResolveAgainstTheFolderTheyWereSeenIn() {
  #expect(PathLinks.resolve("/abs/x.swift", relativeTo: "/Users/me/app", home: home) == "/abs/x.swift")
  #expect(PathLinks.resolve("src/x.swift", relativeTo: "/Users/me/app", home: home) == "/Users/me/app/src/x.swift")
  #expect(PathLinks.resolve("../lib/x.swift", relativeTo: "/Users/me/app/", home: home) == "/Users/me/lib/x.swift")
  #expect(PathLinks.resolve("~/notes.md", relativeTo: nil, home: home) == "/Users/me/notes.md")
  #expect(PathLinks.resolve("./x.swift", relativeTo: "~/app", home: home) == "/Users/me/app/x.swift")
}

@Test func aRelativePathWithoutAFolderCannotBeResolved() {
  #expect(PathLinks.resolve("x.swift", relativeTo: nil, home: home) == nil)
  #expect(PathLinks.resolve("x.swift", relativeTo: "", home: home) == nil)
}

@Test func relativePathsAreInsideTheRootOrNil() {
  #expect(PathLinks.relative("/Users/me/app/src/x.swift", inRoot: "/Users/me/app") == "src/x.swift")
  #expect(PathLinks.relative("/Users/me/app", inRoot: "/Users/me/app") == nil)
  #expect(PathLinks.relative("/Users/me/app2/x.swift", inRoot: "/Users/me/app") == nil)
  #expect(PathLinks.relative("/etc/hosts", inRoot: "/Users/me/app") == nil)
}
