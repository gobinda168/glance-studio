import GlanceCore
import SwiftUI

/// The Pull requests side bar while a PR tab shows its Files page (board 2):
/// - "‹ PR #51" back to the Overview;
/// - the title;
/// - how many files are viewed, with +/− and the bar;
/// - the changed files by folder: viewed boxes, open threads, +/−, and the file shown selected.
///
/// A commit's files show without viewed boxes.
struct ChangedFilesSidebar: View {
    @ObservedObject var controller: PullRequestWindowController
    @ObservedObject private var store = PullRequestStore.shared
    @State private var onlyCommented = false
    @State private var folded: Set<String> = []

    /// A changed file as the list shows it.
    private struct Row {
        let path: String
        let additions: Int
        let deletions: Int
    }

    var body: some View {
        let entry = store.entry(controller.key)
        let rows = changedFiles(entry)
        let counts = ReviewThreads.openCounts(entry.extras?.threads ?? [])
        let viewed = entry.extras?.viewed ?? []
        let readOnly = controller.commit != nil
        let shown = rows.filter { !onlyCommented || counts[$0.path, default: 0] > 0 }
        let folders = PullRequestDiff.folders(shown.map(\.path))
        let byPath = Dictionary(rows.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let current = controller.file ?? rows.first?.path
        VStack(spacing: 0) {
            header(entry, rows: rows, viewed: viewed, readOnly: readOnly)
            HStack(spacing: 0) {
                Caption("Changed files")
                Spacer(minLength: 4)
                ToggleIconButton(icon: .chats, label: onlyCommented ? "Show All Files" : "Show Only Files with Comments",
                                 isOn: onlyCommented) { onlyCommented.toggle() }
                SidebarIconButton(icon: .collapse,
                                  label: folded.count == folders.count ? "Expand Folders" : "Collapse Folders") {
                    folded = folded.count == folders.count ? [] : Set(folders.map(\.path))
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 34)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text(onlyCommented ? "No files with comments." : "Reading the files…")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(folders, id: \.path) { folder in
                        FolderRow(path: folder.path, count: folder.files.count, folded: folded.contains(folder.path)) {
                            if folded.contains(folder.path) { folded.remove(folder.path) } else { folded.insert(folder.path) }
                        }
                        if !folded.contains(folder.path) {
                            ForEach(folder.files, id: \.self) { path in
                                let row = byPath[path]
                                FileRow(name: (path as NSString).lastPathComponent, additions: row?.additions ?? 0,
                                        deletions: row?.deletions ?? 0, comments: readOnly ? 0 : counts[path, default: 0],
                                        viewed: readOnly ? nil : viewed.contains(path), current: path == current,
                                        toggleViewed: {
                                            PullRequestStore.shared.review(.viewed(path: path, !viewed.contains(path)),
                                                                           key: controller.key)
                                        },
                                        open: { controller.file = path })
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

    /// The files: the diff's once it's read (the pull request's, or the commit's), else `gh pr view`'s list. GitHub's
    /// diff can be refused on a big pull request, and the list still shows.
    private func changedFiles(_ entry: PullRequestStore.Entry) -> [Row] {
        let id = controller.commit.map { PullRequestStore.commitKey(controller.key, sha: $0) }
            ?? entry.page.map { PullRequestStore.diffKey(controller.key, head: $0.headOid) }
        if let id, case .ready(let files)? = store.diffs[id] {
            return files.map { Row(path: $0.path, additions: $0.additions, deletions: $0.deletions) }
        }
        guard controller.commit == nil else { return [] }
        return (entry.page?.files ?? []).map { Row(path: $0.path, additions: $0.additions, deletions: $0.deletions) }
    }

    @ViewBuilder private func header(_ entry: PullRequestStore.Entry, rows: [Row], viewed: Set<String>,
                                     readOnly: Bool) -> some View {
        let count = rows.filter { viewed.contains($0.path) }.count
        VStack(alignment: .leading, spacing: 0) {
            Button { controller.section = .overview } label: {
                HStack(spacing: 4) {
                    StudioIcon(.chevronLeft, size: 13)
                    Text("PR #\(controller.key.number)")
                }
                .font(.studio(12))
                .foregroundStyle(StudioColors.coralInk)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to the Overview")
            Text(entry.page?.title ?? "")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 10)
            HStack(spacing: 6) {
                Text(readOnly ? "Commit \(String((controller.commit ?? "").prefix(7))) · \(rows.count) files"
                     : "\(count) of \(rows.count) files viewed")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                Spacer(minLength: 4)
                Text("+\(rows.reduce(0) { $0 + $1.additions })").foregroundStyle(StudioColors.ok)
                Text("−\(rows.reduce(0) { $0 + $1.deletions })").foregroundStyle(StudioColors.danger)
            }
            .font(.studioMono(11))
            .padding(.bottom, 6)
            if !readOnly {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioColors.field)
                        Capsule().fill(StudioColors.coral)
                            .frame(width: rows.isEmpty ? 0 : geometry.size.width * CGFloat(count) / CGFloat(rows.count))
                    }
                }
                .frame(height: 4)
                .accessibilityElement()
                .accessibilityLabel("Files viewed")
                .accessibilityValue("\(count) of \(rows.count)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
    }
}

/// A folder: its chevron and path; folded, how many files it holds.
private struct FolderRow: View {
    let path: String
    let count: Int
    let folded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                StudioIcon(folded ? .chevronRight : .chevronDown, size: 12)
                Text(path).font(.studioMono(11.5)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                if folded { Text("\(count) \(count == 1 ? "file" : "files")").font(.studio(11)) }
            }
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(folded ? "collapsed" : "expanded")
    }
}

/// A changed file: its viewed box, name (muted once viewed), open threads and +/−. The one shown is selected.
private struct FileRow: View {
    let name: String
    let additions: Int
    let deletions: Int
    let comments: Int
    /// Nil for a commit's files: they have no viewed box.
    let viewed: Bool?
    let current: Bool
    let toggleViewed: () -> Void
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let viewed {
                Button(action: toggleViewed) { ViewedBox(checked: viewed) }
                    .buttonStyle(.plain)
                    .help(viewed ? "Mark as Not Viewed" : "Mark as Viewed")
                    .accessibilityLabel("Viewed \(name)")
                    .accessibilityValue(viewed ? "on" : "off")
            }
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.studio(12.5, current ? .semibold : .regular))
                        .foregroundStyle(viewed == true ? StudioColors.muted : StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if comments > 0 {
                        HStack(spacing: 3) {
                            StudioIcon(.chats, size: 11)
                            Text("\(comments)")
                        }
                        .font(.studio(11, .semibold))
                        .foregroundStyle(StudioColors.coralInk)
                    }
                    if additions > 0 { Text("+\(additions)").font(.studioMono(10.5)).foregroundStyle(StudioColors.ok) }
                    if deletions > 0 { Text("−\(deletions)").font(.studioMono(10.5)).foregroundStyle(StudioColors.danger) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(current ? .isSelected : [])
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background {
            let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
            if current {
                shape.fill(StudioColors.selection)
                    .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
                    .clipShape(shape)
            } else {
                shape.fill(hovering ? StudioColors.hover : .clear)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// A header icon button that stays coral while it's on (Show only files with comments).
private struct ToggleIconButton: View {
    let icon: StudioIcons.Name
    let label: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(icon, size: 14)
                .foregroundStyle(isOn ? StudioColors.coralInk : hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering || isOn ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
