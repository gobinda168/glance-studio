import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// New Editor Tab's Open in Editor palette: which folder the new editor tab opens. THIS TAB's project, Home's RECENT
/// projects, New Folder… (named here, made in the clone folder, `git init` by default) and Open Other Folder…. A card
/// centered over the window; Esc or a click elsewhere closes it.
@MainActor
final class OpenInEditorPalette: NSObject, NSWindowDelegate {
    private static var current: OpenInEditorPalette?

    private let panel: PalettePanel
    private weak var parent: NSWindow?
    private let model: OpenInEditorModel

    static let size = NSSize(width: 460, height: 420)

    /// Shows the palette over `parent` (on the main screen without one), `thisTab` the tab's project.
    static func show(over parent: NSWindow?, thisTab: String?) {
        current?.close()
        let palette = OpenInEditorPalette(parent: parent, thisTab: thisTab)
        current = palette
        palette.present()
    }

    private init(parent: NSWindow?, thisTab: String?) {
        self.parent = parent
        panel = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        model = OpenInEditorModel(thisTab: thisTab)
        super.init()
        model.palette = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the card draws its own
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: OpenInEditorCard(model: model))
    }

    private func present() {
        let area = parent?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        // A little above the middle, where a palette sits.
        let origin = NSPoint(x: area.midX - Self.size.width / 2, y: area.midY - Self.size.height / 2 + area.height * 0.08)
        panel.setFrameOrigin(origin)
        if let parent { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    /// A click elsewhere closes it; its own folder chooser (a sheet on it) doesn't.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.attachedSheet == nil else { return }
        close()
    }

    /// Opens `folder` in a new editor tab next to the palette's window and puts it first in RECENT.
    func open(_ folder: String) {
        let parent = self.parent
        close()
        let root = SessionMatch.normalize(folder, home: NSHomeDirectory())
        EditorTabs.open(EditorTabs.preferredKind, root: root, from: parent, reuse: false)
        HomeTabs.recordProject(from: root)
    }

    /// Open Other Folder…: the system's folder chooser on the palette's window, then that folder.
    func openOther() {
        let parent = self.parent
        close()
        chooseFolder(prompt: "Open", message: "Choose a folder to open in the editor.", on: parent) { folder in
            OpenInEditorPalette.openChosen(folder, from: parent)
        }
    }

    private static func openChosen(_ folder: String, from parent: NSWindow?) {
        let root = SessionMatch.normalize(folder, home: NSHomeDirectory())
        EditorTabs.open(EditorTabs.preferredKind, root: root, from: parent, reuse: false)
        HomeTabs.recordProject(from: root)
    }

    /// New Folder's location button: the system's folder chooser as a sheet on the palette.
    func chooseLocation(then chosen: @escaping (String) -> Void) {
        chooseFolder(prompt: "Choose", message: "Choose where to make the new folder.", on: panel, start: model.location,
                     chosen: chosen)
    }

    private func chooseFolder(prompt: String, message: String, on window: NSWindow?, start: String? = nil,
                              chosen: @escaping (String) -> Void) {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.prompt = prompt
        chooser.message = message
        chooser.directoryURL = URL(fileURLWithPath: start ?? OpenInEditorModel.defaultLocation)
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if let self, window === self.panel { self.panel.makeKey() }
            guard response == .OK, let path = chooser.url?.path else { return }
            chosen(path)
        }
        if let window { chooser.beginSheetModal(for: window, completionHandler: finish) } else { finish(chooser.runModal()) }
    }
}

/// A borderless panel that takes the keyboard (the filter field).
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - The model

/// What the palette shows and does: the list (filtered, with the keyboard's highlight) or New Folder's form.
@MainActor
final class OpenInEditorModel: ObservableObject {
    /// One row the keys move through.
    enum Item: Equatable, Identifiable {
        case folder(String, header: String?)
        case newFolder
        case otherFolder

        var id: String {
            switch self {
            case .folder(let path, let header): "\(header ?? "")|\(path)"
            case .newFolder: "new"
            case .otherFolder: "other"
            }
        }
    }

    enum Mode { case list, newFolder }

    let thisTab: String?
    let recent: [String]
    weak var palette: OpenInEditorPalette?
    @Published var mode: Mode = .list
    @Published var filter = "" { didSet { highlighted = 0 } }
    @Published var highlighted = 0
    /// Each folder's checked-out branch, read off the main thread.
    @Published private(set) var branches: [String: String] = [:]

    // New Folder…
    @Published var name = ""
    @Published var location: String = OpenInEditorModel.defaultLocation
    @Published var gitInit = true
    @Published var creating = false
    /// Why the folder wasn't made (or git init failed), shown under the form.
    @Published var problem: String?
    /// The folder is there already: Open It instead.
    @Published var existing: String?

    let home = NSHomeDirectory()

    /// The clone folder (the one chosen last, else ~/Code), else home.
    static var defaultLocation: String {
        RepositoryFolders.cloneFolder(saved: Prefs.cloneFolder, home: NSHomeDirectory(), isDirectory: isDirectory)
            ?? NSHomeDirectory()
    }

