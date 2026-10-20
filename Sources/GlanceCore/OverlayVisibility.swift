/// When the overlay's docked panel is on screen.
public enum OverlayVisibility {
  /// A reply (or ⌥Space, or the orb) asked for the panel: it shows over the terminal or editor in front, or over any
  /// app when the hot key forced it. With "Show Glance over terminals" on, a terminal in front shows it without a reply,
  /// unless it was closed since the last one; editors keep their orb.
  public static func showsPanel(wantsVisible: Bool, terminalFront: Bool, forcedByHotkey: Bool, overEditor: Bool,
                                alwaysOverTerminals: Bool, dismissed: Bool) -> Bool {
    if wantsVisible && (terminalFront || forcedByHotkey) { return true }
    return alwaysOverTerminals && terminalFront && !overEditor && !dismissed
  }
}
