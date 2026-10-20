import Testing
@testable import GlanceCore

@Test func readsAThemesColoursWithOrWithoutTheHash() {
  let theme = TerminalTheme(name: "Mocha", text: """
  palette = 0=#45475a
  palette = 1=f38ba8
  background = 1e1e2e
  foreground = #CDD6F4
  cursor-color = f5e0dc
  # a comment
  """)
  #expect(theme.background == "#1e1e2e")
  #expect(theme.foreground == "#cdd6f4")
  #expect(theme.palette[0] == "#45475a")
  #expect(theme.palette[1] == "#f38ba8")
  #expect(theme.palette[2] == nil)
  #expect(theme.palette.count == 16)
  #expect(theme.isDark)
  #expect(theme.hasColors)
}

@Test func aLightBackgroundIsLightAndOddFilesStillLoad() {
  #expect(!TerminalTheme(name: "Latte", text: "background = #eff1f5").isDark)
  let odd = TerminalTheme(name: "Odd", text: "palette = 99=#ffffff\nbackground = not-a-colour\nwhatever")
  #expect(!odd.hasColors)
  #expect(odd.palette.allSatisfy { $0 == nil })
}

@Test func hexTurnsIntoComponents() {
  let rgb = TerminalTheme.rgb("#ff8000")
  #expect(rgb?.red == 1)
  #expect(rgb?.blue == 0)
  #expect(TerminalTheme.rgb("zzz") == nil)
  #expect(TerminalTheme.defaultPalette.count == 16)
}

@Test func theDefaultPaletteIsTheTerminalsOwn() {
  // src/terminal/color.zig's Name.default: what the terminal shows without a theme, which the preview draws.
  #expect(TerminalTheme.defaultPalette[0] == "#1d1f21")
  #expect(TerminalTheme.defaultPalette[1] == "#cc6666")
  #expect(TerminalTheme.defaultPalette[2] == "#b5bd68")
  #expect(TerminalTheme.defaultPalette[15] == "#eaeaea")
}
