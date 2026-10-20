import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Terminal and Editor side bars of the activity strip (spec 2026-10-07-activity-strip-design.md): the tabs of the
/// window's tab group, flat on the design's bar colour. Terminal lists the terminal tabs (Home is the top bar's ⌂);
/// Editor lists the editor tabs. Other pages (Browser tabs, pull requests, Settings…) are reached from their own
/// side bars. Drag a row to move its tab; the selected tab's plate slides from row to row.
struct TabSidebarView: View {
    /// Which tabs it lists.
    enum Content {
        case terminals, editors

        var title: String {
            switch self {
            case .terminals: "Terminal"
            case .editors: "Editor"
            }
        }

        func lists(_ kind: TabRow.Kind) -> Bool {
            switch self {
            case .terminals: kind == .terminal
            case .editors: kind == .editor
            }
        }
    }

    let content: Content
    @ObservedObject private var model = TabSidebarModel.shared
    @ObservedObject private var rowsChange = TabSidebarModel.shared.rowsChange // redraws the rows
    @ObservedObject private var groups = TabGroups.shared
    @ObservedObject private var features = StudioFeatures.shared
    @State private var window: NSWindow?
    /// The tab list's height, for how far History may grow into it.
    @State private var tabsHeight: CGFloat = 0
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What a full-height History leaves the tab list: about one row.
    private static let tabsLeast: CGFloat = 84

    init(content: Content = .terminals) {
        self.content = content
    }

    var body: some View {
        let all = model.rows(for: window)
        let rows = all.filter { content.lists($0.kind) }
        let selected = all.first(where: \.isSelected)?.id
        VStack(spacing: 0) {
            SidebarHeader(title: content.title) {
                SidebarIconButton(icon: .plus, label: content == .terminals ? "New Tab" : "New Editor Tab") { newTab() }
            }
            SectionHeader(count: rows.count)
            let grouping = content == .terminals && features.isOn(.tabGroups)
            TabList(rows: rows, items: grouping ? groups.items(for: rows) : rows.map { .tab($0.id) },
                    grouping: grouping, selection: selection, model: model,
                    empty: content == .terminals ? "No terminal tabs" : "No editor tabs yet")
                .frame(minHeight: content == .terminals ? Self.tabsLeast : 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tabsHeight = $0 }
            if content == .terminals {
                SessionHistorySection(folder: projectFolder(all), selected: selected, window: window,
                                      spare: max(0, tabsHeight - Self.tabsLeast))
                SidebarPrimaryButton(icon: .terminal, title: "New Tab", hint: "⌘T") { newTab() }
            } else {
                SidebarPrimaryButton(icon: .editor, title: "New Editor Tab", hint: "⇧⌘E") { newTab() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(GlassChrome.move(reduceMotion), value: selected)
        .background(WindowAccessor { found in
            window = found
            if let found { model.watch(found) }
        })
    }

    /// The folder History lists: the selected terminal's, else any terminal tab's in this window's group.
    private func projectFolder(_ all: [TabRow]) -> String? {
        let candidates = (all.first(where: \.isSelected).map { [$0] } ?? []) + all.filter { $0.kind == .terminal }
        for row in candidates {
            if let directory = (row.window.windowController as? GlancePaneOwner)?.glanceDirectory, !directory.isEmpty {
                return directory
            }
        }
        return nil
    }

    private func newTab() {
        switch content {
        case .terminals: model.newTab(near: window)
        case .editors: GlanceTerminalHost.shared.newEditorTab()
        }
    }
}

// MARK: - The list

/// "OPEN TABS        3": the list's label and how many there are, as the design's group headers.
private struct SectionHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("OPEN TABS")
                .tracking(0.66)
            Spacer(minLength: 4)
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.studio(11, .semibold))
        .foregroundStyle(StudioColors.muted)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 tab" : "\(count) tabs")
        .accessibilityAddTraits(.isHeader)
    }
}

/// Where the rows report their frames, for dragging.
private let tabListSpace = "TabSidebar.TabList"

/// The tabs in tab order, grouped when groups are on: a group's header, then its rows (or, folded, its tabs as chips).
/// Dragging a row lifts it and everything else makes room; letting go moves the tab there, into the section above
/// where it lands (`TabSidebarModel.drop`), or, without groups, just there (`TabSidebarModel.move`).
private struct TabList: View {
    typealias Item = TabGroupLayout.Item<ObjectIdentifier>

