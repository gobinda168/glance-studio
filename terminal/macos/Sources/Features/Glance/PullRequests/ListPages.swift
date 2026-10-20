import GlanceCore
import SwiftUI

/// The commits, oldest first: hash, headline, author and age. A click opens the Files page on that commit's changes.
struct CommitsListPage: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page

    var body: some View {
        StudioCard {
            VStack(spacing: 0) {
                ForEach(Array(page.commits.enumerated()), id: \.offset) { index, commit in
                    CommitRow(commit: commit) { controller.showCommit(commit.oid) }
                    if index < page.commits.count - 1 { Rectangle().fill(StudioColors.line2).frame(height: 1) }
                }
            }
        }
    }
}

/// One commit: a click shows its changes.
private struct CommitRow: View {
    let commit: PullRequestPage.Commit
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(commit.shortOid).font(.studioMono(11.5)).foregroundStyle(StudioColors.coralInk)
                Text(commit.headline)
                    .font(.studio(12.5))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(commit.author).font(.studio(12)).foregroundStyle(StudioColors.muted)
                Text(StudioTime.ago(commit.date)).font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(hovering ? StudioColors.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help("Show This Commit's Changes")
    }
}
