import AVKit
import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The session timeline in the Glance view (spec 2026-11-01-command-center-design.md §2): the prompts, Claude's prose,
/// quiet tool rows on a thin rail, edit diffs, Bash results, inline media, subagents nested under their Task, and the
/// live line. Not named TimelineView: that would shadow SwiftUI.TimelineView module-wide.
struct SessionTimelineView: View {
    @ObservedObject var model: SessionViewModel
    /// The rows show proof marks (check results, unbacked claims), so they redraw when the proof changes.
    @ObservedObject private var proof: ProofModel
    @ObservedObject private var explainers: ExplainerModel

    init(model: SessionViewModel) {
        self.model = model
        _proof = ObservedObject(wrappedValue: model.proof)
        _explainers = ObservedObject(wrappedValue: model.explainers)
    }

    /// The bottom of the content is within reach, so new rows keep it in view; otherwise "Jump to latest" shows.
    @State private var atBottom = true

    private static let bottomID = "live"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.timeline.truncated {
                        Text("Earlier messages aren't shown (large transcript)")
                            .font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                            .padding(.bottom, 12)
                    }
                    let media = mediaByBlock
                    ForEach(media.first, id: \.capture.id) { TimelineMediaRow(capture: $0.capture, url: proof.mediaURL($0.capture)) }
                    let fold = explainers.fold(blocks: model.blocks)
                    ForEach(model.blocks) { block in
                        if let line = fold.lines[block.id] { ExplainerStepsLine(line: line, explainers: explainers) }
                        if !fold.hidden.contains(block.id) {
                            TimelineBlockView(block: block, ctx: context).id(block.id)
                        }
                        ForEach(media.after[block.id] ?? [], id: \.capture.id) {
                            TimelineMediaRow(capture: $0.capture, url: proof.mediaURL($0.capture))
                        }
                    }
                    if let prompt = model.prompt {
                        PromptCardView(prompt: prompt, answered: model.answeredCall == prompt.call.id,
                                       answer: { model.answer($0) }, showTerminal: { model.showTerminal() }, model: model)
                            .id(prompt.call.id)
                            .padding(.top, 20)
                    }
                    TimelineLiveLine(live: model.timeline.live, waiting: model.prompt != nil)
                        .padding(.top, 18)
                        .frame(minHeight: 24, alignment: .leading)
                        .id(Self.bottomID)
                }
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(content: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY,
                              container: geometry.containerSize.height)
            } action: { old, new in
                // The content grew or the viewport resized while the bottom was in view: stay on the bottom (the
                // distance only looks big because of the growth). Otherwise it is the user scrolling.
                if Date() < explainers.followPausedUntil {
                    // A new explainer is on screen: its top stays in view while it takes its height.
                    atBottom = false
                } else if old.isNearBottom, old.content != new.content || old.container != new.container {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    atBottom = true
                } else if new.isNearBottom != atBottom {
                    atBottom = new.isNearBottom
                }
            }
            .onChange(of: model.blocks.count) { followIfAtBottom(proxy) }
            .onChange(of: model.timeline.live) { followIfAtBottom(proxy) }
            .onChange(of: model.prompt?.call.id) { followIfAtBottom(proxy) }
            .onChange(of: explainers.scrollRequest) {
                guard let reply = explainers.scrollRequest?.reply else { return }
                atBottom = false
                proxy.scrollTo(reply, anchor: .top)
            }
            .overlay(alignment: .bottom) {
              VStack(spacing: 8) {
                if !atBottom {
                    Button {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                        atBottom = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down").font(.system(size: 11, weight: .semibold))
                            Text("Jump to latest").font(.studio(12, .medium))
                        }
                        .foregroundStyle(StudioColors.ink)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(StudioColors.solid))
                        .overlay(Capsule().stroke(StudioColors.line3, lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
                if let shown = explainers.barPage {
                    ExplainerVoiceBar(explainers: explainers, reply: shown.reply, page: shown.page)
                }
              }
              .padding(.bottom, 12)
            }
        }
    }

    private func followIfAtBottom(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    /// Clips and explainers where they happened (Command center): after the block holding the row they follow, or
    /// before every block. Off with the flag.
    private var mediaByBlock: (first: [TimelineLayout.MediaPlacement], after: [String: [TimelineLayout.MediaPlacement]]) {
        guard StudioFeatures.shared.isOn(.commandCenter), let captures = proof.record?.captures, !captures.isEmpty else { return ([], [:]) }
        var blockOfRow: [String: String] = [:]
        for block in model.blocks {
            switch block {
            case .row(let row), .task(let row, _): blockOfRow[row.id] = block.id
            case .group(let id, _, let rows): for row in rows { blockOfRow[row.id] = id }
            }
        }
        var first: [TimelineLayout.MediaPlacement] = [], after: [String: [TimelineLayout.MediaPlacement]] = [:]
        for placement in TimelineLayout.mediaRows(captures: captures, rows: model.timeline.rows) {
            if let row = placement.after {
                // A row that is in no block (the timeline moved on) goes after the last one.
                if let block = blockOfRow[row] ?? model.blocks.last?.id { after[block, default: []].append(placement) } else { first.append(placement) }
            } else {
                first.append(placement)
            }
        }
        return (first, after)
    }

    private var context: TimelineContext {
        let cwd = model.link?.cwd
        return TimelineContext(
            root: cwd,
            liveToolID: model.timeline.live.tool?.id,
            liveSince: model.timeline.live.tool?.since,
            checks: proof.record?.checks ?? [],
            captures: StudioFeatures.shared.isOn(.commandCenter) ? proof.record?.captures ?? [] : [],
            setupExists: proof.setupExists,
            hasPassingRun: proof.hasPassingRun,
            finishedReplies: model.finishedReplies,
            explainers: ExplainerModel.isEnabled ? explainers : nil,
            open: { [weak controller = model.controller] url in
                Self.openLink(url, window: controller?.window, directory: cwd)
            },
            openPath: { [weak controller = model.controller] path in
                guard let window = controller?.window ?? NSApp.keyWindow else { return }
                _ = GlanceEditorHost.openFromPane(path, from: window, directory: cwd)
            })
    }

    /// A link in Claude's prose: a pull request or issue stays in Studio, a web page opens in the Glance browser, a
    /// file path in Razor (or Quick Look for pictures and documents).
    @MainActor static func openLink(_ url: URL, window: NSWindow?, directory: String?) {
        let window = window ?? NSApp.keyWindow
        let text = url.absoluteString
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // The tab's browser column is open: web pages load there, beside the session.
            if case .browser(let page) = AutomationLinks.route(text), BrowserColumn.isEnabled,
               let controller = BrowserColumn.controller(window), controller.browserColumnOpen {
                BrowserColumn.open(page, in: controller)
                return
            }
            if case .browser(let page) = AutomationLinks.route(text), StudioFeatures.shared.isOn(.browser),
               BrowserTabController.open(url: page, from: window) != nil { return }
            AutomationLinkOpener.open(text, from: window)
            return
        }
        guard let window else { return }
        _ = GlanceEditorHost.openFromPane(text, from: window, directory: directory)
    }
}