    let rows: [TabRow]
    /// What it draws, top to bottom: every row without groups; headers and the rows of open groups with them.
    let items: [Item]
    /// The Terminal side bar with Tab Groups on: rows get the group menu and drops join groups.
    let grouping: Bool
    let selection: Namespace.ID
    let model: TabSidebarModel
    let empty: String
    @ObservedObject private var groups = TabGroups.shared
    @State private var drag: Drag?
    @State private var frames: [Item: CGRect] = [:]
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let spacing: CGFloat = 2

    /// The row being dragged and how far.
    private struct Drag: Equatable {
        let item: Item
        var translation: CGFloat
    }

    var body: some View {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let from = drag.flatMap { drag in items.firstIndex(of: drag.item) }
        let target = from.map { landing(from: $0) }
        ScrollView(.vertical) {
            VStack(spacing: Self.spacing) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    let dragged = index == from
                    let shift = shift(of: index, from: from, target: target)
                    let mine = group(of: item, byID)
                    let endsGroup = mine != nil && (index + 1 == items.count || group(of: items[index + 1], byID) != mine)
                    Group {
                        switch item {
                        case .tab(let id):
                            if let row = byID[id] { tabRow(row, dragged: dragged, quiet: from != nil && !dragged) }
                        case .header(let id):
                            if let info = groups.info(id) {
                                GroupHeader(info: info, rows: rows.filter { groups.group(of: $0.window) == id },
                                            allRows: rows, model: model)
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(tabListSpace)) } action: { frame in
                        if drag == nil { frames[item] = frame }
                    }
                    .padding(.bottom, endsGroup ? 6 : 0)
                    .offset(y: shift)
                    .animation(dragged ? nil : GlassChrome.move(reduceMotion), value: shift)
                    .zIndex(dragged ? 1 : 0)
                }
                if rows.isEmpty {
                    Text(empty)
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 2)
            .padding(.bottom, 8)
            .background(alignment: .topLeading) {
                if grouping { GroupWells(rects: wells(byID)) }
            }
            .coordinateSpace(.named(tabListSpace))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: pressing) { _, active in
            guard !active else { return }
            // `onEnded` has run by now when the drag ended; a drag the system cancelled never gets it: rows go back.
            DispatchQueue.main.async {
                if drag != nil { withAnimation(GlassChrome.move(reduceMotion)) { drag = nil } }
            }
        }
    }

    /// The group a drawn item belongs to: a header's own, a row's tab's.
    private func group(of item: Item, _ byID: [ObjectIdentifier: TabRow]) -> UUID? {
        guard grouping else { return nil }
        switch item {
        case .header(let id): return id
        case .tab(let id): return byID[id].flatMap { groups.group(of: $0.window) }
        }
    }

