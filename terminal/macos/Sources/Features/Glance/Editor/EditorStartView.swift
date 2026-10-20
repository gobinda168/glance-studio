import GlanceCore
import SwiftUI

/// The start tab's window content: the side bar column, the page, the activity strip.
struct EditorStartTabView: View {
    @ObservedObject var model: EditorStartModel
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen { SidebarColumn() }
            EditorStartPage(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StudioColors.background)
        }
        .activityStrip()
    }
}

/// "Open a project": Open Folder…, New Project, Clone Repository, then Recent projects (as the replica's
/// switching.js start page, on the Browser start page's 560 pt column).
struct EditorStartPage: View {
    @ObservedObject var model: EditorStartModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Open a project")
                        .font(.studio(28, .bold))
                        .foregroundStyle(StudioColors.ink)
                    Text("No editor is open in this window. Pick a folder, start one, or clone a repository.")
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                }
                VStack(spacing: 6) {
                    ActionRow(icon: .folder, title: "Open Folder…", hint: "Any folder on this Mac", key: "⌘O",
                              lit: false) { model.openFolder() }
                        .keyboardShortcut("o", modifiers: .command)
                    ActionRow(icon: .fileNew, title: "New Project",
                              hint: "An empty folder in \((model.location as NSString).abbreviatingWithTildeInPath), with git",
                              key: nil, lit: model.form == .newProject) { model.toggle(.newProject) }
                    ActionRow(icon: .download, title: "Clone Repository", hint: "From GitHub or any git URL", key: nil,
                              lit: model.form == .clone) { model.toggle(.clone) }
                }
                if let form = model.form { FormCard(model: model, form: form) }
                if !model.recent.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECENT PROJECTS")
                            .font(.studio(11, .semibold))
                            .foregroundStyle(StudioColors.muted)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                        ForEach(model.recent) { project in
                            RecentRow(project: project) { model.tab?.openProject(project.path) }
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 72)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onExitCommand { model.cancel() }
    }
}

private struct ActionRow: View {
    let icon: StudioIcons.Name
    let title: String
    let hint: String
    let key: String?
    let lit: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                StudioIcon(icon, size: 18)
                    .foregroundStyle(StudioColors.ink)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                    Text(hint).font(.studio(12)).foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
                if let key {
                    Text(key)
                        .font(.studio(10.5, .semibold))
                        .foregroundStyle(StudioColors.muted)
                        .padding(.horizontal, 5)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(StudioColors.line))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(shape.fill(lit ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .overlay(shape.strokeBorder(lit ? StudioColors.line3 : StudioColors.line))
            .overlay(alignment: .leading) { if lit { Rectangle().fill(StudioColors.coral).frame(width: 2) } }
            .clipShape(shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

private struct FormCard: View {
    @ObservedObject var model: EditorStartModel
    let form: EditorStartModel.Form

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(form == .clone ? "Repository" : "Name")
                .font(.studio(11, .semibold))
                .foregroundStyle(StudioColors.muted)
            if form == .clone {
                StudioField(placeholder: "github.com/acme/invoice-service or git@github.com:…", text: $model.repository,
                            font: .system(size: 12.5, design: .monospaced)) { model.cloneRepository() }
            } else {
                StudioField(placeholder: "invoice-service", text: $model.name) { model.createProject() }
            }
            HStack(spacing: 6) {
                StudioIcon(.folder, size: 13)
                Text(model.destination).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Change…") { model.chooseLocation() }
                    .buttonStyle(.plain)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.coralInk)
            }
            .foregroundStyle(StudioColors.muted)
            if form == .newProject {
                Toggle("Initialize a git repository", isOn: $model.gitInit)
                    .toggleStyle(.checkbox)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.body)
            }
            if let problem = model.problem {
                Text(problem).font(.studio(12)).foregroundStyle(StudioColors.danger)
            }
            HStack(spacing: 8) {
                Spacer()
                StudioButton(title: "Cancel", style: .secondary) { model.cancel() }
                StudioButton(title: form == .clone ? "Clone & Open" : "Create & Open", style: .primary, busy: model.busy) {
                    form == .clone ? model.cloneRepository() : model.createProject()
                }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.bar))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StudioColors.line))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

private struct RecentRow: View {
    let project: EditorStartModel.Recent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StudioIcon(.folder, size: 15).foregroundStyle(StudioColors.muted)
                Text(project.name).font(.studio(13, .semibold))
                    .foregroundStyle(hovering ? StudioColors.ink : StudioColors.body)
                Text(project.shown).font(.system(size: 12, design: .monospaced)).foregroundStyle(StudioColors.muted)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let branch = project.branch {
                    HStack(spacing: 3) {
                        StudioIcon(.branch, size: 11)
                        Text(branch).font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(StudioColors.muted)
                }
                Text(project.age).font(.studio(11)).foregroundStyle(StudioColors.muted).frame(width: 28, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
