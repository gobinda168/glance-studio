import CoreGraphics
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
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browser","id":"b1","kind":"test","version":"1.58.2","cdpPort":40001}"#)
    == .browser(id: "b1", kind: .test, version: "1.58.2", cdpPort: 40001))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browser","id":"c","kind":"claude","version":"1.64.1","cdpPort":9}"#)
    == .browser(id: "c", kind: .claude, version: "1.64.1", cdpPort: 9))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"browserGone","id":"b1"}"#) == .browserGone(id: "b1"))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"error","message":"npm failed"}"#) == .error("npm failed"))
  #expect(AgentBrowserEvent.parse(line: #"{"event":"stopped"}"#) == .stopped)
  #expect(AgentBrowserEvent.parse(line: #"{"event":"resumed"}"#) == .resumed)
  for bad in ["", "hello", "{}", #"{"event":"browser","id":"x"}"#, #"{"event":"nope"}"#, #"{"event":"ready"}"#] {
    #expect(AgentBrowserEvent.parse(line: bad) == nil, "\(bad) isn't an event")
  }
}

@Test func thePanelSizeBecomesThePageSize() {
  let fit = AgentBrowserFit.metrics(view: CGSize(width: 640, height: 400), scale: 2)
  #expect(fit.width == 640 && fit.height == 400 && fit.scale == 2)
  let tiny = AgentBrowserFit.metrics(view: CGSize(width: 10, height: 3), scale: 1)
  #expect(tiny.width == 200 && tiny.height == 200)
  let huge = AgentBrowserFit.metrics(view: CGSize(width: 9000, height: 5000.6), scale: 0)
  #expect(huge.width == 4096 && huge.height == 4096 && huge.scale == 1)
}

@Test func framesAreLetterboxedInThePanel() {
  // A 1280×720 page in a 400×400 view: full width, centred vertically.
  let rect = AgentBrowserFit.aspectFit(frame: CGSize(width: 1280, height: 720), in: CGRect(x: 0, y: 0, width: 400, height: 400))
  #expect(rect == CGRect(x: 0, y: 87.5, width: 400, height: 225))
  // A tall page: full height, centred horizontally.
  let tall = AgentBrowserFit.aspectFit(frame: CGSize(width: 390, height: 844), in: CGRect(x: 10, y: 0, width: 844, height: 422))
  #expect(tall.height == 422 && tall.width == 195 && tall.minX == 10 + (844 - 195) / 2)
  #expect(AgentBrowserFit.aspectFit(frame: .zero, in: CGRect(x: 0, y: 0, width: 5, height: 5)) == .zero)
}

@Test func pointsInThePanelMapToThePage() {
  let shown = CGRect(x: 0, y: 87.5, width: 400, height: 225)
  let page = CGSize(width: 1280, height: 720)
  #expect(AgentBrowserFit.pagePoint(CGPoint(x: 200, y: 200), shown: shown, page: page) == CGPoint(x: 640, y: 360))
  #expect(AgentBrowserFit.pagePoint(CGPoint(x: 200, y: 10), shown: shown, page: page) == nil) // in the letterbox
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
