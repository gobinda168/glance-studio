import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Terminal side bar's History: past Claude Code sessions, newest first, each named by its first prompt. It lists
/// the project in front (its root, subfolders and worktrees, `HistoryProject`), only the terminal's folder, or a recent
/// project picked from the header's menu. A click resumes a session in a new terminal tab (`claude --resume`) in the
/// folder it ran in; with the project open in an editor tab, "View as threads" shows its conversation there, one
/// collapsible thread per prompt (Web/chat.js). Its top edge drags it taller or shorter, up to the full side bar.
struct SessionHistorySection: View {
    /// The terminal's folder in front, or nil on Home and pages.
    let folder: String?
    /// Redraws and reloads when the tab in front changes.
    let selected: ObjectIdentifier?
    let window: NSWindow?
    /// How much taller it can grow: what the tab list above can still give up.
    let spare: CGFloat

    @AppStorage("historyOpen") private var open = true
    /// The list's height when not full.
    @AppStorage("historyHeight") private var height = 230.0
    /// Takes the whole side bar, but for the tab list's least height.
    @AppStorage("historyFull") private var full = false
    @AppStorage("historyScope") private var scope = Scope.project
    /// A recent project picked from the menu, listed whatever tab is in front; empty follows the tab.
    @AppStorage("historyPinned") private var pinned = ""
    @State private var entries: [GlanceKit.HistoryEntry] = []
    /// Sessions whose folder is gone (a removed worktree): they can't be resumed.
    @State private var gone: Set<String> = []
    /// The project of `folder`: its git root, else the folder.
    @State private var root: String?
    @State private var loaded = false
    @State private var listHeight: CGFloat = 0
    @State private var drag: Drag?
    @State private var gripHovering = false

    enum Scope: String { case project, folder }

    /// The height a drag started from, the most it may reach, and where the pointer has it now.
    private struct Drag {
        let from: CGFloat
        let limit: CGFloat
        var proposed: CGFloat
    }