/// How far the viewport is from the end of the content. Content shorter than the viewport counts as at the bottom.
private struct ScrollMetrics: Equatable {
    var content: CGFloat = 0
    var visibleMaxY: CGFloat = 0
    var container: CGFloat = 0
    var isNearBottom: Bool { content - visibleMaxY <= 48 }
}

/// What the rows need from the view: where the session runs, which tool is running, how links open.
struct TimelineContext {
    var root: String?
    var liveToolID: String?
    var liveSince: Date?
    /// Inside a subagent: no rail, rows sit in the Task's own rule.
    var nested = false
    /// The proof's check runs: a Bash row finds its own by tool call id (`checkRun(forTool:)`).
    var checks: [ProofCheckRun] = []
    /// The proof's captures: a screenshot row finds its own by tool call id and carries its Outcome or Testing tag.
    /// Empty with the command center off.
    var captures: [ProofCapture] = []
    /// The project has a valid proof setup, so a claim that tests pass can be checked against runs.
    var setupExists = false
    var hasPassingRun = false
    /// The prose rows that end a finished turn: they carry the reply's actions.
    var finishedReplies: Set<String> = []
    /// With Explainer mode's feature on: what can turn a reply into a page.
    var explainers: ExplainerModel?
    let open: (URL) -> Void
    let openPath: (String) -> Void

    /// The run Glance recorded for this tool call (a run's id is its tool call's id), never matched by command text.
    func checkRun(forTool id: String) -> ProofCheckRun? { checks.first { $0.id == id } }
}

// MARK: Blocks

struct TimelineBlockView: View {
    let block: TimelineBlock
    let ctx: TimelineContext

