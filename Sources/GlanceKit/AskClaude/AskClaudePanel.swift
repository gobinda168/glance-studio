import AppKit
import GlanceCore
import SwiftUI

/// Ask Claude about a selection: the small panel behind right-click → Ask Claude in Glance's own views and the Services
/// menu in other apps. It shows the selection, what Claude makes of it, and a draft ticket, to-do and note to edit and
/// save; the user can also ask something else about the text. Whatever leaves the Mac (a Jira ticket) is created only
/// when the user presses its button. Esc or ✕ closes it.
@MainActor
public final class AskClaudePanel {
  public static let shared = AskClaudePanel()

  static let width: CGFloat = 460
  static let margin: CGFloat = 24

  private let model = AskClaudeModel()
  private var panel: AskClaudeWindow?
  private var contentSize = CGSize(width: AskClaudePanel.width, height: 360)
  /// The card's top-left corner, in screen coordinates; it stays put as the card grows.
  private var anchor = NSPoint.zero

  private init() {}

  public var isShowing: Bool { panel?.isVisible == true }

  /// Opens the panel on `selection`; `source` names where it was selected ("Terminal", "Safari").
  public func ask(selection: String, source: String?) {
    let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      NSSound.beep()
      return
    }
    model.start(selection: text, source: source)
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if !panel.isVisible { anchor = Self.initialAnchor(height: contentSize.height) }
    place(panel)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Opens the saved to-dos or notes (`notes`: false for the to-dos), with no selection.
  public func showLibrary(notes: Bool) {
    model.openLibrary(notes ? .notes : .todos)
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if !panel.isVisible { anchor = Self.initialAnchor(height: contentSize.height) }
    place(panel)
    panel.makeKeyAndOrderFront(nil)
  }

  public func close() {
    model.cancel()
    panel?.orderOut(nil)
  }

  // MARK: The window

  private func makePanel() -> AskClaudeWindow {
    let panel = AskClaudeWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 400),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    panel.onCancel = { [weak self] in self?.close() }
    let host = AskClaudeHostingView(rootView: AskClaudeView(model: model, close: { [weak self] in self?.close() },
                                                           measured: { [weak self] in self?.measured($0) }))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  private func measured(_ size: CGSize) {
    contentSize = size
    if let panel, panel.isVisible { place(panel) }
  }