    private static let least: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            header
            if open {
                Group {
                    if entries.isEmpty {
                        Text(loaded ? emptyText : "Loading…")
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 1) {
                                ForEach(entries) { entry in
                                    HistoryRow(entry: entry, gone: gone.contains(entry.id), canThread: editorOpen) {
                                        resume(entry)
                                    } thread: { viewThreads(entry) }
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                        }
                    }
                }
                .frame(minHeight: Self.least, maxHeight: full ? .infinity : CGFloat(height), alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
        }
        .overlay(alignment: .top) { grip }
        // Offered its height before the tab list above, which keeps its own least height.
        .layoutPriority(open ? 1 : 0)
        .task(id: [folder ?? "", selected.map { "\($0)" } ?? "", scope.rawValue, pinned]) { await reload() }
        .onChange(of: open) { _, now in if now { Task { await reload() } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.easeOut(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    StudioIcon(open ? .chevronDown : .chevronRight, size: 12)
                    Text("HISTORY")
                        .tracking(0.66)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            scopeMenu
            // Fixed height: a bare min height lets it take whatever the side bar offers.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFull() }
            if !entries.isEmpty { Text("\(entries.count)").monospacedDigit() }
            Button(action: toggleFull) {
                StudioIcon(full && open ? .minimize : .maximize, size: 12)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(full && open ? "Restore History's height" : "Fill the side bar with History")
            .accessibilityLabel(full && open ? "Restore height" : "Full height")
        }
        .font(.studio(11, .semibold))
        .foregroundStyle(StudioColors.muted)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
    }

    /// "glance ▾": what the list shows, and the other projects it can show.
    private var scopeMenu: some View {
        Menu {
            if let folder {
                let project = root ?? folder
                Toggle(isOn: Binding(get: { pinned.isEmpty && !folderOnly }, set: { _ in follow(.project) })) {
                    Text("This Project · \(Self.name(project))")
                }
                if project != folder {
                    Toggle(isOn: Binding(get: { pinned.isEmpty && folderOnly }, set: { _ in follow(.folder) })) {
                        Text("This Folder Only · \(Self.name(folder))")
                    }
                }
            }
            let others = recentProjects
            if !others.isEmpty {
                Section("Recent Projects") {
                    ForEach(others, id: \.self) { path in
                        Toggle(isOn: Binding(get: { pinned == path }, set: { _ in pinned = path })) {
                            Text(Self.name(path))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(scopeTitle)
                    .font(.studioMono(11))
                    .foregroundStyle(pinned.isEmpty ? StudioColors.muted : StudioColors.coralInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                StudioIcon(.chevronDown, size: 10)
            }
            .foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(scopeHelp)
        .accessibilityLabel("History of \(scopeTitle)")
    }

    /// Only the terminal's own folder, when it's inside a bigger project.
    private var folderOnly: Bool {
        guard scope == .folder, let folder else { return false }
        return (root ?? folder) != folder
    }

    private var scopeTitle: String {
        if !pinned.isEmpty { return Self.name(pinned) }
        guard let folder else { return "—" }
        return folderOnly ? Self.name(folder) + "/" : Self.name(root ?? folder)
    }

    private var scopeHelp: String {
        if !pinned.isEmpty { return "Sessions of \(pinned), whichever tab is in front" }
        guard let folder else { return "Open a terminal to see its project's sessions" }
        return folderOnly ? "Sessions started in \(folder)" : "Sessions of \(root ?? folder), its subfolders and worktrees"
    }

    private var emptyText: String {
        if pinned.isEmpty && folder == nil { return "Open a terminal to see its sessions" }
        return pinned.isEmpty && folderOnly ? "No past sessions in this folder yet" : "No past sessions in this project yet"
    }

    /// Home's Recent projects, but the tab's own.
    private var recentProjects: [String] {
        let current = folder.map { root ?? $0 }
        return Prefs.recentProjects.entries.map(\.path).filter { $0 != current }
    }

    private func follow(_ scope: Scope) {
        pinned = ""
        self.scope = scope
    }

    private static func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    // MARK: Size

    /// The top edge: drag up for more, to the full side bar; down for less, and past the least to fold it.
    private var grip: some View {
        Rectangle()
            .fill(gripHovering || drag != nil ? StudioColors.coral : StudioColors.line)
            .frame(height: gripHovering || drag != nil ? 2 : 0.75)
            .frame(maxWidth: .infinity)
            .frame(height: 9)
            .contentShape(Rectangle())
            .offset(y: -4)
            .onHover { inside in
                gripHovering = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let from = open ? listHeight : 0
                    var current = drag ?? Drag(from: from, limit: from + spare, proposed: from)
                    current.proposed = current.from - value.translation.height
                    drag = current
                    if !open && current.proposed >= Self.least / 2 { open = true }
                    full = current.proposed >= current.limit - 2
                    if !full { height = Double(max(Self.least, min(current.proposed, current.limit))) }
                }
                .onEnded { _ in
                    if let drag, drag.proposed < Self.least / 2 {
                        // Folded: it opens again at the height it had.
                        withAnimation(.easeOut(duration: 0.18)) { open = false }
                        full = false
                        height = Double(max(Self.least * 2, drag.from))
                    }
                    drag = nil
                })
            .accessibilityHidden(true)
    }

    private func toggleFull() {
        withAnimation(.easeOut(duration: 0.18)) {
            if open {
                full.toggle()
            } else {
                open = true
                full = true
            }
        }
    }

    // MARK: Sessions

    private func reload() async {
        let folder = folder
        let pinned = pinned
        let scope = scope
        guard folder != nil || !pinned.isEmpty else { entries = []; root = nil; loaded = true; return }
        let found = await Task.detached(priority: .utility) { () -> (String?, [GlanceKit.HistoryEntry], Set<String>) in
            let root = folder.map { ProjectRoot.find(from: $0) }
            let entries: [GlanceKit.HistoryEntry]
            if !pinned.isEmpty {
                entries = ClaudeHistory.sessions(project: pinned)
            } else if let folder, let root, scope == .folder, root != folder {
                entries = ClaudeHistory.sessions(folder: folder)
            } else if let root {
                entries = ClaudeHistory.sessions(project: root)
            } else {
                entries = []
            }
            let gone = Set(entries.filter { !FileManager.default.fileExists(atPath: $0.cwd) }.map(\.id))
            return (root, entries, gone)
        }.value
        root = found.0
        entries = found.1
        gone = found.2
        loaded = true
    }

    private func resume(_ entry: GlanceKit.HistoryEntry) {
        guard !gone.contains(entry.id) else { return }
        EditorBridgeActions.openTerminalTab(cwd: entry.cwd, near: window, input: "claude --resume \(entry.id)\n")
    }

    /// The editor tab whose chat can show a session's threads: the listed project's.
    private var editorRoot: String? {
        pinned.isEmpty ? folder.map { root ?? $0 } : pinned
    }

    private var editorOpen: Bool {
        guard let editorRoot else { return false }
        return GlanceTabHost.controllers(kind: EditorKind.studio.rawValue).contains { $0.tabKey == editorRoot }
    }

    private func viewThreads(_ entry: GlanceKit.HistoryEntry) {
        guard let editorRoot else { return }
        GlanceTerminalHost.shared.showHistoryThreads(sessionID: entry.id, folder: editorRoot)
    }
}

private struct HistoryRow: View {
    let entry: GlanceKit.HistoryEntry
    /// Its folder is gone, so it can't be resumed.
    let gone: Bool
    let canThread: Bool
    let resume: () -> Void
    let thread: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: resume) {
            HStack(spacing: 8) {
                Text(entry.title)
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(hovering && !gone ? StudioColors.ink : StudioColors.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let place = entry.place, !hovering {
                    Text(place)
                        .font(.studioMono(10.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(hovering ? (gone ? "Folder gone" : "Resume") : ClaudeProjectFolder.ago(entry.updated))
                    .font(.studioMono(11))
                    .foregroundStyle(hovering && !gone ? StudioColors.coralInk : StudioColors.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(GlassChrome.fade, value: hovering)
        .help(entry.place.map { "\(entry.title)\nin \($0)" } ?? entry.title)
        .contextMenu {
            Button("Resume in a New Tab", action: resume)
                .disabled(gone)
            Button("View as Threads", action: thread)
                .disabled(!canThread)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(gone ? "Its folder is gone" : "Resumes this session in a new tab")
        .accessibilityAction(named: "View as Threads", thread)
    }
}