    /// Each group's well: around its header and rows as last measured (both inset 4 pt inside it), from just above the
    /// header's name to a little below its last row.
    private func wells(_ byID: [ObjectIdentifier: TabRow]) -> [CGRect] {
        var union: [UUID: CGRect] = [:]
        var order: [UUID] = []
        for item in items {
            guard let id = group(of: item, byID), var frame = frames[item] else { continue }
            if case .header = item { frame = CGRect(x: frame.minX, y: frame.minY + 4, width: frame.width, height: frame.height - 4) }
            if let known = union[id] { union[id] = known.union(frame) } else { union[id] = frame; order.append(id) }
        }
        return order.compactMap { id in union[id].map { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 4) } }
    }

    private func tabRow(_ row: TabRow, dragged: Bool, quiet: Bool) -> some View {
        let index = rows.firstIndex { $0.id == row.id } ?? 0
        let grouped = grouping && groups.group(of: row.window) != nil
        return TabRowView(
            row: row, selection: selection, lifted: dragged, quiet: quiet,
            onSelect: { model.select(row) },
            onClose: { model.close(row) },
            onSwitch: ProjectSwitch.direction(for: row.window) != nil
                ? { ProjectSwitch.toggle(row.window) } : nil,
            onFolder: row.window.windowController is TerminalController
                ? { TabGoToFolder.pick(for: row.window) } : nil,
            onMoveUp: index > 0 ? { model.move(row, toOffset: index - 1, in: rows) } : nil,
            onMoveDown: index < rows.count - 1 ? { model.move(row, toOffset: index + 2, in: rows) } : nil)
            .padding(.horizontal, grouped ? 4 : 0)
            .onTapGesture { model.select(row) }
            .gesture(reorder(.tab(row.id)))
            .contextMenu {
                if row.window.windowController is TerminalController {
                    Button("Rename…") { model.rename(row) }
                    Button("Go to Folder…") { TabGoToFolder.pick(for: row.window) }
                        .disabled(!GoToFolder.canType(runningCommand: row.command))
                }
                if grouping {
                    Divider()
                    GroupMenu(row: row, rows: rows, model: model)
                }
            }
    }

    private func reorder(_ item: Item) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(tabListSpace))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                if drag?.item != item { drag = Drag(item: item, translation: 0) }
                drag?.translation = clamped(value.translation.height, for: item)
            }
            .onEnded { _ in drop() }
    }

    /// Keeps the dragged row within the list.
    private func clamped(_ translation: CGFloat, for item: Item) -> CGFloat {
        guard let frame = frames[item], let first = items.first.flatMap({ frames[$0] }),
              let last = items.last.flatMap({ frames[$0] }) else { return translation }
        return min(max(translation, first.minY - frame.minY), last.maxY - frame.maxY)
    }

    /// Where the dragged row would land: past how many other items' middles it has been dragged.
    private func landing(from: Int) -> Int {
        guard let drag, let frame = frames[drag.item] else { return from }
        let middle = frame.midY + drag.translation
        return items.indices.filter { $0 != from && (frames[items[$0]]?.midY ?? .infinity) < middle }.count
    }

    /// The dragged row follows the pointer; the items it passed step over by its height to make room.
    private func shift(of index: Int, from: Int?, target: Int?) -> CGFloat {
        guard let drag, let from, let target else { return 0 }
        if index == from { return drag.translation }
        let room = (frames[drag.item]?.height ?? 0) + Self.spacing
        if from < target, index > from, index <= target { return -room }
        if target < from, index >= target, index < from { return room }
        return 0
    }

    private func drop() {
        guard let drag, let from = items.firstIndex(of: drag.item), case .tab(let id) = drag.item,
              let row = rows.first(where: { $0.id == id }) else {
            self.drag = nil
            return
        }
        let target = landing(from: from)
        let others = items.indices.filter { $0 != from }.map { items[$0] }
        let above = target > 0 ? others[target - 1] : nil
        withAnimation(GlassChrome.move(reduceMotion)) {
            self.drag = nil
            guard target != from else { return }
            if grouping {
                model.drop(row, below: above, in: rows)
            } else {
                // No groups (the Editor side bar, or the flag off): just the move, never a group.
                let place = TabGroupLayout.drop(below: above, tabs: rows.map(\.id), membership: [:], groups: [:])
                model.move(row, toOffset: place.toOffset, in: rows)
            }
        }
    }
}

// MARK: - Groups

/// Tab groups' wells (2026-10-12, the prototype's `groupstyle=well`): a quiet tinted panel with a hairline edge behind
/// each group's header and tabs, so loose tabs, on the bare side bar, read apart from grouped ones.
private struct GroupWells: View {
    let rects: [CGRect]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(StudioColors.hover)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(StudioColors.line, lineWidth: 0.75))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A group's header: chevron, name, how many tabs, and + on hover. A click folds or opens it, a double-click renames