  private func place(_ panel: NSWindow) {
    let card = CGSize(width: Self.width, height: max(contentSize.height, 1))
    let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var origin = NSPoint(x: anchor.x, y: anchor.y - card.height)
    // A card that has grown past the bottom edge moves up, and stays where it is after.
    if origin.y < visible.minY + 12 {
      origin.y = visible.minY + 12
      anchor.y = origin.y + card.height
    }
    panel.setFrame(NSRect(origin: origin, size: card).insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  /// Near the pointer, on the screen it is on, inside the visible frame.
  private static func initialAnchor(height: CGFloat) -> NSPoint {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let x = min(max(mouse.x - 40, visible.minX + 12), visible.maxX - width - 12)
    let top = min(max(mouse.y + 24, visible.minY + height + 12), visible.maxY - 12)
    return NSPoint(x: x, y: top)
  }
}

private final class AskClaudeWindow: NSPanel {
  var onCancel: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The first click presses a button.
private final class AskClaudeHostingView: NSHostingView<AskClaudeView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - The card

struct AskClaudeView: View {
  @ObservedObject var model: AskClaudeModel
  @ObservedObject private var captures = CaptureStore.shared
  let close: () -> Void
  let measured: (CGSize) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var asking: Bool
  @State private var newTodo = ""

  private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

  var body: some View {
    card
      .frame(width: AskClaudePanel.width, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGSize.self, of: { $0.size }, action: measured)
      .padding(AskClaudePanel.margin)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      if let tab = model.library {
        library(tab)
      } else {
        quote
        answer
        if model.phase == .ready {
          kinds
          editor
            .transition(.opacity)
        }
        footer
      }
    }
    .padding(16)
    .background {
      if reduceTransparency {
        Self.shape.fill(GlanceColor.solid)
      } else {
        Color.clear.modifier(GlassSurface(shape: Self.shape))
      }
    }
    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 16, y: 7)
    .animation(.smooth(duration: 0.2), value: model.phase)
    .animation(.smooth(duration: 0.2), value: model.kind)
    .animation(.smooth(duration: 0.2), value: model.library)
    .accessibilityElement(children: .contain)
  }

  // MARK: Header, selection, answer

  private var header: some View {
    HStack(spacing: 8) {
      Circle().fill(GlanceColor.coral).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(model.library == nil ? "Ask Glance" : "To-dos & Notes")
        .font(GlanceFont.sans(13, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .accessibilityAddTraits(.isHeader)
      if model.library != nil, model.hasSelection {
        GlanceButton("Back", systemImage: "chevron.left", style: .quiet, label: "Back to the selection", height: 24,
                     cornerRadius: 6) { model.library = nil }
      }
      if model.library == nil, let source = model.source {
        Text(source)
          .font(GlanceFont.mono(10.5))
          .foregroundStyle(GlanceColor.muted)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(GlanceColor.muted.opacity(0.14)))
      }
      Spacer(minLength: 4)
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(GlanceColor.muted)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .help("Close (esc)")
      .accessibilityLabel("Close")
    }
  }

  private var quote: some View {
    HStack(alignment: .top, spacing: 10) {
      RoundedRectangle(cornerRadius: 1.5).fill(GlanceColor.coral.opacity(0.7)).frame(width: 3)
      Text(AskSelection.preview(model.selection))
        .font(GlanceFont.mono(11.5))
        .foregroundStyle(GlanceColor.body)
        .lineLimit(4)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Selected text: \(AskSelection.preview(model.selection))")
  }

  @ViewBuilder
  private var answer: some View {
    switch model.phase {
    case .thinking:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(model.asked.map { "Thinking about “\($0)”…" } ?? "Reading it…")
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(2)
      }
    case .ready:
      VStack(alignment: .leading, spacing: 4) {
        if let asked = model.asked {
          Text(asked)
            .font(GlanceFont.sans(11.5, .medium))
            .foregroundStyle(GlanceColor.muted)
            .lineLimit(2)
        }
        if !model.answer.isEmpty {
          Text(Self.markdown(model.answer))
            .font(GlanceFont.sans(12.5))
            .foregroundStyle(GlanceColor.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.criticalInk)
          .fixedSize(horizontal: false, vertical: true)
        GlanceButton("Try again", style: .secondary, height: 26, cornerRadius: 6) { model.retry() }
      }
    }
  }

  private static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }

  // MARK: What to do with it

  private var kinds: some View {
    HStack(spacing: 6) {
      ForEach(AskSelection.Kind.allCases, id: \.self) { kind in
        KindChip(kind: kind, selected: model.kind == kind, suggested: model.recommended == kind,
                 done: savedAlready(kind)) {
          model.kind = kind
        }
      }
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var editor: some View {
    VStack(alignment: .leading, spacing: 10) {
      switch model.kind {
      case .ticket: ticketEditor
      case .todo: todoEditor
      case .note: noteEditor
      }
      outcome(model.kind)
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(GlanceColor.muted.opacity(0.09)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(GlanceColor.muted.opacity(0.18)))
  }

  private var ticketEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      field("Title", text: $model.ticketTitle, lines: 1...2, weight: .medium)
      field("Description", text: $model.ticketDescription, lines: 3...7)
      if model.trackers.isEmpty {
        Text("Sign in to a Jira site in Glance's Browser to create tickets from here. Until then you can copy this one.")
          .font(GlanceFont.sans(11.5))
          .foregroundStyle(GlanceColor.muted)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer(minLength: 0)
          GlanceButton("Copy ticket", systemImage: "doc.on.doc", style: .secondary, height: 26, cornerRadius: 6) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.ticketText, forType: .string)
          }
        }
      } else {
        destination
        HStack(spacing: 8) {
          Text("Nothing is created until you press this.")
            .font(GlanceFont.sans(11))
            .foregroundStyle(GlanceColor.muted)
          Spacer(minLength: 0)
          if model.saving.contains(.ticket) { ProgressView().controlSize(.small) }
          GlanceButton("Create in \(model.siteName)", systemImage: "ticket", style: .primary, height: 26,
                       cornerRadius: 6) { model.save(.ticket) }
            .disabled(!model.canSaveTicket)
            .opacity(model.canSaveTicket ? 1 : 0.5)
        }
      }
    }
  }

