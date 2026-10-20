import Foundation
import Testing
@testable import GlanceCore

private let surface = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

@Test func everySurfaceGetsItsIdAndTheLinksFolder() {
  let env = SurfaceClaudeEnvironment.make(surface: surface, linksFolder: "/c/links", style: .claudeDefault,
                                          inheritedPluginDirs: "/c/mods/glance-replies", humanizeDir: "/c/h")
  #expect(env == ["GLANCE_SURFACE_ID": surface.uuidString, "GLANCE_SESSION_LINKS": "/c/links"])
}

@Test func humanizeAddsItsPluginAfterTheInheritedOnes() {
  let env = SurfaceClaudeEnvironment.make(surface: surface, linksFolder: "/c/links", style: .humanize,
                                          inheritedPluginDirs: "/c/mods/glance-replies", humanizeDir: "/c/h")
  #expect(env["CLAUDE_CODE_PLUGIN_DIRS"] == "/c/mods/glance-replies:/c/h")
}

@Test func humanizeWithoutItsPluginAddsNothing() {
  let env = SurfaceClaudeEnvironment.make(surface: surface, linksFolder: "/c/links", style: .humanize,
                                          inheritedPluginDirs: nil, humanizeDir: nil)
  #expect(env["CLAUDE_CODE_PLUGIN_DIRS"] == nil)
}
