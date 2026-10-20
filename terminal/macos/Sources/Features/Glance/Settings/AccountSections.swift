import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// A problem under a section: one line, in the danger colour.
private struct AccountProblem: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .font(.studio(12))
                .foregroundStyle(StudioColors.danger)
                .padding(.top, 8)
        }
    }
}

private extension Error {
    /// What to show for a failed server call; nil for anything else (a cancelled task), which leaves any message alone.
    func cloudMessage(in environment: CloudEnvironment.Name) -> String? {
        (self as? CloudError)?.message(in: environment)
    }
}

/// A `glance://invite/…` link waiting for "Join", or why it can't be used.
struct AccountInviteBanner: View {
    private var account: CloudAccount { .shared }
    @State private var joining = false
    @State private var problem: String?

    var body: some View {
        if let invite = account.pendingInvite {
            SettingsGroup(title: "Invite") {
                SettingsRow(id: "account.invite", name: "Join \(invite.preview.workspaceName)",
                            detail: "\(invite.preview.inviterName) invited you as \(invite.preview.role.title.lowercased()).") {
                    HStack(spacing: 8) {
                        StudioButton(title: "Not Now", style: .quiet) { account.dismissInvite() }
                        if account.user == nil {
                            CloudSignInButtons()
                        } else {
                            StudioButton(title: "Join", style: .primary, busy: joining) {
                                joining = true
                                Task {
                                    problem = await account.acceptPendingInvite()
                                    joining = false
                                }
                            }
                        }
                    }
                }
                AccountProblem(text: problem)
            }
        } else if let error = account.inviteError {
            SettingsGroup(title: "Invite") {
                SettingsRow(id: "account.invite", name: "This invite can't be used", detail: error) {
                    StudioButton(title: "OK", style: .quiet) { account.dismissInvite() }
                }
            }
        }
    }
}

/// Sign-in methods: each linked provider, Remove while more than one is left, "Link another" for the rest.
struct AccountSignInMethods: View {
    private var account: CloudAccount { .shared }
    @State private var problem: String?

    var body: some View {
        let identities = account.me?.identities ?? []
        let missing = CloudProvider.allCases.filter { provider in !identities.contains { $0.provider == provider } }
        SettingsGroup(title: "Sign-in methods") {
            ForEach(identities) { identity in
                SettingsRow(id: "account.identity.\(identity.id)", name: identity.provider.title, detail: identity.email) {
                    if identities.count > 1 {
                        StudioButton(title: "Remove", style: .quiet) {
                            Task { problem = await account.run { try await $0.removeIdentity(identity.id) } }
                        }
                    }
                }
            }
            if !missing.isEmpty {
                SettingsRow(id: "account.link", name: "Link another", detail: "Sign in to this account with another provider too.") {
                    HStack(spacing: 8) {
                        ForEach(missing, id: \.self) { provider in
                            StudioButton(title: provider.title) { Task { problem = await account.link(provider) } }
                        }
                    }
                }
            }
            AccountProblem(text: problem)
        }
    }
}

/// Your Macs: every signed-in Mac, this one marked; sign out any of them, or all.
struct AccountMacs: View {
    private var account: CloudAccount { .shared }
    @State private var macs: [CloudMac] = []
    @State private var confirmingSignOutAll = false
    @State private var problem: String?

    var body: some View {
        SettingsGroup(title: "Your Macs") {
            ForEach(macs) { mac in
                SettingsRow(id: "account.mac.\(mac.id)", name: mac.deviceName,
                            detail: mac.current ? "This Mac" : "Last used \(mac.lastUsedAt.formatted(.relative(presentation: .named)))") {
                    if !mac.current {
                        StudioButton(title: "Sign Out", style: .quiet) {
                            Task {
                                problem = await account.run { try await $0.signOutMac(mac.id) }
                                await load()
                            }
                        }
                    }
                }
            }
            SettingsRow(id: "account.signOutAll", name: "Sign out of all Macs", detail: "Ends every session, this one too.") {
                StudioButton(title: "Sign Out Everywhere", style: .quiet) { confirmingSignOutAll = true }
            }
            AccountProblem(text: problem)
        }
        .task { await load() }
        .confirmationDialog("Sign out of every Mac?", isPresented: $confirmingSignOutAll) {
            Button("Sign Out Everywhere", role: .destructive) { account.signOut(everywhere: true) }
        } message: {
            Text("This Mac too. You'll need to sign in again on each one.")
        }
    }

