/// In an editor tab, VS Code gets every key except these, which Glance Studio keeps so tabs and the app work the
/// same everywhere: ⌘T, ⇧⌘E, ⇧⌘L, ⌘1–⌘9, ⇧⌘[ and ⇧⌘], ⌥Space, ⌥., ⌘Q, ⌘H, ⌘M.
public enum EditorShortcuts {
  public struct Key: Equatable, Sendable, CustomStringConvertible {
    /// `NSEvent.charactersIgnoringModifiers`: Shift still applies ("E", "{").
    public let characters: String
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool

    public init(characters: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
      self.characters = characters
      self.command = command
      self.shift = shift
      self.option = option
      self.control = control
    }

    public var description: String {
      (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + characters
    }
  }

  private static let digits: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

  public static func belongsToApp(_ key: Key) -> Bool {
    let c = key.characters.lowercased()
    if key.control { return false }
    if key.option {
      return !key.command && !key.shift && (c == " " || c == ".")
    }
    guard key.command else { return false }
    if key.shift { return ["e", "l", "[", "]", "{", "}"].contains(c) }
    return ["t", "q", "h", "m"].contains(c) || digits.contains(c)
  }
}
