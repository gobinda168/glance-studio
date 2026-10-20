/// The Claude Code plugin that brings Glance Humanize to a Studio terminal (spec 2026-10-11-humanize-summaries-design.md,
/// "Amendments"): the style file as a plugin output style with `force-for-plugin`, so a `claude` started there uses it
/// with no `/output-style` step. Studio writes it to Caches at launch; only surfaces set to Humanize load it.
public enum HumanizePlugin {
  public static let name = "glance-humanize"

  /// Relative path → contents.
  public static func files(style markdown: String) -> [String: String] {
    [".claude-plugin/plugin.json":
      #"{"name":"glance-humanize","version":"1.0.0","description":"Glance Humanize: Glance Studio's response style"}"#,
     "output-styles/humanize.md": forced(markdown)]
  }

  /// The style with `force-for-plugin: true` as its first front-matter field.
  static func forced(_ markdown: String) -> String {
    guard markdown.hasPrefix("---\n") else { return markdown }
    return "---\nforce-for-plugin: true\n" + markdown.dropFirst(4)
  }
}
