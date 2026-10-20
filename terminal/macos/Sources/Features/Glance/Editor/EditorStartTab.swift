import AppKit
import Combine
import GlanceCore
import GlanceKit
import SwiftUI

/// The Editor start page (spec 2026-10-11-strip-switching-design.md §3): one per window, listed in the Editor side
/// bar, shown when the Editor strip item is picked with no editor open. Picking a project opens its editor tab (the
/// one open already, else a new one) and closes this tab.
@MainActor
final class EditorStartTab: NSWindowController, NSWindowDelegate, GlanceTabController {
    static let kind = "editorStart"

    var tabKind: String { Self.kind }
    var tabKey: String { Self.kind }
    let model = EditorStartModel()

    init() {
        let window = GlanceTabWindow()
        super.init(window: window)
        window.delegate = self
        window.title = "Open a project"
        model.tab = self
        window.contentView = PullRequestHostingView(rootView: EditorStartTabView(model: model))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The start page of `parent`'s window (made when it has none), with the Editor side bar.
    @discardableResult
    static func open(from parent: NSWindow?) -> EditorStartTab? {
        SidebarModeModel.shared.show(.editor)
        return GlanceTabHost.open(kind: kind, key: kind, from: parent) { EditorStartTab() }
    }

    /// Opens `folder` in its editor tab in this window and closes the start page.
    func openProject(_ folder: String) {
        let root = SessionMatch.normalize(folder, home: NSHomeDirectory())
        let parent = window
        EditorTabs.open(EditorTabs.preferredKind, root: root, from: parent)
        HomeTabs.recordProject(from: root)
        parent?.performClose(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { model.reloadRecent() }

    func windowWillClose(_ notification: Notification) {
        GlanceTabHost.closed(self)
        DispatchQueue.main.async { [weak window] in MainActor.assumeIsolated { window?.contentView = nil } }
    }
}

/// The start page's state: which form is open, its fields, a run under way, and Recent projects.
@MainActor
final class EditorStartModel: ObservableObject {
    enum Form: Equatable { case newProject, clone }

    struct Recent: Identifiable, Equatable {
        let path: String
        let age: String
        var branch: String?
        var id: String { path }
        var name: String { EditorFolderPicker.name(path) }
        var shown: String { (path as NSString).abbreviatingWithTildeInPath }
    }

    @Published var form: Form?
    @Published var name = ""
    @Published var repository = ""
    @Published var location = OpenInEditorModel.defaultLocation
    @Published var gitInit = true
    @Published var busy = false
    @Published var problem: String?
    @Published var recent: [Recent] = []
    weak var tab: EditorStartTab?

    init() { reloadRecent() }

    func reloadRecent() {
        let now = Date()
        let entries = Prefs.recentProjects.entries.filter { OpenInEditorModel.isDirectory($0.path) }
        recent = entries.map { Recent(path: $0.path, age: RecentProjects.age(of: $0.lastActive, now: now)) }
        let paths = entries.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let branches = paths.map { GitHead.branch(inFolder: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                for (index, branch) in branches.enumerated() where self.recent.indices.contains(index) {
                    self.recent[index].branch = branch
                }
            }
        }
    }

    /// A form's row: opens it, or closes it when it's the open one.
    func toggle(_ form: Form) {
        self.form = self.form == form ? nil : form
        problem = nil
    }

    func cancel() {
        form = nil
        problem = nil
    }

    /// Where New Project makes its folder, or Clone puts the repository: shown under the field.
    var destination: String {
        let parent = (location as NSString).abbreviatingWithTildeInPath
        switch form {
        case .clone: return "Clones into \(parent)/\(CloneSource.name(of: repository) ?? "…")"
        default:
            let typed = name.trimmingCharacters(in: .whitespaces)
            return "\(parent)/\(typed.isEmpty ? "…" : typed)"
        }
    }

    // MARK: Open Folder…

    func openFolder() {
        chooseFolder(prompt: "Open", message: "Choose a folder to open in the editor.", start: nil) { [weak self] folder in
            self?.tab?.openProject(folder)
        }
    }

    func chooseLocation() {
        chooseFolder(prompt: "Choose", message: "Choose where it goes.", start: location) { [weak self] folder in
            self?.location = folder
            self?.problem = nil
        }
    }

    private func chooseFolder(prompt: String, message: String, start: String?, chosen: @escaping (String) -> Void) {
        let chooser = NSOpenPanel()
        chooser.canChooseDirectories = true
        chooser.canChooseFiles = false
        chooser.canCreateDirectories = true
        chooser.allowsMultipleSelection = false
        chooser.prompt = prompt
        chooser.message = message
        if let start { chooser.directoryURL = URL(fileURLWithPath: start) }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = chooser.url else { return }
            chosen(url.path)
        }
        if let window = tab?.window { chooser.beginSheetModal(for: window, completionHandler: handler) }
        else { handler(chooser.runModal()) }
    }

    // MARK: New Project

    func createProject() {
        guard !busy else { return }
        problem = nil
        switch EditorFolderPicker.newFolder(named: name, in: location, exists: { FileManager.default.fileExists(atPath: $0) }) {
        case .empty:
            return
        case .invalid(let reason):
            problem = reason
        case .exists(let folder):
            problem = "There's already a folder named \(EditorFolderPicker.name(folder)) there."
        case .create(let folder):
            busy = true
            NewFolderMaker.make(folder, gitInit: gitInit) { [weak self] outcome in
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .made(let folder): self.tab?.openProject(folder)
                case .failed(let why): self.problem = why
                case .gitFailed(let why, _): self.problem = why
                }
            }
        }
    }

    // MARK: Clone Repository

    func cloneRepository() {
        guard !busy else { return }
        problem = nil
        guard let plan = CloneSource.plan(repository, parent: location) else {
            problem = "Type owner/repo, a GitHub link, or a git URL."
            return
        }
        if FileManager.default.fileExists(atPath: plan.destination) {
            problem = RepositoryFolders.existsMessage(plan.destination)
            return
        }
        let executable: String
        switch plan.tool {
        case .gh:
            guard let gh = PullRequests.executable() else { problem = PullRequests.Failure.notInstalled.message; return }
            executable = gh
        case .git:
            executable = "/usr/bin/git"
        }
        busy = true
        Prefs.cloneFolder = location
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = GitHubCLI.execute(executable, plan.arguments)
            let failure: String? = switch result {
            case nil: "Couldn't start \(plan.tool == .gh ? "gh" : "git")."
            case let result? where result.status != 0: GitHubCLI.firstLine(result.error)
            default: nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let failure { self.problem = failure } else { self.tab?.openProject(plan.destination) }
            }
        }
    }
}