    private func load() async {
        do {
            macs = try await account.api.macs()
        } catch {
            if let message = error.cloudMessage(in: account.environment.name) { problem = message }
        }
    }
}

/// Workspaces: Personal with its paid features, each team, and "New team".
struct AccountWorkspaces: View {
    private var account: CloudAccount { .shared }
    @State private var newTeam = ""
    @State private var problem: String?

    var body: some View {
        let workspaces = account.me?.workspaces ?? []
        SettingsGroup(title: "Workspaces") {
            ForEach(workspaces) { workspace in
                if workspace.kind == .personal {
                    SettingsRow(id: "account.workspace.personal", name: "Personal", detail: features(workspace)) { EmptyView() }
                } else {
                    TeamRow(workspace: workspace)
                }
            }
            SettingsRow(id: "account.newTeam", name: "New team", detail: "Invite people by sharing a link.") {
                HStack(spacing: 8) {
                    TextField("Team name", text: $newTeam)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    StudioButton(title: "Create", enabled: !newTeam.trimmingCharacters(in: .whitespaces).isEmpty) {
                        let name = newTeam
                        Task {
                            problem = await account.run { _ = try await $0.createTeam(named: name) }
                            if problem == nil { newTeam = "" }
                        }
                    }
                }
            }
            AccountProblem(text: problem)
        }
    }

    private func features(_ workspace: CloudWorkspace) -> String {
        let on = (account.entitlements[workspace.id] ?? []).sorted()
        return on.isEmpty ? "Free" : on.map(CloudFeature.title).joined(separator: " · ")
    }
}

/// One team: members (role menu, remove, make owner), the invite link, pending invites, rename and leave/delete.
private struct TeamRow: View {
    let workspace: CloudWorkspace
    private var account: CloudAccount { .shared }
    @State private var open = false
    @State private var members: [CloudMember] = []
    @State private var invites: [CloudInvite] = []
    @State private var inviteRole: CloudRole = .member
    @State private var copied = false
    @State private var newName = ""
    @State private var confirmingDelete = false
    @State private var confirmingLeave = false
    @State private var removing: CloudMember?
    @State private var makingOwner: CloudMember?
    @State private var revoking: CloudInvite?
    @State private var problem: String?

    private var manages: Bool { workspace.role != .member }

    var body: some View {
        SettingsRow(id: "account.team.\(workspace.id)", name: workspace.name, detail: "You're \(workspace.role.title.lowercased())") {
            StudioButton(title: open ? "Done" : "Manage", style: .quiet) { open.toggle() }
        }
        if open {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(members) { member in
                    SettingsRow(id: "account.member.\(member.id)",
                                name: member.name.isEmpty ? (member.email ?? "Member") : member.name, detail: member.email) {
                        memberControls(member)
                    }
                }
                if manages {
                    SettingsRow(id: "account.inviteLink.\(workspace.id)", name: "Invite link", detail: "Single use, works for 7 days.") {
                        HStack(spacing: 8) {
                            Picker("Role", selection: $inviteRole) {
                                Text("Member").tag(CloudRole.member)
                                Text("Admin").tag(CloudRole.admin)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            StudioButton(title: copied ? "Copied" : "Copy Invite Link", style: .primary) {
                                Task { await copyInvite() }
                            }
                        }
                    }
                    ForEach(invites) { invite in
                        SettingsRow(id: "account.pending.\(invite.id)", name: "\(invite.role.title) invite",
                                    detail: "From \(invite.createdByName) · expires \(invite.expiresAt.formatted(.relative(presentation: .named)))") {
                            StudioButton(title: "Revoke", style: .quiet) { revoking = invite }
                        }
                    }
                }
                teamControls
                AccountProblem(text: problem)
            }
            .padding(.leading, 16)
            .task { await load() }
            .confirmationDialog("Delete \(workspace.name)?", isPresented: $confirmingDelete) {
                Button("Delete Team", role: .destructive) {
                    Task { problem = await account.run { try await $0.deleteWorkspace(workspace.id) } }
                }
            } message: {
                Text("Everyone loses access to it. This can't be undone.")
            }
            .confirmationDialog("Leave \(workspace.name)?", isPresented: $confirmingLeave) {
                Button("Leave Team", role: .destructive) {
                    change(reload: false) { try await $0.leave(workspace.id) }
                }
            } message: {
                Text("You lose access to it until someone invites you again.")
            }
            .confirmationDialog("Remove \(removing.map(name) ?? "this member") from \(workspace.name)?",
                                isPresented: isShowing($removing), presenting: removing) { member in
                Button("Remove", role: .destructive) {
                    change { try await $0.removeMember(member.userID, from: workspace.id) }
                }
            } message: { _ in
                Text("They lose access to the team.")
            }
            .confirmationDialog("Make \(makingOwner.map(name) ?? "this member") the owner of \(workspace.name)?",
                                isPresented: isShowing($makingOwner), presenting: makingOwner) { member in
                Button("Make Owner", role: .destructive) {
                    change { try await $0.transfer(workspace.id, to: member.userID) }
                }
            } message: { _ in
                Text("You become an admin. Only the owner can delete the team.")
            }
            .confirmationDialog("Revoke this invite?", isPresented: isShowing($revoking), presenting: revoking) { invite in
                Button("Revoke Invite", role: .destructive) {
                    Task {
                        problem = await account.run { try await $0.revokeInvite(invite.id, in: workspace.id) }
                        await load()
                    }
                }
            } message: { _ in
                Text("The link stops working for anyone who hasn't used it yet.")
            }
        }
    }

