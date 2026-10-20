import Foundation

/// Whether Claude Code is installed, for controls that need it (the PR inbox disables its Claude buttons without it).
public enum ClaudeCode {
  /// Looked up off the main thread and kept once found; a miss is looked up again next time, in case it was installed
  /// since.
  @MainActor public static func isInstalled(_ done: @escaping @MainActor (Bool) -> Void) {
    ClaudeLocator.locate { done($0 != nil) }
  }
}
