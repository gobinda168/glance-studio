import Testing
import Foundation
import GlanceCore
import Sparkle
@testable import Ghostty

/// The update toast's side of Sparkle (GLANCE, 2026-10-09): what each state shows, and what each button tells Sparkle.
struct UpdateToastTests {
    private func item(_ display: String, _ build: String) -> SUAppcastItem {
        let item = SUAppcastItem.empty()
        item.setValue(display, forKey: "_displayVersionString")
        item.setValue(build, forKey: "_versionString")
        return item
    }

    private func scratchDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "UpdateToastTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    /// Collects what Sparkle was told (its reply closures are @Sendable, so not a captured var).
    private final class Log<T>: @unchecked Sendable {
        var items: [T] = []
    }

    // MARK: - What it shows

    @Test func idleShowsNothing() {
        #expect(UpdateState.idle.notice(terminalsRunning: false, currentVersion: "0.1.0 (18412)") == nil)
    }

    @Test func anAvailableUpdateNamesItsVersionAndBuild() {
        let state = UpdateState.updateAvailable(.init(appcastItem: item("0.1.0", "18512"), reply: { _ in }))
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.detail == "0.1.0 (18512)")
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.buttons.map(\.action) == [.later, .install])
    }

    @Test func aDownloadOfKnownSizeShowsItsProgress() {
        let state = UpdateState.downloading(.init(cancel: {}, expectedLength: 1000, progress: 250))
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.progress == 0.25)
    }

    @Test func aDownloadOfUnknownOrZeroSizeShowsNoProgress() {
        let unknown = UpdateState.downloading(.init(cancel: {}, expectedLength: nil, progress: 250))
        let zero = UpdateState.downloading(.init(cancel: {}, expectedLength: 0, progress: 250))
        #expect(unknown.notice(terminalsRunning: false, currentVersion: "")?.progress == nil)
        #expect(zero.notice(terminalsRunning: false, currentVersion: "")?.progress == nil)
    }

    @Test func aDownloadedUpdateAsksForTheRestartAndWarnsAboutRunningTerminals() {
        let state = UpdateState.ready(.init(appcastItem: item("0.1.0", "18512"), reply: { _ in }))
        let notice = state.notice(terminalsRunning: true, currentVersion: "")
        #expect(notice?.buttons.map(\.action) == [.later, .restart])
        #expect(notice?.detail == "0.1.0 (18512)")
        #expect(notice?.note != nil)
    }

    @Test func anUpdateInstalledSilentlyOnQuitAlsoAsksForTheRestart() {
        let state = UpdateState.installing(.init(appcastItem: item("0.1.0", "18512"), retryTerminatingApplication: {}))
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.buttons.map(\.action) == [.later, .restart])
    }

    @Test func anInstallUnderWayOffersNothing() {
        let state = UpdateState.installing(.init(retryTerminatingApplication: {}))
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.buttons == [])
    }

    @Test func upToDateNamesTheRunningVersion() {
        let state = UpdateState.notFound(.init(acknowledgement: {}))
        #expect(state.notice(terminalsRunning: false, currentVersion: "0.1.0 (18412)")?.detail == "0.1.0 (18412)")
    }

    @Test func aFailureCarriesSparklesMessage() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "The update is improperly signed."])
        let state = UpdateState.error(.init(error: error, retry: {}, dismiss: {}))
        #expect(state.notice(terminalsRunning: false, currentVersion: "")?.note == "The update is improperly signed.")
    }

    // MARK: - What the buttons do

    @Test func installNowStartsTheDownload() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let replies = Log<SPUUserUpdateChoice>()
        let model = UpdateViewModel()
        model.state = .updateAvailable(.init(appcastItem: item("0.1.0", "18512"), reply: { replies.items.append($0) }))
        model.perform(.install, defaults: defaults)
        #expect(replies.items == [.install])
    }

    @Test func laterOnAnAvailableUpdateDismissesItAndHidesThatBuildForADay() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let replies = Log<SPUUserUpdateChoice>()
        let model = UpdateViewModel()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        model.state = .updateAvailable(.init(appcastItem: item("0.1.0", "18512"), reply: { replies.items.append($0) }))
        model.perform(.later, defaults: defaults, now: now)
        #expect(replies.items == [.dismiss])
        #expect(model.state == .idle)
        let later = try #require(UpdateLater.load(from: defaults))
        #expect(later.hides(build: "18512", now: now + 60 * 60, userInitiated: false))
    }

    @Test func restartNowInstallsTheDownloadedUpdate() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let replies = Log<SPUUserUpdateChoice>()
        let model = UpdateViewModel()
        model.state = .ready(.init(appcastItem: item("0.1.0", "18512"), reply: { replies.items.append($0) }))
        model.perform(.restart, defaults: defaults)
        #expect(replies.items == [.install])
    }

    @Test func laterOnADownloadedUpdateLeavesItForTheNextQuitAndHidesItForADay() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let replies = Log<SPUUserUpdateChoice>()
        let model = UpdateViewModel()
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        model.state = .ready(.init(appcastItem: item("0.1.0", "18512"), reply: { replies.items.append($0) }))
        model.perform(.later, defaults: defaults, now: now)
        #expect(replies.items == [.dismiss])
        #expect(model.state == .idle)
        #expect(UpdateLater.load(from: defaults)?.hides(build: "18512", now: now + 60, userInitiated: false) == true)
    }

    @Test func restartNowOnASilentlyInstalledUpdateRelaunches() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        var relaunched = 0
        let model = UpdateViewModel()
        model.state = .installing(.init(appcastItem: item("0.1.0", "18512"), retryTerminatingApplication: { relaunched += 1 }))
        model.perform(.restart, defaults: defaults)
        #expect(relaunched == 1)
    }

    @Test func laterOnASilentlyInstalledUpdateOnlyHidesTheToast() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        var relaunched = 0
        let model = UpdateViewModel()
        model.state = .installing(.init(appcastItem: item("0.1.0", "18512"), retryTerminatingApplication: { relaunched += 1 }))
        model.perform(.later, defaults: defaults)
        #expect(relaunched == 0)
        #expect(model.state == .idle)
    }

    @Test func cancelStopsACheckOrADownload() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        var cancelled = 0
        let model = UpdateViewModel()
        model.state = .checking(.init(cancel: { cancelled += 1 }))
        model.perform(.cancel, defaults: defaults)
        model.state = .downloading(.init(cancel: { cancelled += 1 }, expectedLength: 10, progress: 5))
        model.perform(.cancel, defaults: defaults)
        #expect(cancelled == 2)
    }

    @Test func retryAndDismissReachSparkle() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        var retried = 0
        var dismissed = 0
        let model = UpdateViewModel()
        let error = NSError(domain: "test", code: 1)
        model.state = .error(.init(error: error, retry: { retried += 1 }, dismiss: { dismissed += 1 }))
        model.perform(.retry, defaults: defaults)
        model.state = .error(.init(error: error, retry: { retried += 1 }, dismiss: { dismissed += 1 }))
        model.perform(.dismiss, defaults: defaults)
        #expect(retried == 1)
        #expect(dismissed == 1)
        #expect(model.state == .idle)
    }

    @Test func allowTurnsOnAutomaticChecks() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let answers = Log<Bool>()
        let model = UpdateViewModel()
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        model.state = .permissionRequest(.init(request: request, reply: { answers.items.append($0.automaticUpdateChecks) }))
        model.perform(.allow, defaults: defaults)
        model.state = .permissionRequest(.init(request: request, reply: { answers.items.append($0.automaticUpdateChecks) }))
        model.perform(.notNow, defaults: defaults)
        #expect(answers.items == [true, false])
    }

    @Test func aButtonFromAnOlderStepDoesNothing() throws {
        let (defaults, clean) = try scratchDefaults()
        defer { clean() }
        let replies = Log<SPUUserUpdateChoice>()
        let model = UpdateViewModel()
        model.state = .updateAvailable(.init(appcastItem: item("0.1.0", "18512"), reply: { replies.items.append($0) }))
        model.perform(.restart, defaults: defaults)
        #expect(replies.items.isEmpty)
    }

    // MARK: - Up to date fades

    @MainActor @Test func upToDateFadesOnItsOwn() async throws {
        var acknowledged = 0
        let model = UpdateViewModel()
        model.upToDateFade = .milliseconds(30)
        model.state = .notFound(.init(acknowledgement: { acknowledged += 1 }))
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.state == .idle)
        #expect(acknowledged == 1)
    }
}