/// it; folded, its tabs follow as chips. Right-click for Rename, New Tab in Group, Ungroup and Close Group.
private struct GroupHeader: View {
    let info: TabGroupInfo
    /// The group's rows, in tab order.
    let rows: [TabRow]
    /// Every row the side bar lists.
    let allRows: [TabRow]
    let model: TabSidebarModel
    @ObservedObject private var groups = TabGroups.shared
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var naming: Bool
    /// Each tab's window has its own side bar: only the front one's header opens the name field.
    @Environment(\.controlActiveState) private var active

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // The fold/rename clicks cover the name only, so they don't swallow the + beside it.
                HStack(spacing: 6) {
                    StudioIcon(info.isCollapsed ? .chevronRight : .chevronDown, size: 12)
                        .foregroundStyle(StudioColors.muted)
                        .frame(width: 14)
                    if groups.renaming == info.id && active == .key {
                        TextField("Group name", text: $draft)
                            .textFieldStyle(.plain)
                            .foregroundStyle(StudioColors.ink)
                            .padding(.horizontal, 5)
                            .frame(height: 20)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(StudioColors.hover))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(StudioColors.muted.opacity(0.5), lineWidth: 1))
                            .focused($naming)
                            .onSubmit(commit)
                            .onExitCommand { groups.renaming = nil }
                            .onAppear {
                                draft = info.name
                                naming = true
                                // The old name selected, so typing replaces it.
                                DispatchQueue.main.async {
                                    NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                                }
                            }
                            .onChange(of: naming) { _, focused in if !focused { commit() } }
                    } else {
                        Text(info.name.uppercased())
                            .tracking(0.66)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(StudioColors.body)
                    }
                    Text("\(rows.count)")
                        .monospacedDigit()
                        .foregroundStyle(StudioColors.muted)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { groups.renaming = info.id }
                    .exclusively(before: TapGesture().onEnded { model.setCollapsed(info.id, !info.isCollapsed) }))
                if hovering {
                    SidebarIconButton(icon: .plus, label: "New Tab in Group") {
                        model.newTab(inGroup: info.id, in: allRows)
                    }
                    .transition(.opacity)
                }
            }
            .font(.studio(11, .semibold))
            .padding(.leading, 8)
            .padding(.trailing, 2)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(GlassChrome.fade, value: hovering)
            if info.isCollapsed {
                GroupChips(rows: rows, model: model)
            }
        }
        .padding(.top, 6)
        .contextMenu {
            Button("Rename") { groups.renaming = info.id }
            Button("New Tab in Group") { model.newTab(inGroup: info.id, in: allRows) }
            Button(info.isCollapsed ? "Expand" : "Collapse") { model.setCollapsed(info.id, !info.isCollapsed) }
            Divider()
            Button("Ungroup") { model.ungroup(info.id, in: allRows) }
            Button("Close Group") { model.closeGroup(info.id, in: allRows) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(info.name), \(rows.count == 1 ? "1 tab" : "\(rows.count) tabs")\(info.isCollapsed ? ", folded" : "")")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: info.isCollapsed ? "Expand" : "Collapse") { model.setCollapsed(info.id, !info.isCollapsed) }
        .accessibilityAction(named: "Rename") { groups.renaming = info.id }
        .accessibilityAction(named: "Ungroup") { model.ungroup(info.id, in: allRows) }
    }

    /// Return or clicking away keeps the name (a blank one keeps the old name); Esc closes the field as it was.
    private func commit() {
        guard groups.renaming == info.id else { return }
        groups.rename(info.id, to: draft)
    }
}

/// A folded group's tabs as chips that wrap; a click brings that tab to the front.
private struct GroupChips: View {
    let rows: [TabRow]
    let model: TabSidebarModel

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(rows) { row in
                GroupChip(row: row) { model.select(row) }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.bottom, 4)
    }
}

