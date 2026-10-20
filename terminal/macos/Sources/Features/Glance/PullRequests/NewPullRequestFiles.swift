import GlanceCore
import SwiftUI

/// Files changed (board 3): the first six with their additions, deletions and a bar of the additions; "+ N more"; and
/// Open diff, the branch's changes read-only.
struct FilesChangedList: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let files: [BranchCompare.FileStat]
    @State private var all = false

    var body: some View {
        let most = max(files.map(\.additions).max() ?? 0, 1)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Caption("Files changed · \(files.count)")
                Spacer(minLength: 8)
                if !files.isEmpty {
                    Button("Open diff") { controller.showingDiff = true }
                        .buttonStyle(.plain)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.coralInk)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if files.isEmpty {
                    Text("Nothing the base doesn't have.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .padding(8)
                }
                ForEach(all ? files : Array(files.prefix(6)), id: \.path) { file in
                    row(file, most: most)
                }
                if !all && files.count > 6 {
                    Button("+ \(files.count - 6) more") { all = true }
                        .buttonStyle(.plain)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }
            }
            .padding(6)
            .background(shape.fill(StudioColors.card))
            .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
        }
    }

    private func row(_ file: BranchCompare.FileStat, most: Int) -> some View {
        HStack(spacing: 10) {
            Text(file.path)
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.binary ? "bin" : file.additions > 0 ? "+\(file.additions)" : "")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.ok)
                .frame(width: 36, alignment: .trailing)
            Text(file.deletions > 0 ? "−\(file.deletions)" : "")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.danger)
                .frame(width: 26, alignment: .trailing)
            Capsule()
                .fill(StudioColors.field)
                .overlay(alignment: .leading) {
                    Capsule().fill(StudioColors.ok).frame(width: max(3, 80 * CGFloat(file.additions) / CGFloat(most)))
                }
                .frame(width: 80, height: 6)
                .clipShape(Capsule())
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

/// The branch's diff, read-only (New pull request's Open diff): each file's card; drag across numbers, hover + A, or the
/// card's Ask Claude to ask about lines or the file.
struct ReadOnlyDiff: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let files: [PullRequestDiff.File]
    let subject: DiffAsk.Subject
    /// "owner/name", for links in Claude's answers.
    let repository: String
    @ObservedObject private var inbox = ReviewInboxStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { controller.showingDiff = false } label: {
                HStack(spacing: 6) {
                    StudioIcon(.chevronLeft, size: 12)
                    Text("Back to the form")
                }
                .font(.studio(12, .medium))
                .foregroundStyle(StudioColors.coralInk)
            }
            .buttonStyle(.plain)
            ForEach(files, id: \.path) { file in
                ReadOnlyFileCard(controller: controller, file: file,
                                 owner: DiffAsks.Owner(key: DiffAsks.key(newPullRequest: controller.root),
                                                       folder: controller.root, subject: subject),
                                 canAsk: inbox.claudeInstalled != false) { url in
                    PullRequestLinkRouter.open(url, repository: repository, root: controller.root,
                                               from: controller.window)
                }
            }
        }
        .onAppear { inbox.checkClaude() }
    }
}