  private var destination: some View {
    HStack(spacing: 8) {
      Text("Create in")
        .font(GlanceFont.sans(11.5))
        .foregroundStyle(GlanceColor.muted)
      if model.trackers.count > 1 {
        Picker("Site", selection: $model.trackerID) {
          ForEach(model.trackers) { tracker in Text(tracker.siteName ?? tracker.server).tag(String?.some(tracker.server)) }
        }
        .labelsHidden()
        .fixedSize()
      } else {
        Text(model.siteName).font(GlanceFont.sans(11.5, .medium)).foregroundStyle(GlanceColor.ink)
      }
      switch model.projectsState {
      case .idle, .loading:
        ProgressView().controlSize(.mini)
      case .failed(let message):
        Text(message).font(GlanceFont.sans(11)).foregroundStyle(GlanceColor.criticalInk).lineLimit(2)
      case .ready:
        if model.projects.isEmpty {
          Text("no projects you can add to").font(GlanceFont.sans(11)).foregroundStyle(GlanceColor.muted)
        } else {
          Picker("Project", selection: $model.projectKey) {
            ForEach(model.projects) { project in
              Text("\(project.key) · \(project.name)").tag(String?.some(project.key))
            }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var todoEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      field("To-do", text: $model.todoText, lines: 1...3, weight: .medium)
      HStack(spacing: 8) {
        Text("Kept in Glance, on this Mac.")
          .font(GlanceFont.sans(11))
          .foregroundStyle(GlanceColor.muted)
        Spacer(minLength: 0)
        GlanceButton("Add to to-dos", systemImage: "checklist", style: .primary, height: 26, cornerRadius: 6) {
          model.save(.todo)
        }
        .disabled(model.todoText.trimmed.isEmpty || savedAlready(.todo))
        .opacity(model.todoText.trimmed.isEmpty || savedAlready(.todo) ? 0.5 : 1)
      }
    }
  }

  private var noteEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      field("Title", text: $model.noteTitle, lines: 1...2, weight: .medium)
      field("Note", text: $model.noteText, lines: 3...8)
      HStack(spacing: 8) {
        Text("Kept in Notes, on this Mac.")
          .font(GlanceFont.sans(11))
          .foregroundStyle(GlanceColor.muted)
        Spacer(minLength: 0)
        GlanceButton("Add to notes", systemImage: "note.text", style: .primary, height: 26, cornerRadius: 6) {
          model.save(.note)
        }
        .disabled((model.noteTitle.trimmed.isEmpty && model.noteText.trimmed.isEmpty) || savedAlready(.note))
        .opacity((model.noteTitle.trimmed.isEmpty && model.noteText.trimmed.isEmpty) || savedAlready(.note) ? 0.5 : 1)
      }
    }
  }

  private func savedAlready(_ kind: AskSelection.Kind) -> Bool {
    if case .saved? = model.outcomes[kind] { return true }
    return false
  }

  private func field(_ label: String, text: Binding<String>, lines: ClosedRange<Int>,
                     weight: Font.Weight = .regular) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(GlanceFont.sans(10.5, .medium))
        .foregroundStyle(GlanceColor.muted)
      TextField(label, text: text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(GlanceFont.sans(12.5, weight))
        .foregroundStyle(GlanceColor.ink)
        .lineLimit(lines)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(GlanceColor.solid.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(GlanceColor.muted.opacity(0.22)))
        .accessibilityLabel(label)
    }
  }

