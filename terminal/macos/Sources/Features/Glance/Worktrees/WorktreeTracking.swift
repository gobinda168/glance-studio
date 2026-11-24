import Foundation
import GlanceCore
import GlanceKit

/// Keeps Claude Code's tracking hooks in step with Worktrees (change tracking) and Command Center (proof of work):
/// on while either is on, pointing at this app's `glance` and carrying the flags of the features that are on; off when
/// both are off (spec 2026-10-22-multi-session-worktrees-design.md §5, 2026-11-01-command-center-stage2-proof). Every
/// call rewrites the wrapper script and re-adds the hooks, so an install from an older build (missing an event) or one
/// with other flags is brought up to date.
@MainActor
enum WorktreeTracking {
    static func sync() {
        let options = TrackHookSetup.Options(worktrees: StudioFeatures.shared.isOn(.worktrees),
                                             commandCenter: StudioFeatures.shared.isOn(.commandCenter))
        let on = !options.isEmpty
        let glance = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/glance").path
        ClaudeSettingsQueue.shared.async {
            do {
                try TrackHooks.set(on: on, glance: glance, options: options)
            } catch {
                NSLog("Glance: couldn't \(on ? "add" : "remove") the tracking hooks: \(error.localizedDescription)")
            }
        }
    }
}
