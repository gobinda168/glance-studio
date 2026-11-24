import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlanceCore
import GlanceKit

/// The composer under the timeline: types into the terminal's Claude session (Return sends, ⇧Return adds a line),
/// `/` offers commands and skills, `@` offers files, images attach as paths, and Stop interrupts Claude.
/// Replica: design-system/glance/prototype/sessionview.css (.gv-composer, .gv-box, .gv-menu).
struct ComposerView: View {
    @ObservedObject var model: SessionViewModel
    var placeholder = "Ask Claude, or type / for commands"

    @State private var text = ""
    @State private var caret = 0
    @State private var fieldHeight: CGFloat = 22
    @State private var focused = false
    @State private var menuIndex = 0
    /// Esc closed the menu; it stays closed until the text changes.
    @State private var menuClosed = false
    @State private var scanned: [SlashCommand] = []
    @State private var files: [String] = []
    @State private var attachments: [Attachment] = []
    @State private var sendError: String?
    @State private var caption: String?
    @State private var dropTargeted = false
    @State private var rowWidth: CGFloat = 720
    @State private var focusRequest = 0
    /// The key hints are the first to go when the column narrows.
    private static let hintsMinWidth: CGFloat = 600

    private var working: Bool { model.timeline.live.working }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.queued.enumerated()), id: \.offset) { _, message in
                QueuedRow(message: message)
            }
            if let caption {
                CaptionRow(symbol: "arrow.up.forward.app", text: caption, color: StudioColors.body)
            }
            if let sendError {
                CaptionRow(symbol: "xmark", text: sendError, color: StudioColors.danger)
            }
            if let failed = model.modeFailure {
                HStack(spacing: 8) {
                    CaptionRow(symbol: "exclamationmark.triangle", text: model.currentMode.map {
                        "Couldn't switch to \(failed.title). Claude is still in \($0.title)."
                    } ?? "Couldn't switch to \(failed.title).", color: StudioColors.danger)
                    Spacer(minLength: 0)
                    Button("Change it in the terminal") { model.showTerminal() }
                        .buttonStyle(.plain).font(.studio(12, .medium)).foregroundStyle(StudioColors.body)
                }
            }
            box
        }
        .padding(.top, 8).padding(.bottom, 16)
        .overlay(alignment: .top) {
            if let menu {
                ComposerMenuView(menu: menu, index: $menuIndex, accept: { accept(at: $0) })
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
            }
        }
        .zIndex(1)
        .task(id: model.cwd) { await load(cwd: model.cwd) }
        .onChange(of: text) {
            menuClosed = false
            sendError = nil
            if caption != nil { caption = nil }
        }
        .onChange(of: trigger) { menuIndex = 0 }
        .onChange(of: model.composerDraft) { takeDraft() }
        .onChange(of: model.composerAddition) { takeAddition() }
        .onAppear { takeDraft(); takeAddition() }
    }

    /// A draft another part of the view left for the composer (proof's "Update setup"): taken once, not sent.
    private func takeDraft() {
        guard let draft = model.composerDraft else { return }
        model.composerDraft = nil
        text = draft
        caret = (draft as NSString).length
    }

    /// Words another part of the view adds to what's typed (an explainer's Ask about this): never sent, and the
    /// composer takes the keyboard so the sentence can be finished.
    private func takeAddition() {
        guard let addition = model.composerAddition else { return }
        model.composerAddition = nil
        text = text.isEmpty ? addition : text + "\n" + addition
        caret = (text as NSString).length
        focusRequest += 1
    }

    // MARK: The box

    private var box: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(attachments) { item in
                        AttachmentChip(item: item) { remove(item) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
            }
            ComposerTextView(
                text: $text, caret: $caret, height: $fieldHeight, focused: $focused, dropTargeted: $dropTargeted,
                placeholder: placeholder, surfaceID: model.surface.uuidString, menuOpen: menu != nil,
                focusRequest: focusRequest,
                moveMenu: moveMenu, acceptMenu: { accept(at: menuIndex) }, submit: submit, escape: escape,
                attach: attach)
                .frame(height: fieldHeight)
            HStack(spacing: 8) {
                AttachButton(pick: pickImages)
                // The controls change a running session, so they wait for one.
                if model.link != nil { ComposerControls(model: model, failed: { sendError = $0 }) }
                Spacer(minLength: 0)
                if working {
                    Text("Esc to stop").font(.studio(11.5)).foregroundStyle(StudioColors.muted).lineLimit(1).fixedSize()
                } else if rowWidth >= Self.hintsMinWidth {
                    HStack(spacing: 6) {
                        Key("/"); Text("commands")
                        Key("@").padding(.leading, 6); Text("files")
                    }
                    .font(.studio(11.5)).foregroundStyle(StudioColors.muted)
                    .lineLimit(1).fixedSize()
                    .accessibilityHidden(true)
                }
                if model.link != nil, model.timeline.usage.contextTokens > 0 { ContextRing(usage: model.timeline.usage) }
                sendButton
            }
            .padding(.top, 4)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { rowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in rowWidth = new }
            })
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.top, 10).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 16).fill(StudioColors.card))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(dropTargeted ? StudioColors.coral : focused ? StudioColors.coral.opacity(0.55) : StudioColors.line3,
                        lineWidth: dropTargeted ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            let loads = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            for provider in loads {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, ImageIntake.isImage(url) else { return }
                    DispatchQueue.main.async { attach([url]) }
                }
            }
            return !loads.isEmpty
        }
    }

    private var sendButton: some View {
        Button {
            if working { model.stop() } else { submit() }
        } label: {
            Image(systemName: working ? "stop.fill" : "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(working ? StudioColors.background : StudioColors.onCoral)
                .frame(width: 30, height: 30)
                .background(Circle().fill(working ? StudioColors.ink : StudioColors.coral))
                .opacity(working || canSend ? 1 : 0.4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!working && !canSend)
        .help(working ? "Stop (Esc)" : "Send (Return)")
        .accessibilityLabel(working ? "Stop" : "Send")
    }

    // MARK: Menu

    private var trigger: ComposerTrigger? { ComposerTrigger.at(text, caret: caret) }

    private var menu: ComposerMenu? {
        guard !menuClosed, let trigger else { return nil }
        switch trigger {
        case .slash(let query):
            let found = SlashCatalog.matches(query, in: SlashCatalog.builtIns + scanned, limit: 40)
            return found.isEmpty ? nil : .commands(found)
        case .mention(let query, _):
            let found = FileMention.rank(query, in: files, limit: 20)
            return found.isEmpty ? nil : .files(found)
        }
    }

    private func moveMenu(_ delta: Int) {
        guard let count = menu?.count, count > 0 else { return }
        menuIndex = (menuIndex + delta + count) % count
    }

    /// Return / Tab / a click on a menu row. False when there is nothing to accept.
    @discardableResult private func accept(at index: Int) -> Bool {
        guard let menu, let trigger else { return false }
        let items = menu.ordered
        guard items.indices.contains(index) else { return false }
        switch (items[index], trigger) {
        case (.command(let command), _):
            if command.interactive {
                model.runInteractive(command.name)
                text = ""; caret = 0
                caption = "Opened /\(command.name) in the terminal — Glance comes back when it's done"
                scheduleCaptionClear()
            } else {
                text = "/\(command.name) "
                caret = text.utf16.count
            }
        case (.file(let path), .mention(_, let start)):
            let next = ComposerTrigger.replaceMention(in: text, start: start, caret: caret, with: path)
            text = next.text; caret = next.caret
        default:
            return false
        }
        return true
    }

    private func scheduleCaptionClear() {
        let shown = caption
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if caption == shown { caption = nil }
        }
    }

    // MARK: Keys, submit

    private func escape() {
        if menu != nil { menuClosed = true } else if working { model.stop() }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A typed "/model" is the same as picking it: Claude's own dialog belongs in the terminal.
        if trimmed.hasPrefix("/"), !trimmed.contains(where: \.isWhitespace),
           SlashCatalog.builtIns.contains(where: { $0.name == String(trimmed.dropFirst()) && $0.interactive }) {
            model.runInteractive(String(trimmed.dropFirst()))
            text = ""; caret = 0; attachments = []
            return
        }
        if model.send(trimmed) {
            text = ""; caret = 0; attachments = []; sendError = nil
        } else {
            sendError = model.sendFailure ?? "This terminal is closed"
        }
    }

    // MARK: Images

    private func attach(_ urls: [URL]) {
        for url in urls {
            let token = ImageIntake.token(for: url.path)
            let current = text as NSString
            let at = min(caret, current.length)
            let previous = at > 0 ? UnicodeScalar(current.character(at: at - 1)) : nil
            let lead = previous.map { !CharacterSet.whitespacesAndNewlines.contains($0) } == true ? " " : ""
            let insert = lead + token + " "
            text = current.replacingCharacters(in: NSRange(location: at, length: 0), with: insert)
            caret = at + (insert as NSString).length
            attachments.append(Attachment(path: url.path, token: token, thumbnail: ImageIntake.thumbnail(url)))
        }
    }

    /// The attach button: an open panel for images.
    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose images to send to Claude"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        attach(panel.urls)
    }

    private func remove(_ item: Attachment) {
        text = text.replacingOccurrences(of: item.token + " ", with: "").replacingOccurrences(of: item.token, with: "")
        caret = min(caret, text.utf16.count)
        attachments.removeAll { $0.id == item.id }
    }

    // MARK: Loading

    /// The slash commands on disk and the project's files, read once per session folder, off the main thread.
    private func load(cwd: String?) async {
        let home = NSHomeDirectory()
        scanned = await Task.detached(priority: .utility) { SlashCatalog.scan(home: home, project: cwd) }.value
        guard let cwd else { files = []; return }
        files = await Task.detached(priority: .utility) { ProjectFiles.list(in: cwd, cap: 20_000) }.value
    }
}

