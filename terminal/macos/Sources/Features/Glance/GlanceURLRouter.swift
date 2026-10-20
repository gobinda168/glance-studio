import AppKit
import GlanceCore
import GlanceKit

/// Opens `glance://` links (spec 2026-10-18-glance-server-core-design.md, "The Mac app"): an invite opens Settings →
/// Account, which asks before joining. Anything else is ignored, silently: that includes a `glance://auth/done…`
/// that reaches the app after its sign-in sheet closed, which is never a sign-in.
@MainActor
enum GlanceURLRouter {
    static func open(_ url: URL) {
        guard let token = CloudAuth.inviteToken(from: url) else { return }
        SettingsTabController.open(section: .account, from: SettingsTabController.frontWindow)
        Task { await CloudAccount.shared.openInvite(token: token) }
    }
}
