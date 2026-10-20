import Cocoa
import GlanceCore
import GlanceKit
import Sparkle
import SwiftUI

// GLANCE: the update toast (agreed in chat 2026-10-09, after Cursor's "New update available · Later · Install Now"),
// in place of Ghostty's update pill: Sparkle's state as an `UpdateNotice` on GlanceKit's `UpdateToastCard`, at the
// bottom left of every window (`activityStrip()` mounts it). Install Now downloads; the restart waits for Restart Now.

/// The toast's place in a window. It rises in on the spring and leaves faster (MASTER §6), or fades under Reduce
/// Motion; while there's no update news it draws nothing.
struct UpdateToast: View {
    @ObservedObject var model: UpdateViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notice = model.state.notice(terminalsRunning: terminalsRunning, currentVersion: AppVersion.current.short)
        ZStack {
            if let notice {
                UpdateToastCard(notice: notice) { model.perform($0) }
                    .transition(arrival)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.86),
                   value: notice != nil)
    }

    /// Whether a restart would end something running: asked only while the toast offers the restart.
    private var terminalsRunning: Bool {
        switch model.state {
        case .ready, .installing: (NSApp.delegate as? AppDelegate)?.ghostty.needsConfirmQuit ?? false
        default: false
        }
    }

    /// In from 14 pt below through a 6 pt blur; out 6 pt down, faster.
    private var arrival: AnyTransition {
        if reduceMotion { return .opacity.animation(.easeOut(duration: 0.16)) }
        return .asymmetric(
            insertion: .modifier(active: Rise(y: 14, blur: 6, opacity: 0), identity: Rise(y: 0, blur: 0, opacity: 1))
                .animation(.spring(response: 0.42, dampingFraction: 0.86)),
            removal: .modifier(active: Rise(y: 6, blur: 0, opacity: 0), identity: Rise(y: 0, blur: 0, opacity: 1))
                .animation(.easeIn(duration: 0.16)))
    }
}

private struct Rise: ViewModifier {
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(y: y).blur(radius: blur).opacity(opacity)
    }
}

extension UpdateState {
    /// What the toast says for this state; nil when there's nothing to say.
    func notice(terminalsRunning: Bool, currentVersion: String) -> UpdateNotice? {
        switch self {
        case .idle:
            return nil
        case .permissionRequest:
            return UpdateNotice(.permission)
        case .checking:
            return UpdateNotice(.checking)
        case .updateAvailable(let update):
            return UpdateNotice(.available(version: update.appcastItem.versionLabel))
        case .downloading(let download):
            let fraction = download.expectedLength.flatMap { $0 > 0 ? Double(download.progress) / Double($0) : nil }
            return UpdateNotice(.downloading(fraction: fraction))
        case .extracting(let extracting):
            return UpdateNotice(.preparing(fraction: extracting.progress))
        case .ready(let ready):
            return UpdateNotice(.ready(version: ready.appcastItem?.versionLabel, terminalsRunning: terminalsRunning))
        case .installing(let installing):
            // Installed silently for the next quit (auto-update = download): the restart is still the user's call.
            if let item = installing.appcastItem {
                return UpdateNotice(.ready(version: item.versionLabel, terminalsRunning: terminalsRunning))
            }
            return UpdateNotice(.restarting)
        case .notFound:
            return UpdateNotice(.upToDate(version: currentVersion))
        case .error(let error):
            return UpdateNotice(.failed(message: error.error.localizedDescription))
        }
    }
}

extension SUAppcastItem {
    /// "0.1.0 (18512)", the way Settings writes the running version.
    var versionLabel: String { UpdateNotice.versionLabel(display: displayVersionString, build: versionString) }
}

extension UpdateViewModel {
    /// A button on the toast. Later remembers the build (`UpdateLater`) so the hourly checks leave it alone for a day.
    /// A press meant for an earlier step, if the state moved on under the pointer, does nothing.
    func perform(_ action: UpdateNotice.Action, defaults: UserDefaults = .standard, now: Date = Date()) {
        switch (action, state) {
        case (.install, .updateAvailable(let update)):
            update.reply(.install)
        case (.later, .updateAvailable(let update)):
            UpdateLater(build: update.appcastItem.versionString, now: now).save(to: defaults)
            update.reply(.dismiss)
            state = .idle
        case (.restart, .ready(let ready)):
            ready.reply(.install)
        case (.later, .ready(let ready)):
            // Sparkle still installs it when Glance Studio quits.
            if let build = ready.appcastItem?.versionString { UpdateLater(build: build, now: now).save(to: defaults) }
            ready.reply(.dismiss)
            state = .idle
        case (.restart, .installing(let installing)) where installing.appcastItem != nil:
            state.confirm()
        case (.later, .installing(let installing)) where installing.appcastItem != nil:
            // It installs when Glance Studio quits either way.
            state = .idle
        case (.cancel, .checking), (.cancel, .downloading):
            state.cancel()
        case (.retry, .error(let error)):
            error.retry()
        case (.dismiss, .error(let error)):
            error.dismiss()
            state = .idle
        case (.allow, .permissionRequest(let request)), (.notNow, .permissionRequest(let request)):
            request.reply(SUUpdatePermissionResponse(automaticUpdateChecks: action == .allow, sendSystemProfile: false))
        default:
            break
        }
    }
}