    var body: some View {
        switch block {
        case .row(let row): TimelineRowView(row: row, ctx: ctx)
        case .group(_, let label, let rows): ToolGroupView(label: label, rows: rows, ctx: ctx)
        case .task(let row, let children): TaskBlockView(row: row, children: children, ctx: ctx)
        }
    }
}

/// Reads, searches and fetches in a row: one quiet line, opening to what each one was.
private struct ToolGroupView: View {
    let label: String
    let rows: [TimelineRow]
    let ctx: TimelineContext
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StudioIcon(icon, size: 13)
                    Text(label).font(.studio(12.5)).lineLimit(1).truncationMode(.tail)
                    StudioIcon(open ? .chevronDown : .chevronRight, size: 11).opacity(0.6)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioColors.muted)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        Text(Self.detail(row))
                            .font(.studioMono(12)).foregroundStyle(StudioColors.body)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.leading, 21).padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .modifier(StepRail(enabled: !ctx.nested))
        .padding(.vertical, 2)
    }

    private var icon: StudioIcons.Name {
        guard let first = rows.first, case .tool(_, let kind, _, _) = first.kind else { return .docs }
        switch kind {
        case .search: return .search
        case .web: return .globe
        default: return .docs
        }
    }

    private static func detail(_ row: TimelineRow) -> String {
        guard case .tool(_, let kind, _, _) = row.kind else { return "" }
        return toolDetail(kind)
    }
}

/// A subagent: "Agent · summary" with its own rows under a 2pt rule; collapsed once it has a result.
private struct TaskBlockView: View {
    let row: TimelineRow
    let children: [TimelineBlock]
    let ctx: TimelineContext
    @State private var open: Bool

    init(row: TimelineRow, children: [TimelineBlock], ctx: TimelineContext) {
        self.row = row
        self.children = children
        self.ctx = ctx
        var settled = false
        if case .tool(_, _, let result, _) = row.kind { settled = result != nil }
        _open = State(initialValue: !settled)
    }