// MARK: - Pieces

private struct Attachment: Identifiable {
    let id = UUID()
    let path: String
    /// What was inserted into the text.
    let token: String
    let thumbnail: NSImage?
}

private struct AttachmentChip: View {
    let item: Attachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let thumbnail = item.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.system(size: 12)).foregroundStyle(StudioColors.muted)
                }
            }
            .frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 4))
            Text((item.path as NSString).lastPathComponent).font(.studio(12, .medium)).foregroundStyle(StudioColors.body)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 160)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(StudioColors.muted)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image")
        }
        .padding(.leading, 3)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(StudioColors.chip))
    }
}

private struct QueuedRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Queued").font(.studio(11, .semibold)).foregroundStyle(StudioColors.tealInk)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .overlay(Capsule().stroke(StudioColors.tealInk.opacity(0.4), lineWidth: 1))
            Text(preview).font(.studio(12.5)).foregroundStyle(StudioColors.body).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 8).frame(minHeight: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Queued · \(preview)")
    }

    private var preview: String {
        // A recap's context ahead of the message isn't what was sent to read: the words typed are.
        let typed = RecapText.typedText(message)
        if typed.isEmpty { return "Recap as context" }
        let flat = typed.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
    }
}

private struct CaptionRow: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.studio(12.5)).lineLimit(2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).frame(minHeight: 24)
        .accessibilityElement(children: .combine)
    }
}

/// Attach images (they go in as paths, the way Claude Code takes them). Paste and drop work too.
private struct AttachButton: View {
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            Image(systemName: "photo.badge.plus").font(.system(size: 14))
                .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Attach images (or paste or drop them)")
        .accessibilityLabel("Attach images")
    }
}

/// A key cap in the hint row.
private struct Key: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label).font(.studioMono(11, .semibold)).foregroundStyle(StudioColors.body)
            .frame(minWidth: 18, minHeight: 18).padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(StudioColors.chip))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(StudioColors.line3, lineWidth: 1))
    }
}
