import Foundation
import Testing
@testable import GlanceCore

private let t0 = Date(timeIntervalSince1970: 1_000)

@Test func theWrapperSaysWhoItIsAndWhatItOwns() {
  // The exact lines session-mcp.mjs writes (agent-browser/session-mcp.mjs, "Socket protocol").
  #expect(BrowserSessionTable.decode(#"{"type":"hello","wrapperPid":4121,"claudePid":4100,"session":"7d3f","cwd":"/Users/me/app"}"#)
    == .hello(wrapperPID: 4121, claudePID: 4100, session: "7d3f", cwd: "/Users/me/app"))
  // Claude Code may not tell the session id, and a wrapper may have no cwd to give.
  #expect(BrowserSessionTable.decode(#"{"type":"hello","wrapperPid":4121,"claudePid":4100}"#)
    == .hello(wrapperPID: 4121, claudePID: 4100, session: nil, cwd: nil))
  #expect(BrowserSessionTable.decode(#"{"type":"hello","wrapperPid":4121,"claudePid":4100,"session":null,"cwd":null}"#)
    == .hello(wrapperPID: 4121, claudePID: 4100, session: nil, cwd: nil))
  #expect(BrowserSessionTable.decode(#"{"type":"page","targetId":"AB12","adopted":false}"#) == .page(targetId: "AB12", adopted: false))
  #expect(BrowserSessionTable.decode(#"{"type":"page","targetId":"AB12","openerId":"CD34","adopted":true}"#) == .page(targetId: "AB12", adopted: true))
  #expect(BrowserSessionTable.decode(#"{"type":"page","targetId":"AB12"}"#) == .page(targetId: "AB12", adopted: false))
  #expect(BrowserSessionTable.decode(#"{"type":"pageGone","targetId":"AB12"}"#) == .pageGone(targetId: "AB12"))
  #expect(BrowserSessionTable.decode(#"{"type":"tool","name":"browser_click","phase":"start"}"#) == .tool(name: "browser_click", phase: .start))
  #expect(BrowserSessionTable.decode(#"{"type":"tool","name":"browser_click","phase":"end"}"#) == .tool(name: "browser_click", phase: .end))
}

