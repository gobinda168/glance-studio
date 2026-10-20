import Testing
@testable import GlanceCore

@Test func recognisesThePopularTerminalsAndEditors() {
  for id in ["dev.warp.Warp-Stable", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
             "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode"] {
    #expect(TerminalApps.isSupported(id), "\(id)")
  }
}

@Test func ignoresOtherAppsAndMissingIDs() {
  #expect(!TerminalApps.isSupported("com.apple.Safari"))
  #expect(!TerminalApps.isSupported(nil))
  #expect(!TerminalApps.isSupported(""))
}

@Test func namesATerminalByItsBundleID() {
  #expect(TerminalApps.app(for: "com.googlecode.iterm2")?.name == "iTerm2")
  #expect(TerminalApps.app(for: "com.apple.Safari") == nil)
}

@Test func bundleIDsAreUnique() {
  let ids = TerminalApps.all.map(\.bundleID)
  #expect(Set(ids).count == ids.count)
}

@Test func editorsGetTheOrbAndTerminalsTheDockedPanel() {
  for id in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed", "com.vscodium"] {
    #expect(TerminalApps.isEditor(id), "\(id)")
  }
  for id in ["dev.warp.Warp-Stable", "com.googlecode.iterm2", "com.mitchellh.ghostty"] {
    #expect(!TerminalApps.isEditor(id), "\(id)")
  }
  #expect(!TerminalApps.isEditor(nil))
}

@Test func glanceStudioIsNotSomethingTheOverlayDocksTo() {
  #expect(TerminalApps.app(for: "dev.glance.Terminal") == nil)
  #expect(!TerminalApps.isSupported("dev.glance.Terminal"))
  #expect(!TerminalApps.isEditor("dev.glance.Terminal"))
}
