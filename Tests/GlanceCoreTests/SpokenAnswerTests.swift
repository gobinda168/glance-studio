import Testing
@testable import GlanceCore

@Suite struct SpokenAnswerTests {
  private let two = ["Revert", "Fix forward"]

  @Test func aChoiceByItsName() {
    #expect(SpokenAnswer.match("Fix forward.", choices: two, allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("um, let's fix forward", choices: two, allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("REVERT", choices: two, allowText: false) == .choice(0))
  }

  @Test func aChoiceByItsNumber() {
    #expect(SpokenAnswer.match("the second one", choices: two, allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("option one", choices: two, allowText: true) == .choice(0))
    #expect(SpokenAnswer.match("2", choices: two, allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("the last one", choices: ["a", "b", "c"], allowText: true) == .choice(2))
    #expect(SpokenAnswer.match("third", choices: two, allowText: true) == .text("third"))
  }

  @Test func yesAndNoPickBetweenTwo() {
    #expect(SpokenAnswer.match("Yeah.", choices: ["Ship it", "Wait"], allowText: true) == .choice(0))
    #expect(SpokenAnswer.match("nope", choices: ["Ship it", "Wait"], allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("yes", choices: ["a", "b", "c"], allowText: true) == .text("yes"))
  }

  @Test func anythingElseIsTextWhenTextIsAllowed() {
    #expect(SpokenAnswer.match("no idea, ask Riya", choices: ["Yes", "No"], allowText: true) == .text("no idea, ask Riya"))
    #expect(SpokenAnswer.match("no idea, ask Riya", choices: ["Yes", "No"], allowText: false) == .unclear)
    #expect(SpokenAnswer.match("  ", choices: [], allowText: true) == .unclear)
    // Two choices both named: not clear which.
    #expect(SpokenAnswer.match("revert or fix forward", choices: two, allowText: false) == .unclear)
  }

  @Test func permissionsOnlyTakeAClearYesOrNo() {
    #expect(SpokenAnswer.permission("Allow.") == .allow)
    #expect(SpokenAnswer.permission("yes go ahead") == .allow)
    #expect(SpokenAnswer.permission("deny") == .deny)
    #expect(SpokenAnswer.permission("no") == .deny)
    #expect(SpokenAnswer.permission("don't allow") == .unclear)
    #expect(SpokenAnswer.permission("maybe") == .unclear)
    #expect(SpokenAnswer.permission("yes but only in the build folder please") == .unclear)
  }

  @Test func negatedOrHedgedPermissionsAreNeverAnAllow() {
    for said in ["not sure", "I'm not sure", "are you sure", "not okay", "never allow", "not allow", "won't allow",
                 "can't allow", "maybe yes", "wait yes"] {
      #expect(SpokenAnswer.permission(said) == .unclear, "\(said)")
    }
    #expect(SpokenAnswer.permission("sure") == .allow)
    #expect(SpokenAnswer.permission("okay") == .allow)
  }

  @Test func reassurancesAreNotADeny() {
    #expect(SpokenAnswer.permission("no problem") == .unclear)
    #expect(SpokenAnswer.permission("no worries") == .unclear)
  }

  @Test func aNegatedChoiceNameIsNotThatChoice() {
    let ship = ["Ship it", "Wait"]
    #expect(SpokenAnswer.match("don't ship it", choices: ship, allowText: true) == .text("don't ship it"))
    #expect(SpokenAnswer.match("don't ship it", choices: ship, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("don't revert", choices: two, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("never fix forward", choices: two, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("maybe revert", choices: two, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("not the second one", choices: two, allowText: false) == .unclear)
  }

  @Test func bareYesNoNamesNeedTheWholeUtterance() {
    let yn = ["Yes", "No"]
    #expect(SpokenAnswer.match("no idea", choices: yn, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("no clue", choices: yn, allowText: true) == .text("no clue"))
    #expect(SpokenAnswer.match("no problem", choices: yn, allowText: false) == .unclear)
    #expect(SpokenAnswer.match("no worries", choices: yn, allowText: true) == .text("no worries"))
    #expect(SpokenAnswer.match("No.", choices: yn, allowText: false) == .choice(1))
    #expect(SpokenAnswer.match("um, no thanks", choices: yn, allowText: false) == .choice(1))
    #expect(SpokenAnswer.match("yes please", choices: yn, allowText: false) == .choice(0))
  }

  @Test func moreOrdinalsAndFillersInNames() {
    let six = ["a", "b", "c", "d", "e", "f"]
    #expect(SpokenAnswer.match("five", choices: six, allowText: true) == .choice(4))
    #expect(SpokenAnswer.match("the sixth one", choices: six, allowText: true) == .choice(5))
    #expect(SpokenAnswer.match("6", choices: six, allowText: true) == .choice(5))
    #expect(SpokenAnswer.match("too", choices: two, allowText: true) == .choice(1))
    #expect(SpokenAnswer.match("too risky", choices: two, allowText: true) == .text("too risky"))
    #expect(SpokenAnswer.match("well done", choices: ["Well done", "Rare"], allowText: false) == .choice(0))
    #expect(SpokenAnswer.match("done", choices: ["Well done", "Rare"], allowText: false) == .choice(0))
  }
}
