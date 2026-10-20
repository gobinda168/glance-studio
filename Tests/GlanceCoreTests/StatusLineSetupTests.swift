import Foundation
import Testing
@testable import GlanceCore

private let command = "'/Users/me/.claude/glance/statusline.sh' # glance"

private func statusLine(_ settings: [String: Any]) -> [String: Any]? { settings["statusLine"] as? [String: Any] }

@Test func installWithoutAnExistingStatusLine() {
  let result = StatusLineSetup.install(into: ["model": "opus"], command: command)
  #expect(result.original == nil)
  #expect(!result.unsupported)
  #expect(result.settings["model"] as? String == "opus")
  #expect(statusLine(result.settings)?["type"] as? String == "command")
  #expect(statusLine(result.settings)?["command"] as? String == command)
}

@Test func installWrapsAnExistingCommandAndKeepsItsOptions() {
  let mine: [String: Any] = ["type": "command", "command": "~/bin/line.sh --fancy 'a b'", "padding": 2, "refreshInterval": 30]
  let result = StatusLineSetup.install(into: ["statusLine": mine], command: command)
  #expect(NSDictionary(dictionary: result.original ?? [:]).isEqual(to: mine))
  let wrapped = statusLine(result.settings)
  #expect(wrapped?["command"] as? String == command)
  #expect(wrapped?["padding"] as? Int == 2)
  #expect(wrapped?["refreshInterval"] as? Int == 30)
  #expect(StatusLineSetup.innerCommand(of: result.original) == "~/bin/line.sh --fancy 'a b'")
}

@Test func installingTwiceDoesNotWrapGlanceItself() {
  let once = StatusLineSetup.install(into: [:], command: command)
  let twice = StatusLineSetup.install(into: once.settings, command: command)
  #expect(twice.original == nil)
  #expect(!twice.unsupported)
  #expect(NSDictionary(dictionary: twice.settings).isEqual(to: once.settings))

  let mine: [String: Any] = ["type": "command", "command": "echo hi"]
  let wrapped = StatusLineSetup.install(into: ["statusLine": mine], command: command)
  let again = StatusLineSetup.install(into: wrapped.settings, command: command)
  #expect(again.original == nil) // the saved original stays the user's, not Glance's own entry
  #expect(NSDictionary(dictionary: again.settings).isEqual(to: wrapped.settings))
}

@Test func anUnsupportedStatusLineIsLeftAlone() {
  let odds: [Any] = [["type": "text", "text": "hi"], ["type": "command"], ["type": "command", "command": ""], "just a string"]
  for odd in odds {
    let settings: [String: Any] = ["statusLine": odd, "model": "opus"]
    let result = StatusLineSetup.install(into: settings, command: command)
    #expect(result.unsupported)
    #expect(result.original == nil)
    #expect(NSDictionary(dictionary: result.settings).isEqual(to: settings))
  }
}

@Test func uninstallRestoresTheOriginalExactly() {
  let mine: [String: Any] = ["type": "command", "command": "~/bin/line.sh", "padding": 0, "refreshInterval": 5]
  let settings: [String: Any] = ["statusLine": mine, "model": "opus"]
  let installed = StatusLineSetup.install(into: settings, command: command)
  let restored = StatusLineSetup.uninstall(from: installed.settings, restoring: installed.original)
  #expect(NSDictionary(dictionary: restored).isEqual(to: settings))
}

@Test func uninstallRemovesGlancesEntryWhenThereWasNoOriginal() {
  let installed = StatusLineSetup.install(into: ["model": "opus"], command: command)
  let out = StatusLineSetup.uninstall(from: installed.settings, restoring: nil)
  #expect(out["statusLine"] == nil)
  #expect(out["model"] as? String == "opus")
}

@Test func uninstallLeavesAForeignStatusLineAlone() {
  let mine: [String: Any] = ["type": "command", "command": "~/bin/line.sh"]
  let out = StatusLineSetup.uninstall(from: ["statusLine": mine], restoring: ["type": "command", "command": "stale"])
  #expect(NSDictionary(dictionary: statusLine(out) ?? [:]).isEqual(to: mine))
}

@Test func innerCommandIsNilWithoutACommand() {
  #expect(StatusLineSetup.innerCommand(of: nil) == nil)
  #expect(StatusLineSetup.innerCommand(of: ["type": "text"]) == nil)
}
