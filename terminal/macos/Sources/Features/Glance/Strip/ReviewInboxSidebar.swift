import AppKit
import GlanceCore
import SwiftUI

/// The side bar beside the Review comments tab (board 4): the filters with their counts, the one shown selected. Then
/// "By pull request": the pull requests with threads under that filter, each opening its tab.
struct ReviewInboxSidebar: View {
    @ObservedObject var controller: ReviewInboxWindowController
    @ObservedObject private var model = PullRequestsModel.shared

    var body: some View {
        let entry = model.entry(for: controller.repository)
        let open = (entry.board?.waitingOnYou ?? []) + (entry.board?.yours ?? [])
        let threads = entry.reviews?.threads ?? [:]
        let viewer = entry.reviews?.viewer ?? ""
        let counts = ReviewInbox.counts(open, threads: threads, viewer: viewer)
        let groups = ReviewInbox.groups(open, threads: threads, filter: controller.filter, viewer: viewer)
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "Review comments") {
                SidebarIconButton(icon: .refresh, label: "Refresh") {
                    model.load(controller.repository, force: true)
                }
            }
            BackToPullRequestsRow { controller.sidebarShowsList = true }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(ReviewInbox.Filter.allCases, id: \.self) { filter in
                        InboxFilterRow(title: filter.title, count: counts[filter] ?? 0, alert: filter == .blocking,
                                       selected: controller.filter == filter) {
                            controller.filter = filter
                        }
                    }
                    if !groups.isEmpty {
                        Caption("By pull request")
                            .padding(.horizontal, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 6)
                        ForEach(groups, id: \.pullRequest.number) { group in
                            InboxPullRequestRow(pullRequest: group.pullRequest, count: group.threads.count) {
                                PullRequestWindowController.open(repository: controller.repository,
                                                                 number: group.pullRequest.number,
                                                                 root: controller.root, from: controller.window)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The way back to the pull requests list from a side bar that has taken its place (Review comments, New pull
/// request): the coral chevron and "Pull requests", as the changed files' "PR #" row goes back to the Overview.
struct BackToPullRequestsRow: View {
    let back: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: back) {
            HStack(spacing: 6) {
                StudioIcon(.chevronLeft, size: 13)
                Text("Pull requests")
                Spacer(minLength: 0)
            }
            .font(.studio(12.5, .medium))
            .foregroundStyle(StudioColors.coralInk)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .help("Back to the Pull Requests")
        .accessibilityLabel("Back to pull requests")
    }
}

/// A filter (the canvas's row): its name and count, Blocking's count in the danger tint. The one shown has the
/// selection's tint and the 2 pt coral edge.
private struct InboxFilterRow: View {
    let title: String
    let count: Int
    let alert: Bool
    let selected: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        let lit = alert && count > 0
        Button(action: choose) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.studio(13, selected ? .semibold : .regular))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.studioMono(11, lit ? .semibold : .regular))
                    .foregroundStyle(lit ? StudioColors.danger : StudioColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background { rowBackground(selected: selected, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A pull request with threads under the filter: `#51`, its title, how many. A click opens its tab.
private struct InboxPullRequestRow: View {
    let pullRequest: PullRequests.PullRequest
    let count: Int
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text("#\(pullRequest.number)")
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
                Text(pullRequest.title)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background { rowBackground(selected: false, hovering: hovering) }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Open #\(pullRequest.number)")
    }
}

/// A side bar row's fill: the selection's tint with a 2 pt coral edge, the hover fill, or nothing.
@ViewBuilder private func rowBackground(selected: Bool, hovering: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    if selected {
        shape.fill(StudioColors.selection)
            .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
            .clipShape(shape)
    } else {
        shape.fill(hovering ? StudioColors.hover : .clear)
    }
}
