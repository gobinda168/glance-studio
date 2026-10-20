import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The repository picker's list (spec 2026-10-08-pr-repositories-design.md, "The picker"): the filter field; THIS TAB,
/// RECENT and ALL REPOSITORIES, or the matches while filtering; "Signed in as" with Sign out. ↑↓ move, Return picks,
/// Esc closes. The repository button's popover shows it, and the side bar does at full height when nothing is picked.
struct RepositoryPickerList: View {
    /// The repository shown, checked.
    let shown: String?
    /// The tab's project on GitHub.
    let thisTab: String?
    let window: NSWindow?
    let pick: (String) -> Void
    var dismiss: (() -> Void)?
    @ObservedObject private var account = GitHubAccountModel.shared
    @ObservedObject private var model = PullRequestsModel.shared
    @ObservedObject private var folders = RepositoryFoldersModel.shared
    @State private var filter = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private struct Row: Identifiable {
        let id: String
        let repository: GitHubAccount.Repository
        /// The section's title, on its first row.
        let header: String?
    }

    var body: some View {
        let rows = self.rows(RepositoryPicker.groups(all: account.repositories, recent: model.recent, thisTab: thisTab,
                                                     filter: filter))
        VStack(spacing: 0) {
            field(rows)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        status(rows)
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            VStack(alignment: .leading, spacing: 0) {
                                if let header = row.header {
                                    Caption(header)
                                        .padding(.horizontal, 10)
                                        .padding(.top, index == 0 ? 4 : 12)
                                        .padding(.bottom, 4)
                                }
                                PickerRow(repository: row.repository,
                                          isShown: shown.map(RepositoryFolders.key) == RepositoryFolders.key(row.repository.name),
                                          isLocal: folders.folder(for: row.repository.name) != nil,
                                          isHighlighted: index == highlighted) {
                                    pick(row.repository.name)
                                }
                            }
                            .id(row.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
                .onChange(of: highlighted) { _, index in
                    if rows.indices.contains(index) { proxy.scrollTo(rows[index].id) }
                }
            }
            footer
        }
        .onAppear {
            focused = true
            account.loadRepositories()
        }
        .onChange(of: filter) { highlighted = 0 }
    }

