import Foundation
import Testing
@testable import GlanceCore

@Test func onboardingWalksTheStepsInOrderThenFinishes() {
  var flow = OnboardingFlow()
  #expect(flow.phase == .intro)
  flow.begin()
  #expect(flow.phase == .step(.claude))
  #expect(flow.position! == (1, 4))
  flow.next(); flow.next(); flow.next()
  #expect(flow.phase == .step(.accounts))
  flow.next()
  #expect(flow.phase == .finish)
  flow.back()
  #expect(flow.phase == .step(.accounts))
}

@Test func backFromTheFirstStepReturnsToTheIntro() {
  var flow = OnboardingFlow()
  flow.begin()
  flow.back()
  #expect(flow.phase == .intro)
}

@Test func eachFinishedStepLightsItsQuarter() {
  var flow = OnboardingFlow()
  flow.setDone(.permissions, true)
  flow.setDone(.voice, true)
  #expect(flow.litQuarters == [false, true, true, false])
  flow.setDone(.voice, false)
  #expect(flow.litQuarters == [false, true, false, false])
}

@Test func onboardingIsPendingUntilThisVersionIsFinished() {
  #expect(OnboardingFlow.isPending(completedVersion: 0))
  #expect(!OnboardingFlow.isPending(completedVersion: OnboardingFlow.version))
}

@Test func theOrbThinksWhileClaudeIsLookedForAndReadsOnPermissions() {
  #expect(OnboardingStep.claude.mood(checking: true) == .thinking)
  #expect(OnboardingStep.claude.mood(checking: false) == .calm)
  #expect(OnboardingStep.permissions.mood(checking: false) == .reading)
  #expect(OnboardingStep.voice.mood(checking: true) == .calm)
}

@Test func onboardingGreetsByFirstName() {
  #expect(OnboardingFlow.greeting(name: "Gobinda").hasPrefix("Hi Gobinda. I'm Glance."))
  #expect(OnboardingFlow.greeting(name: nil).hasPrefix("Hi. I'm Glance."))
}

@Test func claudeIsSignedInWhenItsConfigHasAnOAuthAccount() {
  let signedIn = #"{"numStartups": 3, "oauthAccount": {"emailAddress": "dev@example.com", "accountUuid": "x"}}"#
  #expect(ClaudeAccount.signedIn(claudeJSON: Data(signedIn.utf8)) == "dev@example.com")
  #expect(ClaudeAccount.signedIn(claudeJSON: Data(#"{"oauthAccount": {"accountUuid": "x"}}"#.utf8)) == "")
  #expect(ClaudeAccount.signedIn(claudeJSON: Data(#"{"numStartups": 3}"#.utf8)) == nil)
  #expect(ClaudeAccount.signedIn(claudeJSON: Data("not json".utf8)) == nil)
}

@Test func claudesVersionIsTheFirstWordOfItsOutput() {
  #expect(ClaudeAccount.version(fromOutput: "2.1.4 (Claude Code)\n") == "2.1.4")
  #expect(ClaudeAccount.version(fromOutput: "command not found") == nil)
}