    @ViewBuilder var body: some View {
        if case .tool(_, .task(let summary), let result, let denied) = row.kind {
            let running = result == nil && ctx.liveToolID == row.id
            VStack(alignment: .leading, spacing: 0) {
                Button { open.toggle() } label: {
                    HStack(spacing: 8) {
                        StudioIcon(.agents, size: 13).foregroundStyle(StudioColors.muted)
                        Text("Agent · \(summary)").font(.studio(13, .medium)).foregroundStyle(StudioColors.body)
                            .lineLimit(1).truncationMode(.tail)
                        if running { TimelineSpinner() }
                        if denied { DeniedChip() } else if result?.isError == true { FailedMark() }
                        StudioIcon(open ? .chevronDown : .chevronRight, size: 11)
                            .foregroundStyle(StudioColors.muted).opacity(0.6)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                if open, !children.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(children) { TimelineBlockView(block: $0, ctx: nestedContext) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(StudioColors.line3).frame(width: 2) }
                    .padding(.leading, 2)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var nestedContext: TimelineContext {
        var child = ctx
        child.nested = true
        return child
    }
}

// MARK: Rows

struct TimelineRowView: View {
    let row: TimelineRow
    let ctx: TimelineContext

    var body: some View {
        switch row.kind {
        case .user(let text, let images): UserRow(text: text, images: images, time: row.time)
        case .prose(let markdown): ProseRow(id: row.id, markdown: markdown, ctx: ctx)
        case .tool(let name, let kind, let result, let denied):
            ToolRow(row: row, name: name, kind: kind, result: result, denied: denied, ctx: ctx)
        case .command(let name, let output): CommandRow(name: name, output: output)
        case .compact: CompactRow()
        }
    }
}

/// The recap a session was started with, folded to one line that opens on a click.
private struct RecapContextRow: View {
    let context: String
    @State private var open = false

    /// The notes and commits in it, not its heading or the "Commits:" label.
    private var items: Int { context.split(separator: "\n").filter { $0.hasPrefix("- ") }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text("Recap as context").font(.studio(12.5, .medium))
                    if items > 0 { Text("\(items) \(items == 1 ? "item" : "items")").font(.studio(12)).foregroundStyle(StudioColors.muted) }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioColors.body)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                Text(context).font(.studio(12.5)).lineSpacing(3).foregroundStyle(StudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
    }
}

/// A prompt starts a turn: a card with who and when above it.
private struct UserRow: View {
    let text: String
    let images: [TimelineImage]
    let time: Date?

    private var parts: (context: String?, typed: String) { RecapText.split(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.studio(11, .medium)).foregroundStyle(StudioColors.muted)
            VStack(alignment: .leading, spacing: 10) {
                // A session started from a worktree recap carries it ahead of what was typed: one folded line, not a wall.
                if let context = parts.context { RecapContextRow(context: context) }
                if !parts.typed.isEmpty {
                    Text(parts.typed)
                        .font(.studio(15)).lineSpacing(9).foregroundStyle(StudioColors.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !images.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in ImageThumb(image: image) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(StudioColors.line, lineWidth: 1))
        }
        .padding(.top, 24).padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private var caption: String {
        guard let time else { return "You" }
        return "You · " + Self.relative.localizedString(for: time, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ProseRow: View {
    let id: String
    let markdown: String
    let ctx: TimelineContext
    @State private var media: [String] = []
    /// Whether the text says tests pass; read once per text, off the main thread.
    @State private var claimsPass = false

    private var prose: some View {
        VStack(alignment: .leading, spacing: 10) {
            if ctx.nested {
                GlanceMarkdown(markdown: markdown, size: 15, open: ctx.open)
            } else {
                GlanceMarkdown(markdown: markdown, size: 15.5, lineSpacing: 5, reading: true, open: ctx.open)
            }
            ForEach(media, id: \.self) { MediaView(path: $0) }
            if claimsPass, ctx.setupExists, !ctx.hasPassingRun { ProofClaimFlag() }
        }
    }

    var body: some View {
        Group {
            if !ctx.nested, ctx.finishedReplies.contains(id) {
                if let explainers = ctx.explainers {
                    ExplainableReply(id: id, markdown: markdown, explainers: explainers) { prose }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        prose
                        ReplyActions(id: id, markdown: markdown)
                    }
                }
            } else {
                prose
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .task(id: markdown) {
            let text = markdown
            let claim = await Task.detached(priority: .utility) { ProofReview.claimsPass(text) }.value
            guard !Task.isCancelled else { return }
            claimsPass = claim
        }
        .task(id: markdown) {
            media = MediaLinks.find(in: markdown, root: ctx.root, home: NSHomeDirectory())
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
    }
}

private struct CommandRow: View {
    let name: String
    let output: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ran \(name.hasPrefix("/") ? name : "/" + name)")
                .font(.studio(12.5)).foregroundStyle(StudioColors.muted)
            if let output, !output.isEmpty { ToolOutput(output: output, failed: false, muted: true) }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(StudioColors.line).frame(height: 1)
            Text("Context compacted").font(.studio(11, .medium)).foregroundStyle(StudioColors.muted).fixedSize()
            Rectangle().fill(StudioColors.line).frame(height: 1)
        }
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Tool rows

private func toolDetail(_ kind: ToolKind) -> String {
    switch kind {
    case .read(let path), .edit(let path, _), .write(let path, _): path
    case .search(let pattern, let path): path.map { "\(pattern)  in \($0)" } ?? pattern
    case .bash(let command, _): command
    case .task(let text), .web(let text), .other(let text): text
    }
}

private struct ToolRow: View {
    let row: TimelineRow
    let name: String
    let kind: ToolKind
    let result: ToolResult?
    let denied: Bool
    let ctx: TimelineContext

    private var running: Bool { result == nil && ctx.liveToolID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch kind {
            case .edit(let path, let diff): EditRow(rowID: row.id, path: path, diff: diff, result: result, denied: denied)
            case .write(let path, let lines):
                WriteRow(path: path, lines: lines, result: result, denied: denied, openPath: ctx.openPath)
            case .bash(let command, let summary):
                BashRow(command: command, summary: summary, result: result, denied: denied,
                        running: running, since: ctx.liveSince, check: ctx.checkRun(forTool: row.id))
            default:
                GenericToolRow(name: name, detail: toolDetail(kind), result: result, denied: denied, running: running)
            }
            if let result, !result.images.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        ForEach(Array(result.images.enumerated()), id: \.offset) { _, image in ImageThumb(image: image) }
                    }
                    if let tag = AssetGroups.timelineTag(rowID: row.id, captures: ctx.captures) { CaptureTag(group: tag) }
                }
                .padding(.vertical, 6)
            }
        }
        .modifier(StepRail(enabled: !ctx.nested, active: running))
        .padding(.vertical, 2)
    }
}

/// `pencil path +N −M`, the diff behind a disclosure.
private struct EditRow: View {
    /// The row's id: a row's diff never changes, so it identifies the content to count.
    let rowID: String
    let path: String
    let diff: [DiffLine]
    let result: ToolResult?
    let denied: Bool
    @State private var open = false
    /// Counted off the main thread; nil until then.
    @State private var counts: (added: Int, removed: Int)?

    private static let cap = 4000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    StudioIcon(.pencil, size: 13).foregroundStyle(StudioColors.muted)
                    Text(path).font(.studioMono(12)).foregroundStyle(StudioColors.muted)
                        .lineLimit(1).truncationMode(.middle)
                    if let counts {
                        Text("+\(counts.added)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.ok)
                        Text("−\(counts.removed)").font(.studioMono(12, .medium)).foregroundStyle(StudioColors.danger)
                    }
                    if denied { DeniedChip() } else if result?.isError == true { FailedMark() }
                    StudioIcon(open ? .chevronDown : .chevronRight, size: 11)
                        .foregroundStyle(StudioColors.muted).opacity(0.6)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(counts.map { "Edited \(path), \($0.added) added, \($0.removed) removed" } ?? "Edited \(path)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.prefix(Self.cap).enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(sign(line.mark)).frame(width: 26)
                                .foregroundStyle(line.mark == .added ? StudioColors.ok
                                                 : line.mark == .removed ? StudioColors.danger : StudioColors.muted)
                            Text(line.text.isEmpty ? " " : line.text).foregroundStyle(StudioColors.ink)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .font(.studioMono(12))
                        .padding(.trailing, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(line.mark == .added ? StudioColors.okFill
                                    : line.mark == .removed ? StudioColors.dangerFill : Color.clear)
                    }
                    if diff.count > Self.cap {
                        Text("Diff cut — open the file for the rest").font(.studio(11.5))
                            .foregroundStyle(StudioColors.muted).padding(8)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line, lineWidth: 1))
                .textSelection(.enabled)
                .padding(.top, 2).padding(.bottom, 8)
            }
        }
        .task(id: rowID) {
            let lines = diff
            let result = await Task.detached(priority: .utility) { TimelineLayout.counts(lines) }.value
            guard !Task.isCancelled else { return }
            counts = result
        }
    }

    private func sign(_ mark: DiffLine.Mark) -> String {
        switch mark {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }
}

private struct WriteRow: View {
    let path: String
    let lines: Int
    let result: ToolResult?
    let denied: Bool
    let openPath: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            StudioIcon(.fileNew, size: 13)
            Text("Wrote").font(.studio(13))
            Button { openPath(path) } label: {
                Text(path).font(.studioMono(12)).lineLimit(1).truncationMode(.middle).frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(path)")
            Text("· \(lines) \(lines == 1 ? "line" : "lines")").font(.studio(13))
            if denied { DeniedChip() } else if result?.isError == true { FailedMark() }
            Spacer(minLength: 0)
        }
        .foregroundStyle(StudioColors.muted)
        .frame(minHeight: 28)
    }
}

/// `$ command` with an exit badge. A failure shows the lines that explain it; a success keeps its output collapsed
/// behind the command line (click it to open).
private struct BashRow: View {
    let command: String
    let summary: String?
    let result: ToolResult?
    let denied: Bool
    let running: Bool
    /// When the running tool started, if the transcript said.
    let since: Date?
    /// The check run Glance recorded for this very call, when the command is one of the project's checks.
    var check: ProofCheckRun?
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if collapsible {
                Button { open.toggle() } label: { header.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .onHover { hovering = $0 }
                    .help(open ? "Hide output" : "Show output")
                    .accessibilityHint(open ? "Hides the output" : "Shows the output")
            } else {
                header
            }
            if let check, result != nil, !denied, !running { ProofCheckStrip(run: check).padding(.top, 4) }
            if let summary, !summary.isEmpty {
                Text(summary).font(.studio(12)).foregroundStyle(StudioColors.muted).lineLimit(2)
            }
            if let result, !result.output.isEmpty, !collapsible || open {
                ToolOutput(output: result.output, failed: code(result) != 0).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }

    /// A finished, successful command with output.
    private var collapsible: Bool {
        guard let result, !denied, !running, !result.output.isEmpty else { return false }
        return code(result) == 0
    }

    private var header: some View {
            HStack(spacing: 8) {
                StudioIcon(.terminal, size: 13).foregroundStyle(StudioColors.muted)
                (Text("$ ").foregroundStyle(StudioColors.muted) + Text(command).foregroundStyle(StudioColors.ink))
                    .font(.studioMono(12.5, .medium))
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if denied {
                    DeniedChip()
                } else if running {
                    RunningBadge(since: since)
                } else if let result {
                    ExitBadge(code: code(result))
                }
                if collapsible {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 30)
            .accessibilityElement(children: .combine)
    }

    private func code(_ result: ToolResult) -> Int { result.exitCode ?? (result.isError ? 1 : 0) }
}

/// A tool that wasn't folded into a group (it failed, was denied, or has no special row): `name · detail`.
private struct GenericToolRow: View {
    let name: String
    let detail: String
    let result: ToolResult?
    let denied: Bool
    let running: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(detail.isEmpty ? name : "\(name) · \(detail)")
                .font(.studio(13)).foregroundStyle(StudioColors.muted)
                .lineLimit(1).truncationMode(.middle)
            if denied { DeniedChip() } else if result?.isError == true { FailedMark() }
            if running { TimelineSpinner() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}

// MARK: Output

/// Command output on a chip: the first lines (for a failure, the lines that explain it and the last few), the rest
/// behind a button; unfolded text stops at 4,000 lines.
private struct ToolOutput: View {
    let output: String
    let failed: Bool
    var muted = false
    @State private var expanded = false
    /// Split and folded off the main thread; nil until then (a cut of the raw text stands in).
    @State private var fold: OutputFold?

    private struct Key: Equatable {
        let output: String
        let failed: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fold {
                if expanded {
                    box(fold.expanded, scrolls: fold.total > 40)
                    if fold.cut {
                        Text("Output cut — open the terminal for the rest")
                            .font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                    }
                    if fold.label != nil { moreButton("Show less") }
                } else {
                    box(fold.shown, scrolls: false)
                    if let label = fold.label { moreButton(label) }
                }
            } else {
                box(String(output.prefix(400)), scrolls: false)
            }
        }
        .task(id: Key(output: output, failed: failed)) {
            let (text, failed) = (output, failed)
            let folded = await Task.detached(priority: .utility) { OutputFold.make(text, failed: failed) }.value
            // A newer output cancelled this task; its result must not overwrite the newer one.
            guard !Task.isCancelled else { return }
            fold = folded
        }
    }

    private func box(_ text: String, scrolls: Bool) -> some View {
        let content = Text(text)
            .font(.studioMono(12)).lineSpacing(3)
            .foregroundStyle(muted ? StudioColors.muted : StudioColors.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
        return Group {
            if scrolls { ScrollView(.vertical) { content }.frame(maxHeight: 520) } else { content }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(failed ? StudioColors.dangerFill : StudioColors.chip))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(failed ? StudioColors.danger.opacity(0.35) : StudioColors.line2, lineWidth: 1))
    }

    private func moreButton(_ title: String) -> some View {
        Button { expanded.toggle() } label: {
            Text(title).font(.studio(12, .medium)).foregroundStyle(StudioColors.body)
                .padding(.horizontal, 10).frame(minHeight: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(StudioColors.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A command's output ready to show: the folded text, the unfolded text (cut at 4,000 lines), the button's label.
private struct OutputFold: Sendable {
    let total: Int
    let shown: String
    let expanded: String
    let cut: Bool
    let label: String?

    private static let cap = 4000

    nonisolated static func make(_ output: String, failed: Bool) -> OutputFold {
        let text = output.trimmingCharacters(in: .newlines)
        let lines = text.components(separatedBy: "\n")
        let folded = failed ? TimelineLayout.foldFailure(text) : TimelineLayout.fold(text)
        let cut = lines.count > cap
        return OutputFold(total: lines.count, shown: folded.shown,
                          expanded: cut ? lines.prefix(cap).joined(separator: "\n") : text, cut: cut,
                          label: TimelineLayout.expandLabel(total: lines.count, hidden: folded.hidden, failed: failed))
    }
}

// MARK: Small parts

/// The left rail tool rows sit on: a hairline with a dot (teal while the row runs).
private struct StepRail: ViewModifier {
    var enabled = true
    var active = false

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.leading, 22)
                .background(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(StudioColors.line).frame(width: 1).padding(.leading, 6)
                        Circle().fill(active ? StudioColors.tealFill : StudioColors.background)
                            .overlay(Circle().stroke(active ? StudioColors.tealInk : StudioColors.line3, lineWidth: 1.5))
                            .frame(width: 7, height: 7)
                            .padding(.leading, 3).padding(.top, 11)
                    }
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
        } else {
            content
        }
    }
}

private struct ExitBadge: View {
    let code: Int

    var body: some View {
        HStack(spacing: 4) {
            if code != 0 { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
            Text("exit \(code)").font(.studioMono(11, .medium))
        }
        .foregroundStyle(code == 0 ? StudioColors.muted : StudioColors.danger)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(code == 0 ? StudioColors.line3 : StudioColors.danger.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(code == 0 ? "Exit code 0" : "Failed, exit code \(code)")
    }
}

private struct RunningBadge: View {
    let since: Date?

    var body: some View {
        HStack(spacing: 6) {
            TimelineSpinner()
            if let since {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(since: since, now: context.date))
                        .font(.studioMono(11, .medium)).monospacedDigit()
                }
            } else {
                Text("running").font(.studioMono(11, .medium))
            }
        }
        .foregroundStyle(StudioColors.tealInk)
    }
}

private struct DeniedChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            Text("Denied").font(.studio(11, .medium))
        }
        .foregroundStyle(StudioColors.danger)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(StudioColors.dangerFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Denied")
    }
}

private struct FailedMark: View {
    var body: some View {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(StudioColors.danger)
            .accessibilityLabel("Failed")
    }
}

private func elapsed(since: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(since)))
    return seconds < 60 ? "\(seconds)s" : String(format: "%dm %02ds", seconds / 60, seconds % 60)
}

/// An arc turning while a tool runs; held still with Reduce Motion.
private struct TimelineSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = false

    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(StudioColors.tealInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(spin && !reduceMotion ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
            }
            .accessibilityLabel("Running")
    }
}

// MARK: Live line

/// Under the last row: what Claude is doing right now, or that it waits for you. Nothing when idle.
private struct TimelineLiveLine: View {
    let live: SessionLive
    let waiting: Bool

    @ViewBuilder var body: some View {
        if waiting {
            HStack(spacing: 8) {
                Circle().stroke(StudioColors.amber, lineWidth: 2).frame(width: 8, height: 8)
                Text("Waiting on you").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.amber)
            }
            .accessibilityElement(children: .combine)
        } else if live.working, let tool = live.tool {
            HStack(spacing: 8) {
                TimelineSpinner()
                Text("running").font(.studio(12.5, .medium))
                Text(tool.detail.isEmpty ? tool.name : tool.detail)
                    .font(.studioMono(12)).lineLimit(1).truncationMode(.tail)
                if let since = tool.since {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(since: since, now: context.date))
                            .font(.studioMono(11)).monospacedDigit().foregroundStyle(StudioColors.muted)
                    }
                }
            }
            .foregroundStyle(StudioColors.tealInk)
            .accessibilityElement(children: .combine)
        } else if live.working {
            HStack(spacing: 8) {
                PulseDot()
                Text("Thinking").font(.studio(12.5, .medium)).foregroundStyle(StudioColors.tealInk)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Teal, with a ring that spreads and fades; still with Reduce Motion.
struct PulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(StudioColors.tealInk).frame(width: 8, height: 8)
            .background(
                Circle().stroke(StudioColors.tealInk.opacity(!reduceMotion && pulse ? 0 : 0.5), lineWidth: 2)
                    .scaleEffect(!reduceMotion && pulse ? 2 : 1)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

// MARK: Pictures and clips

/// Outcome or Testing under a screenshot: the glyph and the word, so the colour is not the only cue.
private struct CaptureTag: View {
    let group: AssetItem.Group

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: group.symbol).font(.system(size: 11, weight: .semibold))
            Text(group.label).font(.studio(11, .semibold))
        }
        .foregroundStyle(group.tint)
        .accessibilityElement(children: .combine)
    }
}

/// A clip or an explainer, in the timeline at the time it was made: its first frame with a play glyph and its length.
/// Click for Quick Look, which plays it.
private struct TimelineMediaRow: View {
    let capture: ProofCapture
    let url: URL
    @State private var frame: CGImage?
    @State private var duration: Double?
    @State private var missing = false

    private var isExplainer: Bool { capture.kind == .explainer }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { QuickLookPreview.shared.show(url.path) } label: {
                ZStack {
                    StudioColors.mediaBack
                    if let frame { Image(decorative: frame, scale: 2).resizable().scaledToFill() }
                    if missing {
                        VStack(spacing: 4) {
                            Image(systemName: "film").font(.system(size: 18))
                            Text("Couldn't load").font(.studio(11, .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.65))
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(StudioColors.mediaScrim.opacity(0.78)))
                    }
                }
                .frame(width: 168, height: 105)
                .overlay(alignment: .bottomTrailing) {
                    if let duration, !missing {
                        Text(String(format: "%d:%02d", Int(duration.rounded()) / 60, Int(duration.rounded()) % 60))
                            .font(.studioMono(11)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(StudioColors.mediaScrim.opacity(0.75)))
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line3, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(missing)
            .accessibilityLabel("\(isExplainer ? "Video" : "Clip")\(capture.caption.isEmpty ? "" : ": " + capture.caption)")
            .accessibilityHint(missing ? "The file is missing" : "Opens a preview that plays it")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: isExplainer ? "film" : "play.rectangle").font(.system(size: 11, weight: .semibold))
                    Text(isExplainer ? "Video" : "Clip").font(.studio(11, .semibold))
                }
                .foregroundStyle(StudioColors.muted)
                if !capture.caption.isEmpty {
                    Text(capture.caption).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink).lineLimit(2)
                }
                if let environment = capture.environment, !environment.isEmpty {
                    Text(environment).font(.studio(11.5)).foregroundStyle(StudioColors.muted).lineLimit(1)
                }
                if let tag = AssetGroups.timelineTag(rowID: capture.id, captures: [capture]) { CaptureTag(group: tag) }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .task(id: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { missing = true; return }
            missing = false
            frame = await VideoThumbnail.image(of: url, maxSide: 336)
            duration = await VideoThumbnail.duration(of: url)
        }
    }
}

/// A picture the user pasted or a tool returned: a 120pt thumbnail, click for Quick Look over the window.
private struct ImageThumb: View {
    let image: TimelineImage
    @State private var picture: NSImage?

    var body: some View {
        Group {
            if let picture {
                Button { preview() } label: {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line3, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Image")
                .accessibilityHint("Opens a preview")
            } else {
                RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip).frame(width: 120, height: 120)
            }
        }
        .task { picture = NSImage(data: image.data) }
    }

    /// Quick Look reads files, so the bytes go to a temporary one first.
    private func preview() {
        let ext = image.mediaType.hasSuffix("jpeg") ? "jpg" : String(image.mediaType.split(separator: "/").last ?? "png")
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("glance-session-images")
        let path = (folder as NSString).appendingPathComponent("\(image.data.hashValue.magnitude).\(ext)")
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? image.data.write(to: URL(fileURLWithPath: path))
        }
        QuickLookPreview.shared.show(path)
    }
}

/// A local picture or clip Claude's reply mentions, inline: pictures up to 280pt high, clips paused until played.
private struct MediaView: View {
    let path: String
    @State private var picture: NSImage?
    @State private var player: AVPlayer?

    private var kind: MediaLinks.Kind? { MediaLinks.kind(of: path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch kind {
            case .video:
                Group {
                    if let player { VideoPlayer(player: player) } else { Color.clear }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: 560)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line3, lineWidth: 1))
                .onAppear { if player == nil { player = AVPlayer(url: URL(fileURLWithPath: path)) } }
                .onDisappear { player?.pause() }
            case .image:
                if let picture {
                    Button { QuickLookPreview.shared.show(path) } label: {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 280)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(StudioColors.line3, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((path as NSString).lastPathComponent)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(StudioColors.chip).frame(width: 200, height: 120)
                }
            case nil:
                EmptyView()
            }
            HStack(spacing: 8) {
                Text((path as NSString).lastPathComponent).font(.studio(12)).foregroundStyle(StudioColors.body)
                    .lineLimit(1).truncationMode(.middle)
                Button { QuickLookPreview.shared.show(path) } label: {
                    Text("Open").font(.studio(12, .medium)).foregroundStyle(StudioColors.coralInk)
                        .frame(minWidth: 36, minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            guard kind == .image, picture == nil else { return }
            let path = path
            let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                DispatchQueue.global(qos: .utility).async { continuation.resume(returning: NSImage(contentsOfFile: path)) }
            }
            picture = loaded
        }
    }
}
