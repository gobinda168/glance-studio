import Foundation

/// Adds and removes Glance's `statusLine` entry in Claude Code's settings JSON. The status line is a single slot, so an
/// existing one is wrapped: Glance's script runs it and prints its output, and `uninstall` puts it back.
public enum StatusLineSetup {
  public struct Installation {
    public var settings: [String: Any]
    /// The user's own `statusLine` that Glance replaced, to save for the script and for `uninstall`. Nil when there was
    /// none, or when Glance's entry was already in place.
    public var original: [String: Any]?
    /// A `statusLine` exists that isn't a command: `settings` is unchanged and there's no usage strip.
    public var unsupported: Bool
  }

  public static func install(into settings: [String: Any], command: String) -> Installation {
    var settings = settings
    guard let existing = settings["statusLine"] else {
      settings["statusLine"] = ["type": "command", "command": command]
      return Installation(settings: settings, original: nil, unsupported: false)
    }
    if isGlance(existing) { return Installation(settings: settings, original: nil, unsupported: false) }
    guard let original = existing as? [String: Any], innerCommand(of: original) != nil else {
      return Installation(settings: settings, original: nil, unsupported: true)
    }
    var entry: [String: Any] = ["type": "command", "command": command]
    for key in ["padding", "refreshInterval"] where original[key] != nil { entry[key] = original[key] }
    settings["statusLine"] = entry
    return Installation(settings: settings, original: original, unsupported: false)
  }

  public static func uninstall(from settings: [String: Any], restoring original: [String: Any]?) -> [String: Any] {
    var settings = settings
    guard isGlance(settings["statusLine"]) else { return settings }
    settings["statusLine"] = original
    return settings
  }

  /// The shell command of a `type: command` status line, if it has one.
  public static func innerCommand(of statusLine: [String: Any]?) -> String? {
    guard let statusLine, statusLine["type"] as? String == "command",
      let command = statusLine["command"] as? String, !command.isEmpty else { return nil }
    return command
  }

  private static func isGlance(_ statusLine: Any?) -> Bool {
    ((statusLine as? [String: Any])?["command"] as? String)?.hasSuffix(HookSetup.marker) ?? false
  }
}
