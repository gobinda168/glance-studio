import Foundation

/// A terminal tab's Go to Folder…: the `cd` typed into its shell once a folder is picked.
public enum GoToFolder {
  public static func command(path: String) -> String {
    "cd -- " + AutomationTemplate.shellQuoted(path)
  }

  /// Only at the shell's prompt: with a program in front (Claude Code, vim, a server) the `cd` would land in it.
  public static func canType(runningCommand: String?) -> Bool { runningCommand == nil }
}