    private func name(_ member: CloudMember) -> String {
        member.name.isEmpty ? (member.email ?? "this member") : member.name
    }

    private func isShowing<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    @ViewBuilder
    private func memberControls(_ member: CloudMember) -> some View {
        let isMe = member.userID == account.user?.id
        if member.role == .owner || !manages || isMe {
            Text(member.role.title)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
        } else {
            HStack(spacing: 8) {
                Menu(member.role.title) {
                    ForEach([CloudRole.admin, .member], id: \.self) { role in
                        Button(role.title) { change { try await $0.setRole(role, for: member.userID, in: workspace.id) } }
                    }
                    if workspace.role == .owner {
                        Divider()
                        Button("Make Owner") { makingOwner = member }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                StudioButton(title: "Remove", style: .quiet) { removing = member }
            }
        }
    }

    private var teamControls: some View {
        SettingsRow(id: "account.teamControls.\(workspace.id)", name: "Team", detail: nil) {
            HStack(spacing: 8) {
                if manages {
                    TextField(workspace.name, text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                    StudioButton(title: "Rename", enabled: !newName.trimmingCharacters(in: .whitespaces).isEmpty) {
                        let name = newName
                        change { try await $0.renameWorkspace(workspace.id, to: name) }
                        newName = ""
                    }
                }
                if workspace.role == .owner {
                    StudioButton(title: "Delete Team…", style: .quiet) { confirmingDelete = true }
                } else {
                    StudioButton(title: "Leave", style: .quiet) { confirmingLeave = true }
                }
            }
        }
    }

    /// `reload: false` when the change removes this team from the account (leave): there's nothing left to load.
    private func change(reload: Bool = true, _ work: @escaping @Sendable (CloudClient) async throws -> Void) {
        Task {
            problem = await account.run(work)
            if reload || problem != nil { await load() }
        }
    }

    private func load() async {
        do {
            members = try await account.api.members(of: workspace.id)
            invites = manages ? try await account.api.invites(of: workspace.id) : []
        } catch {
            if let message = error.cloudMessage(in: account.environment.name) { problem = message }
        }
    }

    private func copyInvite() async {
        do {
            let link = try await account.api.createInvite(to: workspace.id, role: inviteRole)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            copied = true
            await load()
            try? await Task.sleep(for: .seconds(2))
            copied = false
        } catch {
            if let message = error.cloudMessage(in: account.environment.name) { problem = message }
        }
    }
}

/// Delete account: a confirmation, then the server's answer (it refuses while you own a team, naming them).
struct AccountDeletion: View {
    private var account: CloudAccount { .shared }
    @State private var confirming = false
    @State private var problem: String?

    var body: some View {
        SettingsGroup(title: nil) {
            SettingsRow(id: "account.delete", name: "Delete account",
                        detail: "Removes your account, sign-in methods and personal workspace for good.") {
                StudioButton(title: "Delete Account…", style: .quiet) { confirming = true }
            }
            AccountProblem(text: problem)
        }
        .confirmationDialog("Delete your Glance account?", isPresented: $confirming) {
            Button("Delete Account", role: .destructive) {
                Task {
                    problem = await account.run { try await $0.deleteAccount() }
                    if problem == nil { account.signOut() }
                }
            }
        } message: {
            Text("This can't be undone.")
        }
    }
}
