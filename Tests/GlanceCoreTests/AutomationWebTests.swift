import Foundation
import Testing
@testable import GlanceCore

private func route(_ text: String) -> AutomationWeb.Route { AutomationWeb.route(URL(string: text)!) }

@Test func packageFilesAndTheIndexRoute() {
  #expect(route("glance-automation://fix-red-ci/ui/index.html") == .package(id: "fix-red-ci", path: "ui/index.html"))
  #expect(route("glance-automation://fix-red-ci/") == .package(id: "fix-red-ci", path: "ui/index.html"))
  #expect(route("glance-automation://fix-red-ci/ui/app.js?v=2") == .package(id: "fix-red-ci", path: "ui/app.js"))
  #expect(route("glance-automation://fix-red-ci/ui/my%20chart.svg")
    == .package(id: "fix-red-ci", path: "ui/my chart.svg"))
  #expect(route("glance-automation://FIX-RED-CI/ui/index.html") == .package(id: "fix-red-ci", path: "ui/index.html"))
  #expect(AutomationWeb.pageURL("fix-red-ci").absoluteString == "glance-automation://fix-red-ci/ui/index.html")
}

@Test func glancesOwnAssetsRoute() {
  #expect(route("glance-automation://glance/tokens.css") == .asset("tokens.css"))
  #expect(route("glance-automation://glance/glance.js") == .asset("glance.js"))
  #expect(route("glance-automation://glance/fonts/dm-sans.woff2") == .asset("fonts/dm-sans.woff2"))
  #expect(route("glance-automation://glance/fonts/jetbrains-mono.woff2") == .asset("fonts/jetbrains-mono.woff2"))
  // An automation called "glance" keeps every other path of its package.
  #expect(route("glance-automation://glance/ui/index.html") == .package(id: "glance", path: "ui/index.html"))
}

// Review focus: nothing outside the package, however the path is spelled.
@Test func packagePathsNeverLeaveThePackage() {
  for text in ["glance-automation://fix-red-ci/ui/%2e%2e/%2e%2e/approvals.json",
               "glance-automation://fix-red-ci/%2E%2E/other/automation.json",
               "glance-automation://fix-red-ci/ui/..%2F..%2Fapprovals.json",
               "glance-automation://fix-red-ci/ui/..%5C..%5Capprovals.json",
               "glance-automation://fix-red-ci/.git/config",
               "glance-automation://fix-red-ci/ui/.env",
               "glance-automation://fix-red-ci/ui/a%00.html",
               "glance-automation://a.b/ui/index.html"] {
    guard case .refused = route(text) else {
      Issue.record("served \(text)")
      continue
    }
  }
  // "state" is the library's own folder, not an automation.
  guard case .refused = route("glance-automation://state/ui/index.html") else {
    Issue.record("served the state folder")
    return
  }
  #expect(route("https://fix-red-ci/ui/index.html") == .refused("not a glance-automation: address"))
  #expect(AutomationWeb.safePath("ui/./index.html") == nil)
  #expect(AutomationWeb.safePath("/ui//index.html") == "ui/index.html")
}

@Test func insideMeansStrictlyUnder() {
  #expect(AutomationWeb.isInside("/lib/fix/ui/index.html", root: "/lib/fix"))
  #expect(AutomationWeb.isInside("/lib/fix/ui/index.html", root: "/lib/fix/"))
  #expect(!AutomationWeb.isInside("/lib/fix-other/ui/index.html", root: "/lib/fix"))
  #expect(!AutomationWeb.isInside("/lib/fix", root: "/lib/fix"))
  #expect(!AutomationWeb.isInside("/lib/approvals.json", root: "/lib/fix"))
}

@Test func headersCarryTheTypeAndThePolicyOnPages() {
  let page = AutomationWeb.headers(path: "ui/index.html", length: 12)
  #expect(page["Content-Type"] == "text/html; charset=utf-8")
  #expect(page["Content-Length"] == "12")
  #expect(page["Cache-Control"] == "no-store")
  #expect(page["Content-Security-Policy"] == "default-src glance-automation:; style-src glance-automation: "
    + "'unsafe-inline'; script-src glance-automation: 'unsafe-inline'; form-action 'none'; base-uri 'none'; "
    + "object-src 'none'")
  let script = AutomationWeb.headers(path: "ui/app.js", length: 3)
  #expect(script["Content-Type"] == "text/javascript; charset=utf-8")
  // Every response carries the policy: an SVG or XML document can run script too.
  for path in ["ui/app.js", "ui/logo.svg", "ui/page.xhtml", "ui/data.xml", "ui/data.bin", "ui/style.css"] {
    #expect(AutomationWeb.headers(path: path, length: 1)["Content-Security-Policy"]
      == AutomationWeb.contentSecurityPolicy)
  }
  #expect(AutomationWeb.headers(path: "fonts/dm-sans.woff2", length: 1)["Content-Type"] == "font/woff2")
  #expect(AutomationWeb.headers(path: "ui/data.bin", length: 1)["Content-Type"] == "application/octet-stream")
}

@Test func pagesGetThePolicyAsTheirFirstHeadElement() {
  let meta = AutomationWeb.policyMeta
  #expect(meta == #"<meta http-equiv="Content-Security-Policy" content=""# + AutomationWeb.contentSecurityPolicy
    + #"">"#)
  #expect(AutomationWeb.injectingPolicy("<!doctype html><html><head><title>x</title></head></html>")
    == "<!doctype html><html><head>\(meta)<title>x</title></head></html>")
  #expect(AutomationWeb.injectingPolicy("<HTML lang=en><HEAD data-x=\"1\"><header>")
    == "<HTML lang=en><HEAD data-x=\"1\">\(meta)<header>")
  #expect(AutomationWeb.injectingPolicy("<!DOCTYPE html><header>hi</header>")
    == "<!DOCTYPE html>\(meta)<header>hi</header>")
  #expect(AutomationWeb.injectingPolicy("<p>hi</p>") == "\(meta)<p>hi</p>")
}

@Test func tokensCarryTheFontsTheDesignSystemAndABase() {
  let css = AutomationWeb.tokensCSS(designTokens: ":root { --coral: #e8643c; }")
  #expect(css.contains(#"src: url(fonts/dm-sans.woff2) format("woff2")"#))
  #expect(css.contains(#"src: url(fonts/jetbrains-mono.woff2) format("woff2")"#))
  #expect(css.contains(":root { --coral: #e8643c; }"))
  #expect(css.contains("font: var(--fs-body)/var(--lh-body) var(--sans);"))
}

@Test func theRuleListBlocksWebSocketFTPAndFileLoads() {
  guard case .array(let rules)? = AutomationValue.decode(Data(AutomationWeb.blockRules.utf8)) else {
    Issue.record("blockRules isn't a JSON array")
    return
  }
  var filters: [String] = []
  for rule in rules {
    #expect(rule.object?["action"] == .object(["type": .string("block")]))
    if case .string(let filter)? = rule.object?["trigger"]?.object?["url-filter"] { filters.append(filter) }
  }
  #expect(filters == ["^https?:", "^wss?:", "^ftp:", "^file:"])
  // WebKit's rule compiler takes a subset of regex: no disjunction, no counted repeats, no groups, no backreferences.
  for filter in filters {
    for unsupported in ["|", "{", "(", ")", "\\"] {
      #expect(!filter.contains(unsupported), "\(filter) has \(unsupported)")
    }
  }
}
