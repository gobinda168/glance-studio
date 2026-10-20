import Foundation
import Testing
@testable import GlanceCore

@Test func thePluginForcesTheStyle() throws {
  let files = HumanizePlugin.files(style: "---\nname: Glance Humanize\nkeep-coding-instructions: true\n---\n\nBody\n")
  #expect(Set(files.keys) == [".claude-plugin/plugin.json", "output-styles/humanize.md"])
  #expect(files["output-styles/humanize.md"] == "---\nforce-for-plugin: true\nname: Glance Humanize\nkeep-coding-instructions: true\n---\n\nBody\n")
  let manifest = try #require(files[".claude-plugin/plugin.json"])
  let json = try JSONSerialization.jsonObject(with: Data(manifest.utf8)) as? [String: Any]
  #expect(json?["name"] as? String == "glance-humanize")
}
