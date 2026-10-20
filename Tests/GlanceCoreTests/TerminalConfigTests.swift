import Testing
@testable import GlanceCore

private let sample = """
# Glance Studio
font-family = JetBrains Mono
font-family = Symbols Nerd Font
font-size = 13
theme = light:Catppuccin Latte,dark:Catppuccin Mocha
# cursor-style = bar
font-size=15

"""

@Test func theLastValueWinsAndCommentsDontCount() {
  let config = TerminalConfig(text: sample)
  #expect(config.value("font-size") == "15")
  #expect(config.value("cursor-style") == nil)
  #expect(config.firstValue("font-family") == "JetBrains Mono")
  #expect(config.value("font-family") == "Symbols Nerd Font")
}

@Test func setReplacesTheLastLineInPlaceAndKeepsTheRest() {
  var config = TerminalConfig(text: sample)
  config.set("font-size", "14")
  #expect(config.text == sample.replacingOccurrences(of: "font-size=15", with: "font-size = 14"))
}

@Test func fontFamilyChangesOnlyTheFirstLineSoFallbacksSurvive() {
  var config = TerminalConfig(text: sample)
  config.set("font-family", "Berkeley Mono", first: true)
  #expect(config.firstValue("font-family") == "Berkeley Mono")
  #expect(config.text.contains("font-family = Symbols Nerd Font"))
}

@Test func aMissingKeyIsAddedAtTheEndBeforeTheFinalNewline() {
  var config = TerminalConfig(text: "font-size = 13\n")
  config.set("cursor-style", "bar")
  #expect(config.text == "font-size = 13\ncursor-style = bar\n")
  var empty = TerminalConfig(text: "")
  empty.set("theme", "Dracula")
  #expect(empty.text == "theme = Dracula\n")
}

@Test func removeTakesEveryLineForTheKey() {
  var config = TerminalConfig(text: sample)
  config.remove("theme")
  #expect(config.value("theme") == nil)
  #expect(config.text.contains("# cursor-style = bar"))
}

@Test func quotedValuesReadWithoutTheirQuotes() {
  #expect(TerminalConfig(text: "theme = \"Rose Pine\"\n").value("theme") == "Rose Pine")
}

@Test func aThemePairReadsAsLightAndDark() {
  #expect(TerminalConfig.themeLabel("light:Catppuccin Latte,dark:Catppuccin Mocha")
    == "Light: Catppuccin Latte · Dark: Catppuccin Mocha")
  #expect(TerminalConfig.themeLabel("Dracula") == "Dracula")
}
