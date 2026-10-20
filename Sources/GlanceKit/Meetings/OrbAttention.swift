import AppKit
import GlanceCore

/// What every orb shares beyond the panel's status (spec 2026-10-08-meeting-nudges-design.md, "Orb meeting mode"): a
/// meeting is due so the orbs show `meeting`; where the visible orbs are, for the nudge's card; and a click on any orb
/// while a meeting is due, which brings its card back.
@MainActor
public enum OrbAttention {
  public static let changed = Notification.Name("dev.glance.orbAttention")
  public private(set) static var meeting = false
  /// Notification cards are showing: the orbs glow as for a meeting.
  public private(set) static var notice = false
  /// A Tickets card (the morning top 3, the check-in) is showing: the orbs glow as for a meeting.
  public private(set) static var card = false
  static var onOrbClick: (() -> Bool)?
  /// The oldest pending Claude prompt's caption ("my-app needs you: Bash command"); the orbs show `waiting`.
  public private(set) static var prompt: String?
  /// A click on any orb while a prompt is pending opens its card (spec 2026-10-11-needs-input-orb-design.md §2).
  public static var onPromptClick: (() -> Void)?

  private final class Entry {
    weak var orb: AnyObject?
    let frame: () -> NSRect?

    init(orb: AnyObject, frame: @escaping () -> NSRect?) {
      self.orb = orb
      self.frame = frame
    }
  }

  private static var entries: [Entry] = []

  /// The orb channel's mode (`ChannelBook.orbMode`): listening, waiting, error, working, speaking, done; nil leaves
  /// the orb to the panel.
  public private(set) static var channelMode: String?
  /// What the latest session said it's doing ("glance: Running tests"), for the orb's tooltip.
  public private(set) static var caption: String?

  /// The mode an orb shows for the panel's `mode`: fn held for the channel first, then a pending Claude prompt, then a
  /// meeting (or notification / Tickets cards), then the channel, then the panel (`OrbModes.pick`).
  public static func mode(_ panelMode: String) -> String {
    OrbModes.pick(panel: panelMode, channel: channelMode, attention: meeting || notice || card, prompt: prompt != nil)
  }

  public static func setPrompt(_ caption: String?) {
    guard caption != prompt else { return }
    prompt = caption
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// The orbs' tooltip: a pending prompt first, then the channel's caption.
  public static var tooltip: String? { prompt ?? caption }

  /// Some Glance orb (Studio's, the editor orb) is on screen; the floating orb stays away then.
  public static var anyOrbVisible: Bool { !visibleOrbFrames.isEmpty }

  static func setChannel(mode: String?, caption: String?) {
    guard mode != channelMode || caption != self.caption else { return }
    channelMode = mode
    self.caption = caption
    NotificationCenter.default.post(name: changed, object: nil)
  }

  static func setMeeting(_ on: Bool) {
    guard on != meeting else { return }
    meeting = on
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// Notification cards came or went (`NudgeStack`): the orbs show `meeting` while any shows. A meeting under way
  /// already has them there, so only a change the orbs can see is posted.
  static func setNotice(_ on: Bool) {
    guard on != notice else { return }
    notice = on
    guard !meeting else { return }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// A Tickets card came or went (`TicketsCard`): as `setNotice`, posted only when the orbs can see the change.
  static func setCard(_ on: Bool) {
    guard on != card else { return }
    card = on
    guard !meeting, !notice else { return }
    NotificationCenter.default.post(name: changed, object: nil)
  }

  /// An orb reports its body's frame in screen coordinates (nil while it can't be seen), for as long as it lives.
  public static func register(_ orb: AnyObject, frame: @escaping () -> NSRect?) {
    entries.removeAll { $0.orb == nil || $0.orb === orb }
    entries.append(Entry(orb: orb, frame: frame))
  }

  static var visibleOrbFrames: [NSRect] {
    entries.filter { $0.orb != nil }.compactMap { $0.frame() }
  }

  /// An orb was clicked: true when a prompt card or the meeting nudge took the click.
  public static func orbClicked() -> Bool {
    if prompt != nil, let onPromptClick {
      onPromptClick()
      return true
    }
    return onOrbClick?() ?? false
  }
}
