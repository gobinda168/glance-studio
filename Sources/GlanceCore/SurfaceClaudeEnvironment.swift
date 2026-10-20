import Foundation

/// What a Studio terminal's shell gets for Claude Code (spec 2026-10-11-humanize-summaries-design.md, "Session
/// isolation" and "Glance Humanize"): its own id and the folder its `SessionStart` hook writes the session link to,
/// and with Humanize on, the Humanize plugin after the plugin folders every shell inherits.
public enum SurfaceClaudeEnvironment {
  public static let surfaceKey = "GLANCE_SURFACE_ID"
  public static let linksKey = "GLANCE_SESSION_LINKS"

  public static func make(surface: UUID, linksFolder: String, style: ResponseStyle, inheritedPluginDirs: String?,
                          humanizeDir: String?) -> [String: String] {
    var environment = [surfaceKey: surface.uuidString, linksKey: linksFolder]
    if style == .humanize, let humanizeDir,
       let dirs = ClaudeMods.pluginDirs(adding: [URL(fileURLWithPath: humanizeDir)], to: inheritedPluginDirs) {
      environment[ClaudeMods.pluginDirsKey] = dirs
    }
    return environment
  }
}