    nonisolated static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    init(thisTab: String?) {
        self.thisTab = thisTab
        recent = Prefs.recentProjects.entries.map(\.path).filter(Self.isDirectory)
        let folders = [thisTab].compactMap { $0 } + recent
        let home = self.home
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [String: String] = [:]
            for folder in folders { found[folder] = GitHead.branch(inFolder: folder, home: home) }
            DispatchQueue.main.async { self?.branches = found }
        }
    }

    var items: [Item] {
        let groups = EditorFolderPicker.groups(thisTab: thisTab, recent: recent, filter: filter, home: home)
        let folders = groups.flatMap { group in
            group.folders.enumerated().map { index, folder in
                Item.folder(folder, header: index == 0 ? title(group.section) : nil)
            }
        }
        return folders + [.newFolder, .otherFolder]
    }

    private func title(_ section: EditorFolderPicker.Section) -> String? {
        switch section {
        case .thisTab: "This tab"
        case .recent: "Recent"
        case .matches: nil
        }
    }

    func move(_ step: Int) {
        highlighted = min(max(highlighted + step, 0), items.count - 1)
    }

    func choose(_ item: Item) {
        switch item {
        case .folder(let folder, _): palette?.open(folder)
        case .newFolder: startNewFolder()
        case .otherFolder: palette?.openOther()
        }
    }

    func chooseHighlighted() {
        let items = self.items
        if items.indices.contains(highlighted) { choose(items[highlighted]) }
    }

    // MARK: New Folder…

    /// The form, its name the filter's text when nothing matched it.
    func startNewFolder() {
        let query = filter.trimmingCharacters(in: .whitespaces)
        let matched = EditorFolderPicker.groups(thisTab: thisTab, recent: recent, filter: filter, home: home)
        name = matched.isEmpty ? query : ""
        problem = nil
        existing = nil
        mode = .newFolder
    }

    func backToList() {
        mode = .list
        problem = nil
        existing = nil
    }

    func chooseLocation() {
        palette?.chooseLocation { [weak self] folder in
            self?.location = folder
            self?.problem = nil
            self?.existing = nil
        }
    }

    /// The name as typed: nothing, a reason it can't be, a folder that's there, or the folder to make.
    var check: EditorFolderPicker.NewFolder {
        EditorFolderPicker.newFolder(named: name, in: location, exists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Create & Open: makes the folder, runs `git init` in it when asked, then opens it. A failed git init leaves the
    /// folder and says why, with Open Anyway.
    func create() {
        guard !creating else { return }
        problem = nil
        existing = nil
        switch check {
        case .empty:
            return
        case .invalid(let reason):
            problem = reason
        case .exists(let folder):
            existing = folder
        case .create(let folder):
            creating = true
            NewFolderMaker.make(folder, gitInit: gitInit) { [weak self] outcome in
                guard let self else { return }
                self.creating = false
                switch outcome {
                case .made(let folder): self.palette?.open(folder)
                case .failed(let why): self.problem = why
                case .gitFailed(let why, let folder):
                    self.problem = why
                    self.existing = folder
                }
            }
        }
    }

    func openExisting() {
        if let existing { palette?.open(existing) }
    }

    func close() { palette?.close() }
}

// MARK: - The card

/// The palette's card: thick glass (MASTER §2, "palettes"), the list or New Folder's form.
private struct OpenInEditorCard: View {
    @ObservedObject var model: OpenInEditorModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            switch model.mode {
            case .list: FolderList(model: model)
            case .newFolder: NewFolderForm(model: model)
            }
        }
        .frame(width: OpenInEditorPalette.size.width - 32, height: OpenInEditorPalette.size.height - 32)
        .background(shape.fill(StudioColors.card.opacity(0.86)))
        .glassSurface(shape, solid: StudioColors.card)
        .overlay(shape.strokeBorder(StudioColors.line3, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .frame(width: OpenInEditorPalette.size.width, height: OpenInEditorPalette.size.height)
    }
}

/// The filter field and the rows: ↑↓ move, Return opens, Esc closes.
private struct FolderList: View {
    @ObservedObject var model: OpenInEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        let items = model.items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StudioIcon(.search, size: 14).foregroundStyle(StudioColors.muted)
                TextField("Open a folder in a new editor tab…", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.ink)
                    .focused($focused)
                    .onSubmit { model.chooseHighlighted() }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onExitCommand { model.close() }
                    .accessibilityLabel("Filter folders")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .overlay(alignment: .bottom) { Rectangle().fill(StudioColors.line).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !model.filter.trimmingCharacters(in: .whitespaces).isEmpty,
                           !items.contains(where: { if case .folder = $0 { true } else { false } }) {
                            Text("No recent folder matches “\(model.filter.trimmingCharacters(in: .whitespaces))”.")
                                .font(.studio(12))
                                .foregroundStyle(StudioColors.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            row(item, index: index)
                                .id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .onChange(of: model.highlighted) { _, index in
                    if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                }
            }
            footer
        }
        .onAppear { focused = true }
    }

    @ViewBuilder private func row(_ item: OpenInEditorModel.Item, index: Int) -> some View {
        let lit = index == model.highlighted
        switch item {
        case .folder(let folder, let header):
            VStack(alignment: .leading, spacing: 0) {
                if let header {
                    Caption(header)
                        .padding(.horizontal, 10)
                        .padding(.top, index == 0 ? 4 : 12)
                        .padding(.bottom, 4)
                }
                FolderRow(folder: folder, shown: EditorFolderPicker.shown(folder, home: model.home),
                          branch: model.branches[folder], isHighlighted: lit) { model.choose(item) }
            }
        case .newFolder:
            VStack(spacing: 0) {
                Rectangle().fill(StudioColors.line).frame(height: 1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                ActionRow(icon: .plus, title: "New Folder…", isHighlighted: lit) { model.choose(item) }
            }
        case .otherFolder:
            ActionRow(icon: .folder, title: "Open Other Folder…", isHighlighted: lit) { model.choose(item) }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "move")
            hint("↩", "open")
            hint("esc", "close")
            Spacer(minLength: 4)
            Text("Opens in \(EditorTabs.preferredKind == .razor ? "Razor Code" : "GS Code")")
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }

    private func hint(_ keys: String, _ words: String) -> some View {
        HStack(spacing: 5) {
            Kbd(keys)
            Text(words).font(.studio(11.5)).foregroundStyle(StudioColors.muted)
        }
    }
}

/// A folder: its name, where it is in mono, its branch. The highlight follows the keys and the pointer.
private struct FolderRow: View {
    let folder: String
    let shown: String
    let branch: String?
    let isHighlighted: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) {
                StudioIcon(.folder, size: 14)
                    .foregroundStyle(isHighlighted ? StudioColors.coralInk : StudioColors.muted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(EditorFolderPicker.name(folder))
                        .font(.studio(12.5, .semibold))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                    Text(shown)
                        .font(.studioMono(10.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 6)
                if let branch {
                    BranchChip(branch, size: 10.5, truncation: .middle)
                        .frame(maxWidth: 140, alignment: .trailing)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(EditorFolderPicker.name(folder)), \(shown)" + (branch.map { ", branch \($0)" } ?? ""))
    }
}

/// New Folder… and Open Other Folder….
private struct ActionRow: View {
    let icon: StudioIcons.Name
    let title: String
    let isHighlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StudioIcon(icon, size: 14)
                    .foregroundStyle(isHighlighted ? StudioColors.coralInk : StudioColors.muted)
                Text(title)
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// New Folder…: the name, where (the clone folder unless changed), git init, Create & Open. Esc goes back.
private struct NewFolderForm: View {
    @ObservedObject var model: OpenInEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        let check = model.check
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { model.backToList() } label: {
                    StudioIcon(.chevronLeft, size: 14).foregroundStyle(StudioColors.muted)
                }
                .buttonStyle(.plain)
                .help("Back (esc)")
                .accessibilityLabel("Back")
                Text("New Folder")
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
            }
            TextField("Folder name", text: $model.name)
                .textFieldStyle(.plain)
                .font(.studio(13))
                .foregroundStyle(StudioColors.ink)
                .focused($focused)
                .onSubmit { model.create() }
                .onExitCommand { model.backToList() }
                .onChange(of: model.name) { model.problem = nil; model.existing = nil }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? StudioColors.coral.opacity(0.6) : StudioColors.line, lineWidth: 1))
                .accessibilityLabel("Folder name")
            HStack(spacing: 8) {
                Text("in").font(.studio(12)).foregroundStyle(StudioColors.muted)
                Button { model.chooseLocation() } label: {
                    HStack(spacing: 4) {
                        Text(EditorFolderPicker.shown(model.location, home: model.home))
                            .font(.studioMono(11.5, .medium))
                            .lineLimit(1)
                            .truncationMode(.head)
                        StudioIcon(.chevronDown, size: 12)
                    }
                    .foregroundStyle(StudioColors.ink)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line3))
                }
                .buttonStyle(.plain)
                .help("Choose where to make it")
                Spacer(minLength: 8)
                Toggle("git init", isOn: $model.gitInit)
                    .toggleStyle(.checkbox)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.body)
            }
            if case .create(let folder) = check, model.problem == nil {
                Text(EditorFolderPicker.shown(folder, home: model.home))
                    .font(.studioMono(11))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let problem = model.problem {
                InlineError(message: problem)
            } else if case .invalid(let reason) = check {
                InlineError(message: reason)
            } else if model.existing != nil || { if case .exists = check { true } else { false } }() {
                Text("There's already a folder with that name there.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.amber)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                StudioButton(title: "Cancel", style: .quiet) { model.backToList() }
                if case .exists(let folder) = check, model.problem == nil {
                    StudioButton(title: "Open It", style: .primary) {
                        model.existing = folder
                        model.openExisting()
                    }
                } else if model.existing != nil {
                    StudioButton(title: "Open Anyway", style: .primary) { model.openExisting() }
                } else {
                    StudioButton(title: "Create & Open", hint: "↩", style: .primary, busy: model.creating,
                                 enabled: { if case .create = check { true } else { false } }()) { model.create() }
                }
            }
        }
        .padding(16)
        .onAppear { focused = true }
    }
}