private struct GroupChip: View {
    let row: TabRow
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                StudioIcon(row.studioIcon, size: 12)
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.studio(12, .medium))
            .foregroundStyle(row.isSelected || hovering ? StudioColors.ink : StudioColors.body)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: 180)
            .background(Capsule().fill(row.isSelected ? StudioColors.selection : hovering ? StudioColors.hover : StudioColors.chip))
            .overlay(Capsule().strokeBorder(row.isSelected ? StudioColors.coral.opacity(0.4) : .clear, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(GlassChrome.fade, value: hovering)
        .help(row.title)
        .accessibilityLabel(row.title)
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A terminal row's group items: Add to New Group, Add to Group ▸ or (in a group) Move to Group ▸ (the groups with tabs
/// in this window), Remove from Group.
private struct GroupMenu: View {
    let row: TabRow
    let rows: [TabRow]
    let model: TabSidebarModel

    var body: some View {
        let groups = TabGroups.shared
        let mine = groups.group(of: row.window)
        let others = groups.groups(in: rows).filter { $0.id != mine }
        Button("Add to New Group") { model.newGroup(with: row) }
        if !others.isEmpty {
            Menu(mine == nil ? "Add to Group" : "Move to Group") {
                ForEach(others) { info in
                    Button(info.name) { model.moveToGroup(row, info.id, in: rows) }
                }
            }
        }
        if mine != nil {
            Button("Remove from Group") { model.moveToGroup(row, nil, in: rows) }
        }
    }
}

// MARK: - A row

private struct TabRowView: View {
    let row: TabRow
    let selection: Namespace.ID
    /// Being dragged.
    var lifted = false
    /// Another row is being dragged: no hover light here.
    var quiet = false
    let onSelect: () -> Void
    let onClose: () -> Void
    /// Open in Editor (a terminal row) or Open in Terminal (an editor row), shown on hover; nil for other rows.
    var onSwitch: (() -> Void)?
    /// Go to Folder… (a terminal row), shown on hover; nil for other rows.
    var onFolder: (() -> Void)?
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { hovering && !quiet }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            KindChip(icon: row.studioIcon, lit: row.isSelected || lit)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.studio(12.5, row.isSelected ? .semibold : .medium))
                    .foregroundStyle(row.isSelected || lit ? StudioColors.ink : StudioColors.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.folder.isEmpty || row.branch != nil || row.panes > 1 {
                    Subline(folder: row.folder, branch: row.branch, panes: row.panes)
                }
                if let command = row.command {
                    CommandChip(command: command)
                        .padding(.top, 1)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            ZStack {
                if lit {
                    HStack(spacing: 2) {
                        if let onFolder { FolderButton(busyWith: row.command, action: onFolder) }
                        if let onSwitch { SwitchButton(toEditor: row.kind == .terminal, action: onSwitch) }
                        CloseButton(action: onClose)
                    }
                    .transition(.opacity)
                } else {
                    StatusBadges(row: row)
                        .transition(.opacity)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background { plate }
        .scaleEffect(lifted && !reduceMotion ? 1.02 : 1)
        .contentShape(RoundedRectangle(cornerRadius: SelectionPlate.radius, style: .continuous))
        .onHover { hovering = $0 }
        .animation(GlassChrome.fade, value: lit)
        .animation(GlassChrome.move(reduceMotion), value: lifted)
        .animation(GlassChrome.fade, value: row.command)
        .animation(GlassChrome.move(reduceMotion), value: row.claude)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityActions {
            Button("Close Tab", action: onClose)
            if let onSwitch { Button(row.kind == .terminal ? "Open in Editor" : "Open in Terminal", action: onSwitch) }
            if let onFolder, GoToFolder.canType(runningCommand: row.command) { Button("Go to Folder…", action: onFolder) }
            if let onMoveUp { Button("Move Up", action: onMoveUp) }
            if let onMoveDown { Button("Move Down", action: onMoveDown) }
        }
    }

    @ViewBuilder private var plate: some View {
        if row.isSelected {
            SelectionPlate.matched(in: selection, reduceMotion: reduceMotion)
        } else if lit || lifted {
            HoverPlate(lifted: lifted)
                .transition(.opacity)
        }
    }
}

/// A tab's kind at a glance: a small flat tile with its canvas icon (the prompt for a terminal, the brackets for an
/// editor, the house for Home).
private struct KindChip: View {
    let icon: StudioIcons.Name
    var lit = false

    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            tile.fill(lit ? StudioColors.chip : StudioColors.field)
            tile.strokeBorder(StudioColors.line, lineWidth: 0.75)
            StudioIcon(icon, size: 14)
                .foregroundStyle(lit ? StudioColors.ink : StudioColors.body)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// "folder ⑂ branch", whichever exist, in mono; the branch on its chip.
private struct Subline: View {
    let folder: String
    let branch: String?
    var panes = 1

    var body: some View {
        HStack(spacing: 6) {
            if !folder.isEmpty {
                Text(folder)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }
            if let branch {
                BranchChip(branch, size: 11)
            }
            if panes > 1 {
                SplitChip(panes: panes)
                    .layoutPriority(2)
            }
        }
        .font(.studioMono(11))
        .foregroundStyle(StudioColors.muted)
        .lineLimit(1)
    }
}

/// The tab is split: the panes' glyph and how many there are.
private struct SplitChip: View {
    let panes: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 9.5, weight: .semibold))
            Text("\(panes)")
                .font(.studioMono(10.5))
        }
        .foregroundStyle(StudioColors.body)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(StudioColors.field))
        .fixedSize()
        .help("\(panes) terminals in this tab")
        .accessibilityLabel("\(panes) split terminals")
    }
}