    /// The filter field: typing narrows, ↑↓ move the highlight, Return picks it, Esc closes.
    private func field(_ rows: [Row]) -> some View {
        HStack(spacing: 8) {
            StudioIcon(.search, size: 14).foregroundStyle(StudioColors.muted)
            TextField("Filter repositories", text: $filter)
                .textFieldStyle(.plain)
                .font(.studio(12))
                .foregroundStyle(StudioColors.ink)
                .focused($focused)
                .onSubmit { if rows.indices.contains(highlighted) { pick(rows[highlighted].repository.name) } }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, max(rows.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onExitCommand { dismiss?() }
                .accessibilityLabel("Filter repositories")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }

    /// Loading, a failed read (the saved list stays under it), an empty account, or no matches.
    @ViewBuilder private func status(_ rows: [Row]) -> some View {
        let query = filter.trimmingCharacters(in: .whitespaces)
        if case .failed(let message) = account.listState {
            InlineError(message: message) { account.loadRepositories(force: true) }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        if rows.isEmpty {
            Group {
                if !query.isEmpty {
                    Text("No repository matches “\(query)”.")
                } else if account.repositories.isEmpty && account.hasList {
                    Text("No repositories on this account.")
                } else if account.repositories.isEmpty {
                    HStack(spacing: 8) {
                        Spinner(size: 13)
                        Text("Loading your repositories…")
                    }
                }
            }
            .font(.studio(12))
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    /// "Signed in as <login>" and Sign out, and why a sign-out failed.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = account.signOutError {
                InlineError(message: error)
            }
            HStack(spacing: 8) {
                if let login = account.login {
                    Text("Signed in as \(login)")
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    StudioButton(title: "Sign out", style: .quiet, height: 24) {
                        dismiss?()
                        account.signOut(from: window)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    private func rows(_ groups: [RepositoryPicker.Group]) -> [Row] {
        let everything = filter.trimmingCharacters(in: .whitespaces).isEmpty
            ? [Row(id: "everything", repository: GitHubAccount.Repository(name: PullRequests.allRepositories), header: nil)]
            : []
        return everything + groups.flatMap { group in
            group.repositories.enumerated().map { index, repository in
                Row(id: "\(group.section)-\(RepositoryFolders.key(repository.name))", repository: repository,
                    header: index == 0 ? title(group) : nil)
            }
        }
    }

    private func title(_ group: RepositoryPicker.Group) -> String? {
        switch group.section {
        case .thisTab: "This tab"
        case .recent: "Recent"
        case .all: "All repositories · \(group.repositories.count)"
        case .matches: nil
        }
    }
}

/// One repository: the check on the one shown, `owner/name` in mono, a lock when private, a folder when it's on this
/// Mac. The highlight follows the keys and the pointer.
private struct PickerRow: View {
    let repository: GitHubAccount.Repository
    let isShown: Bool
    let isLocal: Bool
    let isHighlighted: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 8) {
                StudioIcon(.check, size: 13, weight: 2.4)
                    .foregroundStyle(StudioColors.coralInk)
                    .opacity(isShown ? 1 : 0)
                if repository.name == PullRequests.allRepositories {
                    StudioIcon(.layers, size: 13).foregroundStyle(StudioColors.muted)
                    Text("All repositories")
                        .font(.studio(12.5, isShown ? .semibold : .medium))
                        .foregroundStyle(StudioColors.ink)
                } else {
                    Text(repository.name)
                        .font(.studioMono(11.5, isShown ? .semibold : .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if repository.isPrivate {
                    StudioIcon(.lock, size: 12).foregroundStyle(StudioColors.muted).help("Private")
                }
                if isLocal {
                    StudioIcon(.folder, size: 12).foregroundStyle(StudioColors.muted).help("On this Mac")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHighlighted || hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel((repository.name == PullRequests.allRepositories ? "All repositories" : repository.name)
                            + (repository.isPrivate ? ", private" : "") + (isLocal ? ", on this Mac" : ""))
        .accessibilityAddTraits(isShown ? .isSelected : [])
    }
}

/// The side bar's repository button (the canvas's `.btn`, mono with the chevron): the repository shown; a click opens
/// the picker under it, 360 pt wide.
struct RepositoryButton: View {
    let shown: String
    let thisTab: String?
    let window: NSWindow?
    let pick: (String) -> Void
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Text(shown == PullRequests.allRepositories ? "All repositories" : shown)
                    .font(.studioMono(11.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                StudioIcon(.chevronDown, size: 14)
            }
            .foregroundStyle(StudioColors.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering || open ? StudioColors.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Choose a Repository")
        .accessibilityLabel(shown == PullRequests.allRepositories ? "All repositories" : "Repository \(shown)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            RepositoryPickerList(shown: shown, thisTab: thisTab, window: window, pick: { repository in
                open = false
                pick(repository)
            }, dismiss: { open = false })
            .frame(width: 360, height: 440)
            .background(StudioColors.bar)
        }
    }
}

/// "Sign in to GitHub" (spec, "Signing in"): Sign in with GitHub runs gh's browser sign-in; the card then shows the
/// one-time code, Copy Code and Open GitHub, and waits for GitHub with Cancel. A failure says why, with Try Again.
struct GitHubSignInCard: View {
    @ObservedObject private var account = GitHubAccountModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to GitHub")
                .font(.studio(12.5, .semibold))
                .foregroundStyle(StudioColors.ink)
            switch account.signIn {
            case nil:
                Text("Glance reads your pull requests with the GitHub CLI.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
                StudioButton(title: "Sign in with GitHub", style: .primary) { account.startSignIn() }
            case .starting?:
                waiting("Starting the GitHub CLI…")
            case .waiting(let prompt)?:
                Text("Enter this code on GitHub:")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.body)
                Text(prompt.code)
                    .font(.studioMono(22, .semibold))
                    .tracking(2)
                    .foregroundStyle(StudioColors.ink)
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(prompt.code.map(String.init).joined(separator: " "))")
                Text("Copied to your clipboard")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                StudioButton(title: "Copy Code and Open GitHub", icon: .copy, style: .primary) {
                    account.copyCodeAndOpen()
                }
                waiting("Waiting for GitHub…")
            case .failed(let message)?:
                InlineError(message: message)
                StudioButton(title: "Try Again", icon: .refresh, style: .primary) { account.startSignIn() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func waiting(_ words: String) -> some View {
        HStack(spacing: 8) {
            Spinner(size: 13)
            Text(words)
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
            Spacer(minLength: 4)
            StudioButton(title: "Cancel", style: .quiet, height: 26) { account.cancelSignIn() }
        }
    }
}
