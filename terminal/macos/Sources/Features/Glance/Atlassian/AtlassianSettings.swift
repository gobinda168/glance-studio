import AppKit
import GlanceCore
import SwiftUI

/// Settings → Atlassian, stage S1 (spec 2026-10-09-jira-confluence-design.md, "Settings → Atlassian"):
/// - the sites, with Sign In, Add Jira or Confluence, Rename and Remove;
/// - Add a site;
/// - each site's personal token, for when signing in inside Studio doesn't work.
/// Notifications (S2), Claude Code and project folders (S3) join later.
struct AtlassianSettings: View {
    @ObservedObject private var sessions = AtlassianSessions.shared
    @State private var window: NSWindow?
    @State private var removing: AtlassianSite?
    @State private var renaming: AtlassianSite?
    @State private var newName = ""
    @State private var showTokens = false

    /// The token rows show when asked for, and always while a site has a token, so it can be removed.
    private var showingTokens: Bool {
        showTokens || sessions.store.sites.contains { sessions.hasToken($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: "Atlassian through Glance") {
                ForEach(sessions.store.sites) { site in
                    SettingsRow(id: "connectors.site.\(site.id)", name: site.name, detail: detail(site),
                                light: light(site)) {
                        HStack(spacing: 8) {
                            if !isSignedIn(site) {
                                StudioButton(title: "Sign In") {
                                    BrowserTabController.openAtlassian(
                                        site: site, product: site.has(.jira) ? .jira : .confluence, from: window)
                                }
                            }
                            if site.flavor == .dataCenter, let missing = AtlassianProduct.allCases.first(where: { !site.has($0) }) {
                                StudioButton(title: "Add a \(missing.title) address…") {
                                    AddSitePalette.show(over: window, extending: site)
                                }
                            }
                            StudioButton(title: "Rename…") {
                                newName = site.name
                                renaming = site
                            }
                            StudioButton(title: "Remove…") { removing = site }
                        }
                    }
                }
                SettingsRow(id: "connectors.sites", name: "Add a site",
                            detail: "Your company's Jira and Confluence, on Atlassian Cloud or Data Center. You sign in "
                                + "once in its tab; Glance keeps you signed in.") {
                    StudioButton(title: "Add a Site…", style: .primary) { AddSitePalette.show(over: window) }
                }
            }
            SettingsGroup(title: "Signing in doesn't work?") {
                SettingsRow(id: "connectors.token", name: "Personal token",
                            detail: "If your company's sign-in won't open inside Studio, a personal token lets the side "
                                + "bars reach the site. It's kept in your Keychain; the tabs still sign in through the web.") {
                    StudioButton(title: showingTokens ? "Hide" : "Show…", style: .quiet) { showTokens.toggle() }
                }
                // Collapsed until asked for, or while any site has a token saved.
                if showingTokens {
                    ForEach(sessions.store.sites) { site in
                        TokenRow(site: site)
                    }
                }
            }
        }
        .background(WindowAccessor { window = $0 })
        .alert("Remove \(removing?.name ?? "") from Glance?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { sessions.remove(removing.id) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text("You stay signed in to Atlassian in your browser.")
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { sessions.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func isSignedIn(_ site: AtlassianSite) -> Bool {
        if case .signedIn = sessions.signIn(site.id) { return true }
        return false
    }

    private func light(_ site: AtlassianSite) -> Bool? {
        switch sessions.signIn(site.id) {
        case .signedIn: true
        case .signedOut, .unreachable: false
        case .unknown: nil
        }
    }

    /// "Cloud · acme.atlassian.net · Signed in as Ada Lovelace".
    private func detail(_ site: AtlassianSite) -> String {
        let flavor = site.flavor == .cloud ? "Cloud" : "Data Center"
        let addresses = site.flavor == .cloud
            ? site.displayAddress
            : AtlassianProduct.allCases.compactMap { product in
                site.url(product).map { "\(product.title) at \($0.host ?? "")\($0.path == "/" ? "" : $0.path)" }
            }.joined(separator: " and ")
        let state: String
        switch sessions.signIn(site.id) {
        case .signedIn(let user): state = "Signed in as \(user.displayName)" + (sessions.hasToken(site.id) ? " with a token" : "")
        case .signedOut: state = "Signed out"
        case .unreachable: state = "Can't reach it"
        case .unknown: state = "Checking…"
        }
        return "\(flavor) · \(addresses) · \(state)"
    }
}

/// One site's personal token: Cloud's email and API token, or Data Center's personal access token; Save, Remove, and
/// where to make one.
private struct TokenRow: View {
    let site: AtlassianSite
    @ObservedObject private var sessions = AtlassianSessions.shared
    @State private var email = ""
    @State private var token = ""

    var body: some View {
        let saved = sessions.hasToken(site.id)
        SettingsRow(id: "connectors.token.\(site.id)", name: site.name,
                    detail: saved ? "A token is saved for this site." : help, stacked: true) {
            HStack(spacing: 8) {
                if site.flavor == .cloud {
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                }
                SecureField(site.flavor == .cloud ? "API token" : "Personal access token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                StudioButton(title: "Save", enabled: canSave) { save() }
                if saved {
                    StudioButton(title: "Remove", style: .quiet) { sessions.setToken(nil, for: site.id) }
                }
                StudioButton(title: "Where do I make one?", style: .quiet) {
                    if let page = tokenPage { NSWorkspace.shared.open(page) }
                }
            }
        }
    }

    private var help: String {
        site.flavor == .cloud
            ? "Your Atlassian account's email and an API token from your account's security settings."
            : "A personal access token from your profile on the site."
    }

    private var canSave: Bool {
        let tokenGiven = !token.trimmingCharacters(in: .whitespaces).isEmpty
        return site.flavor == .cloud ? tokenGiven && email.contains("@") : tokenGiven
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: AtlassianAPI.Credential = site.flavor == .cloud
            ? .cloudToken(email: email.trimmingCharacters(in: .whitespaces), token: trimmed)
            : .personalToken(trimmed)
        sessions.setToken(credential, for: site.id)
        token = ""
    }

    /// Where the token is made: Atlassian's account page on Cloud; the profile's token page on Data Center.
    private var tokenPage: URL? {
        if site.flavor == .cloud { return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens") }
        if let jira = site.jiraURL {
            return URL(string: jira.absoluteString
                + "/secure/ViewProfile.jspa?selectedTab=com.atlassian.pats.pats-plugin:jira-user-personal-access-tokens")
        }
        return site.confluenceURL.flatMap { URL(string: $0.absoluteString + "/plugins/personalaccesstokens/usertokens.action") }
    }
}
