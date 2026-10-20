/// The apps Glance docks to: terminals, and editors with a built-in terminal where Claude Code runs. Glance Studio is not
/// listed: it has the pane built in.
public enum TerminalApps {
  public struct App: Equatable, Sendable {
    public let name: String
    public let bundleID: String
    /// A code editor: Glance shows as an orb over the editor with a popover, not a panel docked over its right side
    /// (where Claude Code's side bar lives).
    public var isEditor = false
  }

  public static let all: [App] = [
    App(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
    App(name: "Warp Preview", bundleID: "dev.warp.Warp-Preview"),
    App(name: "Terminal", bundleID: "com.apple.Terminal"),
    App(name: "iTerm2", bundleID: "com.googlecode.iterm2"),
    App(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
    App(name: "WezTerm", bundleID: "com.github.wez.wezterm"),
    App(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
    App(name: "Alacritty", bundleID: "org.alacritty"),
    App(name: "Hyper", bundleID: "co.zeit.hyper"),
    App(name: "Tabby", bundleID: "org.tabby"),
    App(name: "Wave", bundleID: "dev.commandline.waveterm"),
    App(name: "Rio", bundleID: "com.raphaelamorim.rio"),
    App(name: "VS Code", bundleID: "com.microsoft.VSCode", isEditor: true),
    App(name: "VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", isEditor: true),
    App(name: "VSCodium", bundleID: "com.vscodium", isEditor: true),
    App(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", isEditor: true),
    App(name: "Windsurf", bundleID: "com.exafunction.windsurf", isEditor: true),
    App(name: "Zed", bundleID: "dev.zed.Zed", isEditor: true),
  ]

  public static func app(for bundleID: String?) -> App? {
    all.first { $0.bundleID == bundleID }
  }

  public static func isSupported(_ bundleID: String?) -> Bool {
    app(for: bundleID) != nil
  }

  public static func isEditor(_ bundleID: String?) -> Bool {
    app(for: bundleID)?.isEditor ?? false
  }
}