/// The program running in the tab as a mono chip, behind a prompt mark: coral when it's Claude.
private struct CommandChip: View {
    let command: String

    var body: some View {
        let claude = command == "claude" || command.hasPrefix("claude ")
        HStack(spacing: 4) {
            Text("›")
                .foregroundStyle(claude ? StudioColors.coralInk : StudioColors.muted)
                .accessibilityHidden(true)
            Text(command)
                .foregroundStyle(StudioColors.ink)
        }
        .font(.studioMono(11, .medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(claude ? StudioColors.selection : StudioColors.chip))
    }
}

/// The bell and Claude's status, as lights.
private struct StatusBadges: View {
    let row: TabRow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            if row.bell {
                LEDDot(color: GlassChrome.amber, size: 7)
                    .help("Bell")
                    .accessibilityLabel("Bell")
            }
            switch row.claude {
            case .thinking:
                ThinkingLight()
                    .help("Claude is thinking")
                    .accessibilityLabel("Claude is thinking")
            case .finished:
                ZStack {
                    Circle().fill(StudioColors.ok)
                    StudioIcon(.check, size: 9, weight: 3)
                        .foregroundStyle(Color.white)
                }
                .frame(width: 14, height: 14)
                .accessibilityElement()
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    .help("Claude finished")
                    .accessibilityLabel("Claude finished")
            case .idle:
                EmptyView()
            }
        }
    }
}

/// Claude is thinking in this tab: a teal light that pulses, as the orb does on Home and in the Glance pane.
private struct ThinkingLight: View {
    var body: some View {
        Breathing(period: 1.4, low: 0.35) {
            LEDDot(color: GlassChrome.teal, size: 8)
        }
        .frame(width: 10, height: 10)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(.close, size: 12)
                .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab")
        .accessibilityLabel("Close Tab")
    }
}

/// A terminal row's Go to Folder…, beside its Open in Editor on hover: dimmed while a program is in front, since the
/// `cd` would be typed into it.
private struct FolderButton: View {
    let busyWith: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let enabled = GoToFolder.canType(runningCommand: busyWith)
        // Not .disabled: a disabled button shows no tooltip, and the tooltip says what's in the way.
        Button { if enabled { action() } } label: {
            StudioIcon(.folder, size: 13)
                .foregroundStyle(hovering && enabled ? StudioColors.ink : StudioColors.muted)
                .opacity(enabled ? 1 : 0.45)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering && enabled ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(busyWith.map { "Busy: \($0)" } ?? "Go to Folder…")
        .accessibilityLabel("Go to Folder")
    }
}

/// A row's Open in Editor / Open in Terminal, beside its close button on hover.
private struct SwitchButton: View {
    let toEditor: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let label = toEditor ? "Open in Editor" : "Open in Terminal"
        Button(action: action) {
            Group {
                if toEditor {
                    StudioIcon(.editor, size: 13)
                } else {
                    Text(">_").font(.system(size: 10, weight: .bold, design: .monospaced))
                }
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(label) (⌥⌘E)")
        .accessibilityLabel(label)
    }
}

// MARK: - Plates

/// The selected tab's plate, as the design marks a selected row: the selection's tint and a coral edge on the left.
/// One per side bar; it slides between rows and Home (matched geometry), or fades under Reduce Motion.
private struct SelectionPlate: View {
    static let radius: CGFloat = 8

    @ViewBuilder
    static func matched(in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
        if reduceMotion {
            SelectionPlate()
                .transition(.opacity)
        } else {
            SelectionPlate()
                .matchedGeometryEffect(id: "selected-tab", in: namespace)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        shape
            .fill(StudioColors.selection)
            .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
            .clipShape(shape)
    }
}

/// A hovered or dragged row's plate: the hover tint; a dragged row lifts onto a card with a shadow.
private struct HoverPlate: View {
    var lifted = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SelectionPlate.radius, style: .continuous)
        shape
            .fill(lifted ? StudioColors.card : StudioColors.hover)
            .overlay(lifted ? shape.strokeBorder(StudioColors.line, lineWidth: 1) : nil)
            .shadow(color: .black.opacity(lifted ? (scheme == .dark ? 0.4 : 0.16) : 0), radius: lifted ? 12 : 0,
                    y: lifted ? 6 : 0)
    }
}

// MARK: - Window

/// Tells SwiftUI content which window it is in.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AccessorView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
