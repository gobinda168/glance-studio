import AppKit
import Foundation

/// The orb channel's switches (Settings → Orb Channel, spec 2026-10-09-orb-channel-design.md).
extension Prefs {
  /// Claude sessions can reach the user (the socket listens).
  public static var orbChannelEnabled: Bool {
    get { defaults.object(forKey: "orbChannelEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "orbChannelEnabled") }
  }

  /// Studio starts `claude` with its channel, so Glance can message it; Claude asks to confirm "local development" once
  /// per launch, so it's off until the user turns it on.
  public static var orbChannelLaunchFlag: Bool {
    get { defaults.object(forKey: "orbChannelLaunchFlag") as? Bool ?? false }
    set { defaults.set(newValue, forKey: "orbChannelLaunchFlag") }
  }

  /// Sessions' `speak` is heard.
  public static var orbChannelSessionsSpeak: Bool {
    get { defaults.object(forKey: "orbChannelSessionsSpeak") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "orbChannelSessionsSpeak") }
  }

  /// Questions are read aloud when they arrive.
  public static var orbChannelReadQuestions: Bool {
    get { defaults.object(forKey: "orbChannelReadQuestions") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "orbChannelReadQuestions") }
  }

  /// Sessions' permission prompts come to the orb as cards.
  public static var orbChannelApprovals: Bool {
    get { defaults.object(forKey: "orbChannelApprovals") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "orbChannelApprovals") }
  }

  public static var orbAssistantEnabled: Bool {
    get { defaults.object(forKey: "orbAssistantEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "orbAssistantEnabled") }
  }

  /// The key held with fn to talk to the assistant from anywhere: "control", "option" or "shift".
  public static var orbAssistantModifier: String {
    get { defaults.string(forKey: "orbAssistantModifier") ?? "control" }
    set { defaults.set(newValue, forKey: "orbAssistantModifier") }
  }

  static var orbAssistantFlag: NSEvent.ModifierFlags {
    switch orbAssistantModifier {
    case "option": .option
    case "shift": .shift
    default: .control
    }
  }

  /// The assistant's conversation and when it was last used (a new one after 15 idle minutes).
  static var orbAssistantSession: String? {
    get { defaults.string(forKey: "orbAssistantSession") }
    set { defaults.set(newValue, forKey: "orbAssistantSession") }
  }

  static var orbAssistantLastUse: Date? {
    get { defaults.object(forKey: "orbAssistantLastUse") as? Date }
    set { defaults.set(newValue, forKey: "orbAssistantLastUse") }
  }
}
