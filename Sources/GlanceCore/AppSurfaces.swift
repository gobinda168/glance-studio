/// What the one app runs: the built-in terminal (Dock icon, windows, tabs, editor, Home) and the overlay on other
/// terminals (menu-bar item, docking, editor orb, hook server). Settings has a switch for each.
public struct AppSurfaces: Equatable, Sendable {
  public var terminal: Bool
  public var overlay: Bool

  public init(terminal: Bool = true, overlay: Bool = true) {
    self.terminal = terminal
    self.overlay = overlay
  }

  public enum Policy: Equatable, Sendable { case regular, accessory }

  /// A Dock icon only with the terminal on (and Ghostty's `macos-hidden = always` not asking to hide it).
  public func activationPolicy(configHidesApp: Bool) -> Policy {
    terminal && !configHidesApp ? .regular : .accessory
  }

  /// A terminal window opens at launch (and when the switch comes on with none open).
  public var opensWindowAtLaunch: Bool { terminal }

  public enum Reopen: Equatable, Sendable {
    /// The terminal's own reopen handling (focus a window, or make one).
    case showTerminal
    case showOverlay
    case showSettings
  }

  /// Opening the app again (Spotlight, Finder, Dock).
  public func reopen() -> Reopen { terminal ? .showTerminal : (overlay ? .showOverlay : .showSettings) }

  public enum HotkeyTarget: Equatable, Sendable { case studioWindow, overlay, none }

  /// ⌥Space and ⌥. are system-wide, so the overlay (their owner) passes them to Studio's window when Studio is in front.
  public func hotkeyTarget(studioFront: Bool) -> HotkeyTarget {
    if studioFront && terminal { return .studioWindow }
    return overlay ? .overlay : .none
  }

  public enum DictationRoute: Equatable, Sendable {
    /// Written into the focused terminal split.
    case studioTerminal
    /// Typed into whatever app has focus, through Accessibility.
    case frontApp
    case none
  }

  /// Where a fn hold's text goes. With Studio in front on a Home or editor tab there is nowhere to put it.
  public func dictationRoute(appActive: Bool, studioHasFocusedTerminal: Bool) -> DictationRoute {
    if appActive && terminal { return studioHasFocusedTerminal ? .studioTerminal : .none }
    return overlay ? .frontApp : .none
  }

  /// With the terminal off, the app in front can only be Settings: the panel stays up.
  /// With the terminal on, the app in front is Studio, which has its own pane.
  public var treatsOwnAppAsFront: Bool { !terminal }

  public var showsTerminalCards: Bool { terminal }
  public var showsOverlayCards: Bool { overlay }
}