/// One file of the branch's diff, with its own line picking, key monitor and answer boxes.
private struct ReadOnlyFileCard: View {
    @ObservedObject var controller: NewPullRequestWindowController
    let file: PullRequestDiff.File
    let owner: DiffAsks.Owner
    let canAsk: Bool
    let openLink: (URL) -> Void
    @ObservedObject private var asks = DiffAsks.shared
    @State private var composing: FilesPage.Composing?
    @State private var picking: FilesPage.Composing?
    @State private var draft = ""
    @State private var frames = DiffLineFrames()
    @State private var hover = HoverBox()
    @State private var keys = CommentKeyMonitor()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let boxes = asks.boxes(owner.key, path: file.path)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(boxes.filter { $0.anchor == nil }) { box in
                DiffAskBox(box: box, owner: owner.key, openLink: openLink)
            }
            VStack(alignment: .leading, spacing: 0) {
                header
                if let notice = FilesPage.notice(file) {
                    Text(notice)
                        .font(.studio(12.5))
                        .foregroundStyle(StudioColors.muted)
                        .padding(16)
                } else {
                    lines(boxes)
                }
            }
            .background(shape.fill(StudioColors.card))
            .clipShape(shape)
            .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
        }
        .onAppear {
            keys.start(window: controller.window, line: { hover.anchor }, comment: { open($0) }, ask: { open($0) })
        }
        .onDisappear { keys.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(file.path)
                .font(.studioMono(12, .medium))
                .foregroundStyle(StudioColors.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("+\(file.additions)").font(.studioMono(11)).foregroundStyle(StudioColors.ok)
            Text("−\(file.deletions)").font(.studioMono(11)).foregroundStyle(StudioColors.danger)
            StudioButton(title: "Ask Claude", enabled: canAsk, height: 24) {
                asks.open(owner, file: file, path: file.path, scope: .file, question: nil)
            }
            .help(canAsk ? "Ask Claude about this file" : "Install Claude Code to ask Claude")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(StudioColors.field)
    }

    private func lines(_ boxes: [DiffAsks.Box]) -> some View {
        let lineBoxes = Dictionary(grouping: boxes.filter { $0.anchor != nil }, by: { $0.anchor! })
            .mapValues { $0.map(\.id) }
        let items = DiffItem.items(file, layout: .unified, placement: ReviewThreads.Placement(),
                                   composing: composing?.end, asks: lineBoxes)
        let selected = DiffPicking.range(picking ?? composing, frames: frames.frames, split: false)
        let interaction = LineInteraction(
            hover: hover,
            comment: { open($0) },
            drag: { start, point in
                if let picked = DiffPicking.picked(from: start, to: point, frames: frames.frames, split: false) {
                    picking = picked
                }
            },
            dragEnded: {
                if let ordered = DiffPicking.ordered(picking, frames: frames.frames) { composing = ordered }
                picking = nil
            },
            canComment: false)
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                switch item {
                case .hunk(_, let header):
                    Text(header)
                        .font(.studioMono(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                case .unified(let line, _):
                    UnifiedLineView(line: line, twoColumns: file.change == .modified || file.change == .renamed,
                                    language: SyntaxHighlight.Language(path: file.path),
                                    interaction: canAsk ? interaction : nil,
                                    selected: DiffItem.commentAnchor(line).map { selected.contains($0) } ?? false)
                case .ask(let id):
                    if let box = boxes.first(where: { $0.id == id }) {
                        DiffAskBox(box: box, owner: owner.key, openLink: openLink)
                            .inlineBlock()
                    }
                case .composer:
                    if let composing {
                        CommentComposer(title: "Ask Claude about "
                                            + DiffAsk.place(.lines(start: composing.start, end: composing.end)),
                                        text: $draft, busy: false, error: nil,
                                        cancel: { self.composing = nil }, add: {},
                                        asksOnly: true, canAsk: canAsk, ask: { askLines(composing) })
                            .inlineBlock()
                    }
                case .split, .threads:
                    EmptyView()
                }
            }
        }
        .coordinateSpace(.named(DiffSpace.name))
        .onPreferenceChange(DiffLineFrameKey.self) { frames.frames = $0 }
    }

    private func open(_ anchor: ReviewThreads.Anchor) {
        guard canAsk else { NSSound.beep(); return }
        composing = FilesPage.Composing(start: nil, end: anchor)
    }

    private func askLines(_ composing: FilesPage.Composing) {
        asks.open(owner, file: file, path: file.path, scope: .lines(start: composing.start, end: composing.end),
                  question: draft)
        self.composing = nil
        draft = ""
    }
}
