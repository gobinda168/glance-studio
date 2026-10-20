import Foundation

/// How Glance Studio shows the Glance pane: as a sidebar on the right of the window, or as an orb floating over the
/// terminal that opens the panel as a card. The pin in the panel's header cycles the mode.
public enum PaneLayout {
  public enum Mode: String, CaseIterable, Sendable {
    /// The sidebar in wide windows, the orb in narrow ones.
    case auto
    /// Always the sidebar.
    case pinned
    /// Always the orb.
    case floating

    public init(saved: String?) {
      self = saved.flatMap(Mode.init(rawValue:)) ?? .auto
    }

    /// The pin's next state: auto → pinned → floating → auto.
    public var next: Mode {
      switch self {
      case .auto: .pinned
      case .pinned: .floating
      case .floating: .auto
      }
    }
  }

  public enum Placement: Sendable {
    case sidebar
    case floating
  }

  /// The pane's usual width.
  public static let paneWidth: Double = 460
  /// How narrow and how wide the sidebar can be dragged (its left edge).
  public static let minSidebarWidth: Double = 320
  public static let maxSidebarWidth: Double = 720

  /// The sidebar's width from the saved one: clamped, or the usual width when there's none.
  public static func sidebarWidth(_ saved: Double?) -> Double {
    guard let saved, saved.isFinite, saved > 0 else { return paneWidth }
    return min(maxSidebarWidth, max(minSidebarWidth, saved))
  }
  /// The terminal keeps at least this much beside the sidebar, or auto floats the pane instead.
  public static let minTerminalWidth: Double = 800
  /// Auto switches only this far past the threshold, so dragging a window edge near it doesn't flicker.
  public static let hysteresis: Double = 20

  /// Where the pane goes. `width` is what the terminal and the sidebar share (the window without the tab sidebar);
  /// `current` is where it is now. While `reading` (a summary is open) the pane is the sidebar whatever the mode
  /// (spec 2026-10-11-humanize-summaries-design.md, "A fixed right side for reading").
  public static func placement(mode: Mode, width: Double, current: Placement?, reading: Bool = false) -> Placement {
    if reading { return .sidebar }
    switch mode {
    case .pinned: return .sidebar
    case .floating: return .floating
    case .auto:
      guard width.isFinite, width > 0 else { return current ?? .sidebar }
      let threshold = paneWidth + minTerminalWidth
      switch current {
      case .sidebar: return width > threshold - hysteresis ? .sidebar : .floating
      case .floating: return width >= threshold + hysteresis ? .sidebar : .floating
      case nil: return width >= threshold ? .sidebar : .floating
      }
    }
  }
}
