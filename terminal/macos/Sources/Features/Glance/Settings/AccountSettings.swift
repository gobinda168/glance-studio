import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Account (spec 2026-10-18-glance-server-core-design.md, "Settings → Account"): the Glance account cloud features
/// use. Glance works without one.
struct AccountSettings: View {
    private var account: CloudAccount { .shared }

    var body: some View {
        let server = StudioFeatures.shared.isDevelopment ? "Glance server · \(account.environment.name.title)" : nil
        VStack(alignment: .leading, spacing: 0) {
            AccountInviteBanner()
            SettingsGroup(title: server) {
                SettingsRow(id: "account.signIn", name: "Glance account", detail: detail, light: account.user != nil) {
                    switch account.state {
                    case .notSetUp:
                        EmptyView()
                    case .signedOut, .failed:
                        CloudSignInButtons(showsProblem: false)
                    case .signingIn:
                        StudioButton(title: "Cancel") { account.cancelSignIn() }
                    case .signedIn(let user):
                        HStack(spacing: 10) {
                            AccountAvatar(url: user.avatarURL)
                            StudioButton(title: "Sign Out") { account.signOut() }
                        }
                    }
                }
            }
            if account.user != nil {
                AccountSignInMethods()
                AccountMacs()
                AccountWorkspaces()
                AccountDeletion()
            }
        }
        .task(id: account.user?.id) { await account.refreshMe() }
    }

    private var detail: String {
        switch account.state {
        case .notSetUp: "The Glance server isn't set up in this build."
        case .signedOut: "An account is only needed for cloud features. Everything else works without one."
        case .signingIn: "Finish signing in in the sheet…"
        case .failed(let message): message
        case .signedIn(let user):
            [user.name, user.email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

/// Continue with Apple / Google / GitHub: Settings → Account's buttons, for any cloud feature that finds you signed out.
struct CloudSignInButtons: View {
    var height: CGFloat = 30
    /// Settings → Account already says why a sign-in failed in its own row.
    var showsProblem = true
    var onSignedIn: () -> Void = {}

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(CloudProvider.allCases, id: \.self) { provider in
                    StudioButton(title: "Continue with \(provider.title)", height: height) {
                        Task {
                            if (try? await CloudAccount.shared.signIn(with: provider)) != nil { onSignedIn() }
                        }
                    }
                }
            }
            if showsProblem, case .failed(let message) = CloudAccount.shared.state {
                Text(message)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.danger)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The account's picture, or a person mark while it loads or when there's none.
struct AccountAvatar: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            StudioIcon(.person, size: 14).foregroundStyle(StudioColors.muted)
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(StudioColors.line, lineWidth: 1))
    }
}
