import Foundation
import Testing
@testable import GlanceCore

@Test func playwrightClientsAreKnownByTheirUserAgent() {
  #expect(PlaywrightClientVersion.parse(userAgent: "Playwright/1.58.2 (arm64; macOS 27.0) node/22.19") == "1.58.2")
  #expect(PlaywrightClientVersion.parse(userAgent: "Playwright/1.64.0-alpha-1790635538000 (arm64)") == "1.64.0-alpha-1790635538000")
  #expect(PlaywrightClientVersion.parse(userAgent: "Playwright/1.60.0") == "1.60.0")
  for other in [nil, "", "curl/8.7.1", "node", "Playwright/", "Playwright/latest (x)", "Mozilla/5.0 Playwright/1.2.3"] {
    #expect(PlaywrightClientVersion.parse(userAgent: other) == nil, "\(other ?? "nil") isn't a Playwright client")
  }
}

@Test func brokerLinesBecomeEvents() {
  #expect(AgentBrowserEvent.parse(line: #"{"event":"ready","clientPort":51234,"cdpPort":51235}"#)
    == .ready(clientPort: 51234, cdpPort: 51235))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"installing","what":"Playwright 1.58.2"}"#)
    == .installing(what: "Playwright 1.58.2"))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browser","id":"b1","kind":"test","version":"1.58.2","cdpPort":40001,"pid":812}"#)
    == .browser(id: "b1", kind: .test, version: "1.58.2", cdpPort: 40001, pid: 812))
  // A broker from before real windows sends no pid.
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browser","id":"c","kind":"claude","version":"1.64.1","cdpPort":9}"#)
    == .browser(id: "c", kind: .claude, version: "1.64.1", cdpPort: 9, pid: 0))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browserGone","id":"b1"}"#) == .browserGone(id: "b1"))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"error","message":"npm failed"}"#) == .error("npm failed"))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"stopped"}"#) == .stopped)
  #expect(AgentBrowserEvent.parse(line: #"{"event":"resumed"}"#) == .resumed)
  for bad in ["", "hello", "{}", #"{"event":"browser","id":"x"}"#, #"{"event":"nope"}"#, #"{"event":"ready"}"#] {
    #expect(AgentBrowserEvent.parse(line: bad) == nil, "\(bad) isn't an event")
  }
}

@Test func portsKeepTheSavedPairWhileItIsFree() {
  #expect(AgentBrowserPorts.choose(saved: (9400, 9401), isFree: { _ in true }) == AgentBrowserPorts.Pair(client: 9400, cdp: 9401))
  #expect(AgentBrowserPorts.choose(saved: nil, isFree: { _ in true }) == AgentBrowserPorts.Pair(client: 9322, cdp: 9323))
  // 9323 is taken: the next pair that's free.
  #expect(AgentBrowserPorts.choose(saved: nil, isFree: { $0 != 9323 }) == AgentBrowserPorts.Pair(client: 9324, cdp: 9325))
  // The saved pair is taken: start over from the default.
  #expect(AgentBrowserPorts.choose(saved: (9400, 9401), isFree: { $0 < 9400 }) == AgentBrowserPorts.Pair(client: 9322, cdp: 9323))
  #expect(AgentBrowserPorts.choose(saved: nil, isFree: { _ in false }) == nil)
}

@Test func cdpMessagesRoundTrip() {
  let data = CDPMessage.command(id: 7, method: "Page.navigate", params: ["url": "https://example.com"], sessionId: "S1")
  let json = JSONValue.parse(String(decoding: data, as: UTF8.self))
  #expect(json?["id"]?.int == 7 && json?["method"]?.string == "Page.navigate" && json?["sessionId"]?.string == "S1")
  #expect(json?["params"]?["url"]?.string == "https://example.com")
  let bare = JSONValue.parse(String(decoding: CDPMessage.command(id: 1, method: "Target.getTargets"), as: UTF8.self))
  #expect(bare?["sessionId"] == nil && bare?["params"]?.object?.isEmpty == true)

  #expect(CDPMessage.parse(#"{"id":7,"result":{"frameId":"F"}}"#) == .response(id: 7, result: ["frameId": "F"], error: nil))
  #expect(CDPMessage.parse(#"{"id":8,"error":{"code":-32000,"message":"No target"}}"#)
    == .response(id: 8, result: nil, error: "No target"))
  #expect(CDPMessage.parse(#"{"method":"Page.screencastFrame","params":{"sessionId":3},"sessionId":"S1"}"#)
    == .event(method: "Page.screencastFrame", params: ["sessionId": 3], sessionId: "S1"))
  #expect(CDPMessage.parse("nope") == nil)
}

@Test func packagesLiveInApplicationSupport() {
  #expect(AgentBrowserPackages.folder(home: "/Users/me") == "/Users/me/Library/Application Support/Glance/agent-browser")
  #expect(AgentBrowserPackages.mcpScript(home: "/Users/me")
    == "/Users/me/Library/Application Support/Glance/agent-browser/node_modules/@playwright/mcp/cli.js")
}

@Test func aPageOpensWhenATabAppearsOrGoesSomewhereNew() {
  #expect(AgentBrowserPageOpening.opens(from: nil, to: "about:blank"), "a new tab")
  #expect(AgentBrowserPageOpening.opens(from: "https://a.dev/", to: "https://b.dev/"), "Playwright MCP reuses its one tab")
  #expect(AgentBrowserPageOpening.opens(from: "about:blank", to: "http://localhost:5173/"))
  #expect(AgentBrowserPageOpening.opens(from: "https://a.dev/x", to: "https://a.dev/y"))
  #expect(!AgentBrowserPageOpening.opens(from: "https://a.dev/", to: "https://a.dev/"), "only the title changed")
  #expect(!AgentBrowserPageOpening.opens(from: "https://a.dev/#top", to: "https://a.dev/#end"), "a jump within the page")
}

@Test func browserOptionsReadWhatStudioWrote() throws {
  let home = NSTemporaryDirectory() + "glance-ab-options-\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: home) }
  let file = AgentBrowserOptions.file(home: home)
  #expect(file == AgentBrowserPackages.folder(home: home) + "/options.json")

  // No file yet, an unreadable one and one of the wrong shape all read as the defaults: no session windows.
  #expect(AgentBrowserOptions.read(home: home) == AgentBrowserOptions(sessionWindows: false, socket: nil))
  try FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  for bad in ["", "not json", "[1,2]", #"{"sessionWindows":"yes"}"#, #"{"socket":"/x"}"#] {
    try bad.write(toFile: file, atomically: true, encoding: .utf8)
    #expect(AgentBrowserOptions.read(home: home) == AgentBrowserOptions(sessionWindows: false, socket: nil), "\(bad) isn't options")
  }

  try #"{"sessionWindows":true,"socket":"/tmp/glance/sessions/s.sock"}"#.write(toFile: file, atomically: true, encoding: .utf8)
  #expect(AgentBrowserOptions.read(home: home) == AgentBrowserOptions(sessionWindows: true, socket: "/tmp/glance/sessions/s.sock"))
  // The socket is optional: Studio may not be listening yet.
  try #"{"sessionWindows":true}"#.write(toFile: file, atomically: true, encoding: .utf8)
  #expect(AgentBrowserOptions.read(home: home) == AgentBrowserOptions(sessionWindows: true, socket: nil))
}
