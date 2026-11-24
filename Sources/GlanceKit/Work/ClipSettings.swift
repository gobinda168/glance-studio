import Foundation

/// Command Center (spec 2026-11-01-command-center-design.md §4.2): whether Glance records clips of what Claude does in
/// its browser's session windows (Settings → Browser). On until switched off. Switching it off finishes the clips
/// being recorded, so the recorder listens for `didChange`.
public enum ClipSettings {
  public static let didChange = Notification.Name("dev.glance.settings.recordClipsDidChange")

  private static let key = "recordBrowserClips"

  public static var recordClips: Bool {
    get { Prefs.defaults.object(forKey: key) as? Bool ?? true }
    set {
      guard newValue != recordClips else { return }
      Prefs.defaults.set(newValue, forKey: key)
      NotificationCenter.default.post(name: didChange, object: nil)
    }
  }
}