  @ViewBuilder
  private func outcome(_ kind: AskSelection.Kind) -> some View {
    switch model.outcomes[kind] {
    case .saved(let message, let url)?:
      HStack(spacing: 6) {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(GlanceColor.okInk).accessibilityHidden(true)
        Text(message).font(GlanceFont.sans(12, .medium)).foregroundStyle(GlanceColor.okInk)
        Spacer(minLength: 0)
        if kind == .ticket, let url {
          GlanceButton("Open", style: .quiet, label: "Open the ticket in the browser", height: 24, cornerRadius: 6) {
            NSWorkspace.shared.open(url)
          }
        } else if kind == .note {
          GlanceButton(captures.onOpenNote == nil ? "View notes" : "Open note", style: .quiet,
                       label: "Show the note", height: 24, cornerRadius: 6) {
            if captures.onOpenNote == nil { model.library = .notes } else { openNote(captures.notes.first?.id) }
          }
        } else if kind == .todo {
          GlanceButton("View to-dos", style: .quiet, label: "Show your to-dos", height: 24, cornerRadius: 6) {
            model.library = .todos
          }
        }
      }
    case .failed(let message)?:
      Text(message)
        .font(GlanceFont.sans(11.5))
        .foregroundStyle(GlanceColor.criticalInk)
        .fixedSize(horizontal: false, vertical: true)
    case nil:
      EmptyView()
    }
  }

  // MARK: Footer

