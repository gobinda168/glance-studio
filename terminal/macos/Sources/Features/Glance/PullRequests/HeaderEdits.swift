import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The header's title in place (spec 2026-10-12-pr-sidebar-tabs-design.md, "Title and base"): the field, Save (⏎) and
/// Cancel (Esc). It closes once the new title is saved; a failure stays under it.
struct TitleEditor: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    let close: () -> Void
    @State private var draft = ""

    var body: some View {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StudioField(placeholder: "Title", text: $draft, height: 38, font: .studio(17, .semibold)) { save(title) }
                    .onExitCommand(perform: close)
                StudioButton(title: "Cancel", style: .quiet, action: close)
                StudioButton(title: "Save", style: .primary, busy: entry.busy.contains("title"),
                             enabled: !title.isEmpty) { save(title) }
            }
            if let error = entry.errors["title"] { InlineError(message: error) }
        }
        .onAppear { draft = page.title }
    }

    private func save(_ title: String) {
        guard !title.isEmpty else { return }
        guard title != page.title else { return close() }
        PullRequestStore.shared.perform(.editTitle(title), key: controller.key, root: controller.root) { close() }
    }
}

/// The branch it merges into: the chip, and while the pull request is open, a button that opens the base picker.
struct BaseBranchButton: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @State private var picking = false
    @State private var hovering = false

    var body: some View {
        if page.state == .open {
            Button { picking = true } label: {
                HStack(spacing: 3) {
                    BranchChip(page.base, size: 11.5)
                    if entry.busy.contains("base") {
                        ProgressView().controlSize(.mini)
                    } else {
                        StudioIcon(.chevronDown, size: 11)
                            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(entry.busy.contains("base"))
            .onHover { hovering = $0 }
            .help("Change the Base Branch")
            .accessibilityLabel("Base branch: \(page.base)")
            .accessibilityHint("Changes the branch it merges into")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                BasePicker(controller: controller, page: page) { picking = false }
            }
        } else {
            BranchChip(page.base, size: 11.5)
        }
    }
}

/// The base picker: the repository's branches (read when it opens), a filter, the current base ticked. ⏎ picks the
/// first match. Picking another branch runs `gh pr edit --base`.
private struct BasePicker: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let close: () -> Void
    @State private var branches: [String]?
    @State private var failed = false
    @State private var filter = ""

    var body: some View {
        let rows = branches.map { PullRequestActions.baseChoices($0, head: page.head, base: page.base, filter: filter) }
        VStack(alignment: .leading, spacing: 8) {
            Caption("Merge into")
            StudioField(placeholder: "Filter branches", text: $filter) {
                if let first = rows?.first { choose(first) }
            }
            if let rows {
                if rows.isEmpty {
                    Text(filter.isEmpty ? "No other branches." : "No branch matches “\(filter)”.")
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .padding(.vertical, 4)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(rows, id: \.self) { name in
                                BaseRow(name: name, isBase: name == page.base) { choose(name) }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
            } else if failed {
                InlineError(message: "Couldn't read the branches.") { load() }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading branches…").font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear(perform: load)
    }

    private func load() {
        failed = false
        PullRequestStore.shared.lookup(PullRequestActions.branchList(repository: controller.key.repository),
                                       parse: PullRequestActions.parseBranches) { names in
            if let names { branches = names } else { failed = true }
        }
    }

    private func choose(_ name: String) {
        close()
        guard name != page.base else { return }
        PullRequestStore.shared.perform(.editBase(name), key: controller.key, root: controller.root)
    }
}

/// A branch in the base picker: its name in mono, ticked when it's the base.
private struct BaseRow: View {
    let name: String
    let isBase: Bool
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 8) {
                StudioIcon(.check, size: 12, weight: 2.2)
                    .foregroundStyle(StudioColors.coralInk)
                    .opacity(isBase ? 1 : 0)
                Text(name)
                    .font(.studioMono(12, isBase ? .semibold : .regular))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isBase ? [.isSelected] : [])
    }
}
