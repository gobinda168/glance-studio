import Testing
@testable import GlanceCore

private func key(_ c: String, cmd: Bool = true, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) -> EditorShortcuts.Key {
  .init(characters: c, command: cmd, shift: shift, option: opt, control: ctrl)
}

@Test func glanceTerminalKeepsItsTabAndAppShortcuts() {
  for k in [key("t"), key("q"), key("h"), key("m"), key("1"), key("9"), key("E", shift: true), key("L", shift: true),
            key("{", shift: true), key("}", shift: true), key("[", shift: true), key("]", shift: true),
            key(" ", cmd: false, opt: true), key(".", cmd: false, opt: true)] {
    #expect(EditorShortcuts.belongsToApp(k), "\(k)")
  }
}

@Test func everythingElseGoesToVSCode() {
  for k in [key("s"), key("p"), key("w"), key("f"), key("P", shift: true), key("F", shift: true), key("0"), key("/"),
            key("t", shift: true), key("e"), key("l"), key("t", ctrl: true), key("1", opt: true),
            key("f", cmd: false, opt: true), key("`", cmd: false, ctrl: true), key("z", cmd: false, opt: true)] {
    #expect(!EditorShortcuts.belongsToApp(k), "\(k)")
  }
}
