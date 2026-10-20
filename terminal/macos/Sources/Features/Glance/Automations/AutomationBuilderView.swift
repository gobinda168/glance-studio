import GlanceCore
import GlanceKit
import SwiftUI

/// The builder tab: the side bar column, the conversation, and the Glance pane.
struct AutomationBuilderTabView: View {
    @ObservedObject var controller: AutomationBuilderTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                AutomationBuilderPage(controller: controller)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .background(StudioColors.background)
                    .overlay(alignment: .bottomTrailing) {
                        if controller.glancePaneOpen && controller.glancePlacement == .floating {
                            GlanceFloatView()
                        }
                    }
                if controller.glancePaneOpen && controller.glancePlacement == .sidebar {
                    GlancePaneView()
                        .glanceSidebar()
                }
            }
        }
        .glancePlacement($controller.glancePlacement)
        .activityStrip()
    }
}

/// Header, thread, the saved banner, and the composer. One coral primary at a time: Send, or "Open <name>" once a
/// save has landed. No glow: everything on this page is Claude's.
private struct AutomationBuilderPage: View {
    @ObservedObject var controller: AutomationBuilderTabController
    @ObservedObject private var engine = AutomationEngine.shared

    var body: some View {
        let saves = controller.saved.compactMap { engine.entry($0) }
        VStack(spacing: 0) {
            header
            Rectangle().fill(StudioColors.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if controller.thread.items.isEmpty {
                            AutomationBuilderEmpty(controller: controller)
                        }
                        ForEach(Array(controller.thread.items.enumerated()), id: \.offset) { _, item in
                            AutomationBuilderRow(item: item, open: controller.openLink)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: controller.thread.items.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            if !saves.isEmpty {
                VStack(spacing: 8) {
                    ForEach(saves, id: \.id) { entry in
                        AutomationBuilderSaved(entry: entry, primary: entry.id == saves.last?.id) {
                            controller.openSaved(entry.id)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 12)
            }
            AutomationBuilderComposer(controller: controller, primary: saves.isEmpty)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                CoralDot(size: 12)
                Text(AutomationBuilderText.title(controller.subject))
                    .font(.studio(18, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if controller.working {
                    StatePill(text: "Working", icon: .spinner, tone: .coral)
                }
            }
            Text(AutomationBuilderText.subtitle(controller.subject))
                .font(.studio(12.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }
}

/// Before the first message: what to ask (New automation), or what goes with the first message.
private struct AutomationBuilderEmpty: View {
    @ObservedObject var controller: AutomationBuilderTabController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch controller.subject {
            case .new, .newAgent:
                Caption("For example")
                ForEach(controller.subject == .newAgent ? AutomationBuilderText.agentExamples
                        : AutomationBuilderText.examples, id: \.self) { example in
                    Button { controller.draft = example } label: {
                        Text(example)
                            .font(.studio(13))
                            .foregroundStyle(StudioColors.body)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.chip))
                    }
                    .buttonStyle(.plain)
                    .help("Put this in the message")
                }
            case .edit:
                Text("Say what should change. Claude copies the automation into a draft, changes it, checks it, "
                     + "and saves it as the next version.")
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.body)
            case .run:
                Text("The run's status, inputs and failing lines go with your first message.")
                    .font(.studio(13))
                    .foregroundStyle(StudioColors.body)
            }
        }
    }
}

/// One row of the conversation.
private struct AutomationBuilderRow: View {
    let item: ChatItem
    let open: (URL) -> Void

    var body: some View {
        switch item {
        case .user(let text, _):
            HStack {
                Spacer(minLength: 80)
                Text(AutomationBuilderText.displayText(text))
                    .font(.studio(13.5))
                    .foregroundStyle(StudioColors.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.chip))
            }
        case .assistant(let blocks):
            StudioMarkdownView(markdown: blocks.map(\.markdown).joined(separator: "\n\n"), open: open)
        case .tool(let name, let detail):
            toolLine(icon: .checklist, color: StudioColors.muted, name: name, detail: detail)
        case .denied(let name, let detail):
            toolLine(icon: .alert, color: StudioColors.danger, name: "Not allowed: " + name, detail: detail)
        }
    }

    private func toolLine(icon: StudioIcons.Name, color: Color, name: String, detail: String) -> some View {
        HStack(spacing: 8) {
            StudioIcon(icon, size: 12).foregroundStyle(color)
            Text(Self.toolName(name)).font(.studioMono(11.5, .medium)).foregroundStyle(color)
            Text(detail)
                .font(.studioMono(11.5))
                .foregroundStyle(StudioColors.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// "mcp__plugin_glance_glance__automation_save" reads "automation_save".
    static func toolName(_ name: String) -> String {
        name.hasPrefix(AutomationMCP.toolPrefix) ? String(name.dropFirst(AutomationMCP.toolPrefix.count)) : name
    }
}

/// A save landed: what it is, whether it waits for approval, and Open <name>.
private struct AutomationBuilderSaved: View {
    let entry: AutomationEntry
    /// Only the latest save carries the coral button.
    let primary: Bool
    let open: () -> Void

    var body: some View {
        StudioCard(rim: true) {
            HStack(spacing: 12) {
                StudioIcon(.check, size: 16, weight: 2.3).foregroundStyle(StudioColors.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved \(entry.name) v\(entry.manifest?.version ?? 0)")
                        .font(.studio(13, .semibold))
                        .foregroundStyle(StudioColors.ink)
                    Text(entry.isBroken ? (entry.brokenLine ?? "Broken")
                         : entry.approval.isApproved ? "Its approval still holds."
                         : "It waits for your approval in Setup before it can run.")
                        .font(.studio(12))
                        .foregroundStyle(entry.isBroken ? StudioColors.danger : StudioColors.muted)
                }
                Spacer(minLength: 8)
                StudioButton(title: "Open \(entry.name)", style: primary ? .primary : .secondary, action: open)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

/// The message field, Send (⌘↩) or Stop (Esc), and what went wrong.
private struct AutomationBuilderComposer: View {
    @ObservedObject var controller: AutomationBuilderTabController
    /// Send is the coral primary until a save offers "Open <name>".
    let primary: Bool

    var body: some View {
        let empty = controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if let problem = controller.problem {
                InlineError(message: problem)
            }
            StudioTextEditor(placeholder: AutomationBuilderText.placeholder(controller.subject),
                             text: $controller.draft, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioColors.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(StudioColors.line, lineWidth: 1))
            HStack(spacing: 12) {
                Text("Claude works in your automation library. Nothing it saves runs until you approve it.")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                Spacer(minLength: 8)
                if controller.working {
                    StudioButton(title: "Stop", hint: "Esc", style: .secondary) { controller.stop() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    StudioButton(title: "Send", hint: "⌘↩", style: primary ? .primary : .secondary,
                                 enabled: !empty) { controller.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(empty ? "Write a message first" : "Send to Claude (⌘↩)")
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .background(StudioColors.bar)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
    }
}
