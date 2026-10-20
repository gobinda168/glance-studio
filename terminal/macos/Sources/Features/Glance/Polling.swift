import AppKit

/// A repeating refresh that sleeps while Glance is behind another app and reads once when it comes back, so a
/// background window costs no network or `gh` processes.
@MainActor
enum ActivePolling {
    /// Runs `work` now and every `seconds` while the app is in front, until the calling task is cancelled.
    static func run(every seconds: Double, _ work: @MainActor () -> Void) async {
        while !Task.isCancelled {
            if NSApp.isActive {
                work()
                try? await Task.sleep(for: .seconds(seconds))
            } else {
                // Woken by the app coming forward; the next pass reads at once.
                for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                    break
                }
            }
        }
    }
}
