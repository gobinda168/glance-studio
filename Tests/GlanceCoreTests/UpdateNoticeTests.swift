import Foundation
import Testing
@testable import GlanceCore

// The update toast's steps (UpdateNotice) and "Later" (UpdateLater).

@Test func anAvailableUpdateOffersLaterBesideInstallNowAndNamesTheVersion() {
  let notice = UpdateNotice(.available(version: "0.1.0 (18512)"))
  #expect(notice.buttons.map(\.action) == [.later, .install])
  #expect(notice.buttons.map(\.role) == [.quiet, .primary])
  #expect(notice.detail == "0.1.0 (18512)")
}

@Test func aBlankVersionLeavesTheDetailOut() {
  #expect(UpdateNotice(.available(version: "  ")).detail == nil)
  #expect(UpdateNotice(.upToDate(version: "")).detail == nil)
}

@Test func aDownloadShowsHowFarItHasGot() {
  let notice = UpdateNotice(.downloading(fraction: 0.42))
  #expect(notice.progress == 0.42)
  #expect(notice.detail == "42%")
  #expect(notice.buttons.map(\.action) == [.cancel])
}

@Test func aDownloadNeverReads100PercentBeforeItIsDone() {
  #expect(UpdateNotice(.downloading(fraction: 0.999)).detail == "99%")
  #expect(UpdateNotice(.downloading(fraction: 1)).detail == "100%")
}

@Test func progressOutsideZeroToOneIsHeldToTheEnds() {
  #expect(UpdateNotice(.downloading(fraction: 1.7)).progress == 1)
  #expect(UpdateNotice(.downloading(fraction: 1.7)).detail == "100%")
  #expect(UpdateNotice(.preparing(fraction: -0.2)).progress == 0)
  #expect(UpdateNotice(.preparing(fraction: -0.2)).detail == "0%")
}

@Test func aDownloadOfUnknownSizeHasNoLineAndNoPercentage() {
  let notice = UpdateNotice(.downloading(fraction: nil))
  #expect(notice.progress == nil)
  #expect(notice.detail == nil)
}

@Test func preparingTheUpdateKeepsTheLineGoing() {
  let notice = UpdateNotice(.preparing(fraction: 0.5))
  #expect(notice.progress == 0.5)
  #expect(notice.detail == "50%")
  #expect(notice.buttons.isEmpty) // Sparkle can't stop an extraction
}

@Test func aReadyUpdateAsksForTheRestartAndOffersLater() {
  let notice = UpdateNotice(.ready(version: "0.1.0 (18512)", terminalsRunning: false))
  #expect(notice.buttons.map(\.action) == [.later, .restart])
  #expect(notice.buttons.map(\.role) == [.quiet, .primary])
  #expect(notice.progress == nil)
}

@Test func aReadyUpdateWarnsOnlyWhenARestartWouldEndRunningTerminals() {
  #expect(UpdateNotice(.ready(version: nil, terminalsRunning: true)).note != nil)
  #expect(UpdateNotice(.ready(version: nil, terminalsRunning: false)).note == nil)
}

@Test func checkingCanBeCancelled() {
  #expect(UpdateNotice(.checking).buttons.map(\.action) == [.cancel])
}

@Test func upToDateAndRestartingOfferNothingToPress() {
  #expect(UpdateNotice(.upToDate(version: "0.1.0 (18412)")).buttons.isEmpty)
  #expect(UpdateNotice(.restarting).buttons.isEmpty)
}

@Test func aFailureSaysWhatWentWrongAndOffersRetry() {
  let notice = UpdateNotice(.failed(message: "The network connection was lost."))
  #expect(notice.note == "The network connection was lost.")
  #expect(notice.buttons.map(\.action) == [.dismiss, .retry])
  #expect(notice.buttons.map(\.role) == [.quiet, .primary])
}

@Test func aFailureWithNoMessageHasNoSecondLine() {
  #expect(UpdateNotice(.failed(message: " \n")).note == nil)
}

@Test func thePermissionQuestionOffersNotNowAndAllow() {
  let notice = UpdateNotice(.permission)
  #expect(notice.buttons.map(\.action) == [.notNow, .allow])
  #expect(notice.buttons.map(\.role) == [.quiet, .primary])
}

@Test func aVersionLabelAddsTheBuildTheWayAboutDoes() {
  #expect(UpdateNotice.versionLabel(display: "0.1.0", build: "18512") == "0.1.0 (18512)")
}

@Test func aVersionLabelWithoutABuildOrAMarketingVersionUsesWhatThereIs() {
  #expect(UpdateNotice.versionLabel(display: "0.1.0", build: "") == "0.1.0")
  #expect(UpdateNotice.versionLabel(display: "0.1.0", build: "0.1.0") == "0.1.0")
  #expect(UpdateNotice.versionLabel(display: "", build: "18512") == "18512")
  #expect(UpdateNotice.versionLabel(display: " ", build: " ") == "")
}

// MARK: Later

private let found = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let hour: TimeInterval = 60 * 60

@Test func laterHidesThatBuildFromTheHourlyChecksForADay() {
  let later = UpdateLater(build: "18512", now: found)
  #expect(later.hides(build: "18512", now: found + 23 * hour, userInitiated: false))
}

@Test func laterLetsTheBuildBackAfterADay() {
  let later = UpdateLater(build: "18512", now: found)
  #expect(!later.hides(build: "18512", now: found + 24 * hour, userInitiated: false))
}

@Test func laterNeverHidesANewerBuild() {
  let later = UpdateLater(build: "18512", now: found)
  #expect(!later.hides(build: "18530", now: found + hour, userInitiated: false))
}

@Test func laterNeverHidesAnUpdateTheUserAskedFor() {
  let later = UpdateLater(build: "18512", now: found)
  #expect(!later.hides(build: "18512", now: found + hour, userInitiated: true))
}

@Test func laterIsRememberedAcrossLaunches() throws {
  let suite = "UpdateNoticeTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  #expect(UpdateLater.load(from: defaults) == nil)

  UpdateLater(build: "18512", now: found).save(to: defaults)
  let reloaded = try #require(UpdateLater.load(from: defaults))
  #expect(reloaded.hides(build: "18512", now: found + 23 * hour, userInitiated: false))
  #expect(!reloaded.hides(build: "18512", now: found + 24 * hour, userInitiated: false))
}
