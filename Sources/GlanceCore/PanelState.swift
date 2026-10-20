import Foundation

/// What the panel is doing: waiting, Claude is thinking, Glance is reading the reply, or the voice is on.
public enum OrbState: Equatable, Sendable {
  case idle, thinking, reading, speaking, paused
}

/// The words and orb mode the panel shows for a state.
public struct PanelStatus: Equatable, Sendable, Encodable {
  /// The orb's look: `idle`, `thinking`, `reading` or `speaking`.
  public let mode: String
  /// Under "Glance" in the header.
  public let header: String
  /// Under the big orb.
  public let title: String
  public let subtitle: String

  public init(mode: String, header: String, title: String, subtitle: String) {
    self.mode = mode
    self.header = header
    self.title = title
    self.subtitle = subtitle
  }

  public init(state: OrbState, hasReply: Bool) {
    switch state {
    case .idle:
      self.init(mode: "idle", header: hasReply ? "READY" : "WAITING FOR CLAUDE", title: "Idle",
                subtitle: "READY WHEN YOU ARE")
    case .thinking:
      self.init(mode: "thinking", header: "THINKING", title: "Thinking", subtitle: "WORKING ON AN ANSWER")
    case .reading:
      self.init(mode: "reading", header: "READING", title: "Reading", subtitle: "SCANNING THE PAGE")
    case .speaking:
      self.init(mode: "speaking", header: "READING ALOUD", title: "Speaking", subtitle: "READING ALOUD")
    case .paused:
      self.init(mode: "idle", header: "PAUSED", title: "Paused", subtitle: "PRESS PLAY TO CONTINUE")
    }
  }
}

/// The panel's own settings, changed from its settings view and saved between launches.
public struct PanelPrefs: Codable, Equatable, Sendable {
  public enum Theme: String, Codable, Sendable { case dark, light }

  public static let speeds: ClosedRange<Double> = 0.75...1.5

  public var theme: Theme
  /// Voice speed, 0.75× to 1.5×.
  public var speed: Double
  /// Text size: 0 small, 1 medium, 2 large.
  public var size: Int
  /// Draw diagrams piece by piece.
  public var animate: Bool
  /// Dim what hasn't been read yet.
  public var follow: Bool

  public init(theme: Theme = .dark, speed: Double = 1, size: Int = 1, animate: Bool = true, follow: Bool = true) {
    self.theme = theme
    self.speed = speed
    self.size = size
    self.animate = animate
    self.follow = follow
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = PanelPrefs()
    theme = (try? c.decode(Theme.self, forKey: .theme)) ?? d.theme
    speed = (try? c.decode(Double.self, forKey: .speed)) ?? d.speed
    size = (try? c.decode(Int.self, forKey: .size)) ?? d.size
    animate = (try? c.decode(Bool.self, forKey: .animate)) ?? d.animate
    follow = (try? c.decode(Bool.self, forKey: .follow)) ?? d.follow
  }

  /// Keeps values the page sends inside the ranges the controls offer.
  public func clamped() -> PanelPrefs {
    var copy = self
    copy.speed = min(max(speed.isFinite ? speed : 1, Self.speeds.lowerBound), Self.speeds.upperBound)
    copy.size = min(max(size, 0), 2)
    return copy
  }
}