@Test func anythingMalformedOrUnknownDecodesToNothing() {
  let bad = [
    "", "not json", "[1,2]", "null", #""hello""#, "{}",
    #"{"type":"mystery","targetId":"A"}"#,
    #"{"type":7}"#,
    #"{"type":"hello"}"#,
    #"{"type":"hello","wrapperPid":"4121","claudePid":4100}"#,
    #"{"type":"hello","wrapperPid":4121.5,"claudePid":4100}"#,
    #"{"type":"hello","wrapperPid":4121,"claudePid":99999999999}"#,
    #"{"type":"hello","wrapperPid":4121,"claudePid":4100,"session":12}"#,
    #"{"type":"hello","wrapperPid":4121,"claudePid":4100,"cwd":["/x"]}"#,
    #"{"type":"page"}"#,
    #"{"type":"page","targetId":""}"#,
    #"{"type":"page","targetId":5}"#,
    #"{"type":"page","targetId":"A","adopted":"yes"}"#,
    #"{"type":"pageGone"}"#,
    #"{"type":"pageGone","targetId":false}"#,
    #"{"type":"tool","name":"browser_click"}"#,
    #"{"type":"tool","name":"browser_click","phase":"middle"}"#,
    #"{"type":"tool","name":3,"phase":"start"}"#,
    #"{"type":"tool","phase":"start"}"#,
  ]
  for line in bad { #expect(BrowserSessionTable.decode(line) == nil, "\(line) isn't a message") }
}

private func table(_ events: [(Int, BrowserSessionTable.Event)]) -> BrowserSessionTable {
  var table = BrowserSessionTable()
  for (client, event) in events { table.apply(event, client: client, at: t0) }
  return table
}

private func hello(_ wrapper: Int32, claude: Int32, session: String? = nil, cwd: String? = nil) -> BrowserSessionTable.Event {
  .hello(wrapperPID: wrapper, claudePID: claude, session: session, cwd: cwd)
}

@Test func aPageBelongsToTheClientThatReportedIt() {
  let table = table([
    (5, hello(11, claude: 10, session: "s1", cwd: "/a")),
    (6, hello(21, claude: 20, session: "s2", cwd: "/b")),
    (5, .page(targetId: "T1", adopted: false)),
    (5, .page(targetId: "T2", adopted: true)),
    (6, .page(targetId: "T3", adopted: false)),
  ])
  #expect(table.client(owning: "T1")?.id == 5)
  #expect(table.client(owning: "T3")?.id == 6)
  #expect(table.client(owning: "T1")?.targets == ["T1", "T2"])
  #expect(table.client(owning: "T1")?.adopted == ["T2"])
  #expect(table.client(owning: "T1")?.cwd == "/a")
  #expect(table.client(owning: "nobody") == nil)
  // The same page announced twice (a reconnect) is still one page.
  var again = table
  again.apply(.page(targetId: "T1", adopted: false), client: 5, at: t0)
  #expect(again == table)
}

@Test func aPageTheWrapperHasNotIntroducedItselfForIsNotTracked() {
  // Messages before a hello have no client to belong to.
  var table = BrowserSessionTable()
  table.apply(.page(targetId: "T1", adopted: false), client: 5, at: t0)
  table.apply(.tool(name: "browser_click", phase: .start), client: 5, at: t0)
  #expect(table == BrowserSessionTable())
  #expect(table.disconnect(client: 5) == [])
}

@Test func aRepeatedHelloOnOneConnectionReplacesTheClient() {
  var table = table([
    (5, hello(11, claude: 10, session: "old", cwd: "/a")),
    (5, .page(targetId: "T1", adopted: false)),
    (5, .tool(name: "browser_click", phase: .start)),
  ])
  table.apply(hello(11, claude: 10, session: "new", cwd: "/a"), client: 5, at: t0)
  let client = table.client(owning: "T1")
  #expect(client == nil, "the pages come again after a hello")
  table.apply(.page(targetId: "T1", adopted: false), client: 5, at: t0)
  #expect(table.client(owning: "T1")?.session == "new")
  #expect(table.client(owning: "T1")?.inFlight == 0)
}

@Test func toolsInFlightCountAndNeverGoBelowZero() throws {
  var table = table([(5, hello(11, claude: 10)), (5, .page(targetId: "T1", adopted: false))])
  func client() throws -> BrowserSessionTable.Client { try #require(table.client(owning: "T1")) }
  #expect(try client().inFlight == 0)
  #expect(try client().lastTool == nil)

  // An end with no start (the wrapper doesn't queue what happened while Studio was away).
  table.apply(.tool(name: "browser_click", phase: .end), client: 5, at: t0)
  #expect(try client().inFlight == 0)

  let t1 = t0.addingTimeInterval(5)
  table.apply(.tool(name: "browser_navigate", phase: .start), client: 5, at: t1)
  table.apply(.tool(name: "browser_click", phase: .start), client: 5, at: t1.addingTimeInterval(1))
  #expect(try client().inFlight == 2)
  #expect(try client().lastTool == t1.addingTimeInterval(1))
  table.apply(.tool(name: "browser_navigate", phase: .end), client: 5, at: t1.addingTimeInterval(2))
  #expect(try client().inFlight == 1)
  table.apply(.tool(name: "browser_click", phase: .end), client: 5, at: t1.addingTimeInterval(3))
  table.apply(.tool(name: "browser_click", phase: .end), client: 5, at: t1.addingTimeInterval(4))
  #expect(try client().inFlight == 0)
  #expect(try client().lastTool == t1.addingTimeInterval(4))
}

@Test func aPageGoneDropsOnlyThatTarget() {
  var table = table([
    (5, hello(11, claude: 10)),
    (5, .page(targetId: "T1", adopted: false)),
    (5, .page(targetId: "T2", adopted: true)),
  ])
  table.apply(.pageGone(targetId: "T2"), client: 5, at: t0)
  #expect(table.client(owning: "T1")?.targets == ["T1"])
  #expect(table.client(owning: "T1")?.adopted == [])
  #expect(table.client(owning: "T2") == nil)
  // A target some other client reported isn't this client's to drop.
  table.apply(.pageGone(targetId: "T9"), client: 5, at: t0)
  #expect(table.client(owning: "T1")?.targets == ["T1"])
}

@Test func disconnectingReturnsExactlyThatClientsTargets() {
  var table = table([
    (5, hello(11, claude: 10)),
    (6, hello(21, claude: 20)),
    (5, .page(targetId: "T1", adopted: false)),
    (5, .page(targetId: "T2", adopted: true)),
    (6, .page(targetId: "T3", adopted: false)),
  ])
  #expect(Set(table.disconnect(client: 5)) == ["T1", "T2"])
  #expect(table.client(owning: "T1") == nil)
  #expect(table.client(owning: "T3")?.id == 6)
  #expect(table.disconnect(client: 5) == [], "already gone")
  #expect(table.disconnect(client: 99) == [], "never there")
  #expect(table.disconnect(client: 6) == ["T3"])
  #expect(table == BrowserSessionTable())
}

@Test func windowsAreFoundByClaudeThenBySession() {
  let table = table([
    (5, hello(11, claude: 10, session: "before-clear")),
    (5, .page(targetId: "T1", adopted: false)),
    (6, hello(21, claude: 20, session: "other")),
    (6, .page(targetId: "T3", adopted: false)),
  ])
  // After /clear the session id changes but the claude process, and so its windows, stay.
  #expect(table.pages(claudePID: 10, session: "after-clear") == ["T1"])
  #expect(table.pages(claudePID: 10, session: nil) == ["T1"])
  // No pid known: the session finds it.
  #expect(table.pages(claudePID: nil, session: "before-clear") == ["T1"])
  #expect(table.pages(claudePID: nil, session: "other") == ["T3"])
  // A pid that owns nothing falls back to the session.
  #expect(table.pages(claudePID: 77, session: "other") == ["T3"])
  // The pid wins over a session that belongs to someone else.
  #expect(table.pages(claudePID: 10, session: "other") == ["T1"])
  #expect(table.pages(claudePID: 77, session: "nobody") == [])
  #expect(table.pages(claudePID: nil, session: nil) == [])
}

@Test func aClientWithNoPagesYetOwnsNone() {
  var table = table([(5, hello(11, claude: 10, session: "s"))])
  #expect(table.pages(claudePID: 10, session: "s") == [])
  #expect(table.disconnect(client: 5) == [])
}

@Test func theSessionSocketMovesToTheTemporaryFolderWhenTheHomePathIsTooLong() {
  let short = BrowserSessionSocket.path(home: "/Users/me", pid: 4121, temporary: "/var/folders/x/T/")
  #expect(short == "/Users/me/Library/Application Support/Glance/agent-browser/sessions/s-4121.sock")
  #expect(short.utf8.count <= BrowserSessionSocket.longestPath)

  // 100 bytes is still fine; 101 is not.
  func home(forPathLength length: Int) -> String {
    let base = BrowserSessionSocket.path(home: "/", pid: 4121, temporary: "/t").utf8.count
    return "/" + String(repeating: "h", count: length - base - 1)
  }
  let edge = BrowserSessionSocket.path(home: home(forPathLength: 100), pid: 4121, temporary: "/var/folders/x/T/")
  #expect(edge.utf8.count == 100 && edge.hasSuffix("/sessions/s-4121.sock"))
  let over = BrowserSessionSocket.path(home: home(forPathLength: 101), pid: 4121, temporary: "/var/folders/x/T/")
  #expect(over == "/var/folders/x/T/glance-sessions/s-4121.sock")
  #expect(BrowserSessionSocket.path(home: home(forPathLength: 140), pid: 7, temporary: "/tmp") == "/tmp/glance-sessions/s-7.sock")
}