  private var footer: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(GlanceColor.coralInk)
          .accessibilityHidden(true)
        TextField("Ask something else about this…", text: $model.question)
          .textFieldStyle(.plain)
          .font(GlanceFont.sans(12.5))
          .foregroundStyle(GlanceColor.ink)
          .focused($asking)
          .onSubmit { model.ask() }
          .accessibilityLabel("Ask something else about this")
        Button { model.ask() } label: {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 18))
            .foregroundStyle(model.question.trimmed.isEmpty || model.phase == .thinking
              ? GlanceColor.muted.opacity(0.5) : GlanceColor.coral)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(model.question.trimmed.isEmpty || model.phase == .thinking)
        .accessibilityLabel("Ask")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GlanceColor.solid.opacity(0.7)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
        .strokeBorder(asking ? GlanceColor.coral.opacity(0.6) : GlanceColor.muted.opacity(0.22)))

      HStack(spacing: 4) {
        GlanceButton("To-dos (\(captures.openCount))", systemImage: "checklist", style: .quiet,
                     label: "Show your to-dos", height: 24, cornerRadius: 6) { model.library = .todos }
        GlanceButton("Notes (\(captures.notes.count))", systemImage: "note.text", style: .quiet,
                     label: "Show your notes", height: 24, cornerRadius: 6) { model.library = .notes }
        Spacer(minLength: 0)
      }
    }
  }

  // MARK: Saved to-dos and notes

  private func library(_ tab: AskClaudeModel.LibraryTab) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        ForEach(AskClaudeModel.LibraryTab.allCases, id: \.self) { item in
          let count = item == .todos ? captures.openCount : captures.notes.count
          Button { model.library = item } label: {
            Text("\(item.rawValue) \(count)")
              .font(GlanceFont.sans(12, tab == item ? .semibold : .medium))
              .foregroundStyle(tab == item ? GlanceColor.ink : GlanceColor.body)
              .padding(.horizontal, 10)
              .frame(height: 26)
              .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tab == item ? GlanceColor.coral.opacity(0.16) : GlanceColor.muted.opacity(0.07)))
              .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tab == item ? GlanceColor.coral.opacity(0.55) : Color.clear))
          }
          .buttonStyle(.plain)
          .focusEffectDisabled()
          .accessibilityLabel("\(item.rawValue), \(count)")
          .accessibilityAddTraits(tab == item ? .isSelected : [])
        }
        Spacer(minLength: 0)
      }
      switch tab {
      case .todos: todos
      case .notes: notes
      }
    }
  }

  @ViewBuilder
  private var todos: some View {
    let list = Captures.ordered(captures.todos)
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(GlanceColor.coralInk)
          .accessibilityHidden(true)
        TextField("Add a to-do", text: $newTodo)
          .textFieldStyle(.plain)
          .font(GlanceFont.sans(12.5))
          .foregroundStyle(GlanceColor.ink)
          .onSubmit(addTodo)
          .accessibilityLabel("Add a to-do")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GlanceColor.solid.opacity(0.7)))
      .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(GlanceColor.muted.opacity(0.22)))
      if list.isEmpty {
        Text("No to-dos yet. Select text anywhere, right-click → Ask Glance…, and add one.")
          .font(GlanceFont.sans(11.5))
          .foregroundStyle(GlanceColor.muted)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(list) { todo in todoRow(todo) }
          }
        }
        .frame(maxHeight: 280)
      }
    }
  }

  private func addTodo() {
    try? captures.addTodo(newTodo, source: nil)
    newTodo = ""
  }

  private func todoRow(_ todo: Captures.Todo) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Button { captures.toggle(todo) } label: {
        Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(todo.done ? GlanceColor.okInk : GlanceColor.muted)
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .accessibilityLabel(todo.done ? "Mark not done" : "Mark done")
      VStack(alignment: .leading, spacing: 1) {
        Text(todo.text)
          .font(GlanceFont.sans(12))
          .foregroundStyle(todo.done ? GlanceColor.muted : GlanceColor.ink)
          .strikethrough(todo.done)
          .fixedSize(horizontal: false, vertical: true)
        if let source = todo.source {
          Text("from \(source)").font(GlanceFont.sans(10.5)).foregroundStyle(GlanceColor.muted)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button { captures.remove(todo) } label: {
        Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(GlanceColor.muted)
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .help("Delete")
      .accessibilityLabel("Delete to-do")
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var notes: some View {
    if captures.notes.isEmpty {
      Text("No notes yet. Select text anywhere, right-click → Ask Glance…, and add a note.")
        .font(GlanceFont.sans(11.5))
        .foregroundStyle(GlanceColor.muted)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(captures.notes) { note in
            Button { openNote(note.id) } label: {
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Text(note.displayTitle).font(GlanceFont.sans(12.5, .semibold)).foregroundStyle(GlanceColor.ink)
                    .lineLimit(1)
                  if !note.diagrams.isEmpty {
                    Text("\(note.diagrams.count) diagram\(note.diagrams.count == 1 ? "" : "s")")
                      .font(GlanceFont.sans(10)).foregroundStyle(GlanceColor.tealInk)
                  }
                }
                Text(note.updated.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                  .font(GlanceFont.sans(10.5)).foregroundStyle(GlanceColor.muted)
                if !note.body.isEmpty {
                  Text(note.body).font(GlanceFont.sans(12)).foregroundStyle(GlanceColor.body)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(GlanceColor.muted.opacity(0.09)))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(captures.onOpenNote == nil)
            .help("Open in Notes")
          }
        }
      }
      .frame(maxHeight: 320)
    }
    if captures.onOpenNote != nil {
      HStack {
        Spacer(minLength: 0)
        GlanceButton("Open Notes", systemImage: "arrow.up.forward.square", style: .quiet, height: 24, cornerRadius: 6) {
          openNote(nil)
        }
      }
    }
  }

  /// The note (nil: the notes) in Studio's To-dos & Notes tab; the panel steps aside.
  private func openNote(_ id: UUID?) {
    guard let open = captures.onOpenNote else { return }
    close()
    open(id)
  }
}

private struct KindChip: View {
  let kind: AskSelection.Kind
  let selected: Bool
  let suggested: Bool
  let done: Bool
  let action: () -> Void
  @State private var hovering = false

  private var title: String {
    switch kind {
    case .ticket: "Ticket"
    case .todo: "To-do"
    case .note: "Note"
    }
  }

  private var symbol: String {
    switch kind {
    case .ticket: "ticket"
    case .todo: "checklist"
    case .note: "note.text"
    }
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Image(systemName: done ? "checkmark" : symbol).font(.system(size: 11, weight: .medium))
          .accessibilityHidden(true)
        Text(title).font(GlanceFont.sans(12, selected ? .semibold : .medium))
        if suggested {
          Text("suggested")
            .font(GlanceFont.sans(9.5, .medium))
            .foregroundStyle(selected ? GlanceColor.coralInk : GlanceColor.muted)
        }
      }
      .foregroundStyle(selected ? GlanceColor.ink : GlanceColor.body)
      .padding(.horizontal, 10)
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(selected ? GlanceColor.coral.opacity(0.16) : GlanceColor.muted.opacity(hovering ? 0.14 : 0.07)))
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(selected ? GlanceColor.coral.opacity(0.55) : Color.clear, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .accessibilityLabel(suggested ? "\(title), suggested" : title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
