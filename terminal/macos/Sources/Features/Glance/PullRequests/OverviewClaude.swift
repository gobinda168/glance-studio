import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// Claude's read of the pull request (board 1's note): what it does, and what's worth a look. Read aloud reads it in
/// the Glance pane's voice (⌥. pauses, as for any reply). Hidden without Claude Code.
struct ClaudeReadCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let read: PullRequestStore.Read
    @ObservedObject private var inbox = ReviewInboxStore.shared

    var body: some View {
        if read != .unavailable && !(read == .idle && inbox.claudeInstalled == false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    CoralDot(size: 11)
                    Text("CLAUDE'S READ OF THIS PR")
                        .font(.studio(11, .semibold))
                        .tracking(0.66)
                        .foregroundStyle(StudioColors.noteInk)
                    Spacer(minLength: 4)
                    if case .ready(let text) = read {
                        Button { GlanceTerminalHost.shared.readAloud(text) } label: {
                            HStack(spacing: 6) {
                                StudioIcon(.speaker, size: 14)
                                Text("Read aloud").font(.studio(12, .medium))
                                Kbd("⌥.")
                            }
                            .foregroundStyle(StudioColors.noteInk)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Read aloud")
                    }
                }
                switch read {
                case .ready(let text):
                    StudioMarkdownView(markdown: text, size: 14, color: StudioColors.ink) {
                        PullRequestLinkRouter.open($0, from: controller)
                    }
                case .idle:
                    if Prefs.pullRequestsAutoClaude {
                        reading
                    } else {
                        Text("Claude can read this PR: what it does, and what's worth a look.")
                            .font(.studio(13))
                            .foregroundStyle(StudioColors.noteInk)
                        StudioButton(title: "Ask Claude to read this PR", style: .quiet, height: 26) {
                            PullRequestStore.shared.retryRead(controller.key, root: controller.root)
                        }
                    }
                case .reading:
                    reading
                case .failed(let message):
                    InlineError(message: message) {
                        PullRequestStore.shared.retryRead(controller.key, root: controller.root)
                    }
                case .unavailable:
                    EmptyView()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.note))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
            .onAppear { inbox.checkClaude() }
        }
    }

    private var reading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Claude is reading the pull request…").font(.studio(13)).foregroundStyle(StudioColors.noteInk)
        }
    }
}

/// Ask Claude about this PR's answers (spec 2026-10-12-pr-sidebar-tabs-design.md, "Ask Claude"), above the comment
/// box: each question and Claude's answer, the one being answered with Stop, a failure with Retry, and × to clear
/// them. A follow-up goes in the box.
struct AskClaudeCard: View {
    @ObservedObject var controller: PullRequestWindowController
    let ask: PullRequestStore.Ask

    /// Where the page scrolls when a question is asked.
    static let anchor = "ask-claude"

    var body: some View {
        if !ask.exchanges.isEmpty || ask.question != nil {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    CoralDot(size: 11)
                    Text("ASKED CLAUDE")
                        .font(.studio(11, .semibold))
                        .tracking(0.66)
                        .foregroundStyle(StudioColors.noteInk)
                    Spacer(minLength: 4)
                    SmallIconButton(icon: .close, label: "Clear") { PullRequestStore.shared.clearAsks(controller.key) }
                }
                ForEach(Array(ask.exchanges.enumerated()), id: \.offset) { _, exchange in
                    VStack(alignment: .leading, spacing: 6) {
                        question(exchange.question)
                        StudioMarkdownView(markdown: exchange.answer, size: 14, color: StudioColors.ink) {
                            PullRequestLinkRouter.open($0, from: controller)
                        }
                    }
                }
                if let asked = ask.question {
                    VStack(alignment: .leading, spacing: 6) {
                        question(asked)
                        if ask.running {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Claude is reading the pull request…")
                                    .font(.studio(13))
                                    .foregroundStyle(StudioColors.noteInk)
                                Spacer(minLength: 4)
                                StudioButton(title: "Stop", style: .quiet, height: 26) {
                                    PullRequestStore.shared.stopAsk(controller.key)
                                }
                            }
                        } else if let error = ask.error {
                            InlineError(message: error) {
                                PullRequestStore.shared.retryAsk(controller.key, root: controller.root)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.note))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
            .id(Self.anchor)
        }
    }

    private func question(_ text: String) -> some View {
        Text(text)
            .font(.studio(13, .semibold))
            .foregroundStyle(StudioColors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// The comment box (board 1): Markdown, Comment ⌘↩, Close PR, and Ask Claude about this PR ⌘I, the page's glow ring,
/// which asks Claude the box's words instead of posting them (or, empty, what to know before merging); the answer
/// shows above the box (`AskClaudeCard`). With the project on this Mac, Claude reads its files too.
struct Composer: View {
    @ObservedObject var controller: PullRequestWindowController
    let page: PullRequestPage.Page
    let entry: PullRequestStore.Entry
    @ObservedObject private var inbox = ReviewInboxStore.shared
    @State private var text = ""
    @State private var confirmingClose = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(login: entry.settings?.viewer ?? entry.extras?.viewer ?? "", size: 24).padding(.top, 4)
            VStack(alignment: .leading, spacing: 0) {
                StudioTextEditor(placeholder: "Leave a comment — Markdown, @mentions, #references", text: $text, minHeight: 72)
                Rectangle().fill(StudioColors.line2).frame(height: 1)
                HStack(spacing: 8) {
                    GlowPill(title: "Ask Claude about this PR", hint: "⌘I", busy: entry.ask.running,
                             enabled: inbox.claudeInstalled != false) { ask() }
                        .keyboardShortcut("i", modifiers: .command)
                        .help(inbox.claudeInstalled == false ? "Install Claude Code to ask Claude"
                              : entry.ask.running ? "Claude is answering" : "Ask Claude about this PR (⌘I)")
                    Spacer(minLength: 8)
                    if page.state == .open {
                        StudioButton(title: "Close PR", style: .quiet, busy: entry.busy.contains("close")) {
                            confirmingClose = true
                        }
                    }
                    StudioButton(title: "Comment", hint: "⌘↩", busy: entry.busy.contains("comment"),
                                 enabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        let words = text
                        PullRequestStore.shared.perform(.comment(words), key: controller.key, root: controller.root) {
                            text = ""
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                if let error = entry.errors["comment"] ?? entry.errors["close"] {
                    InlineError(message: error)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1))
        }
        .onAppear { inbox.checkClaude() }
        .confirmationDialog("Close #\(page.number) without merging?", isPresented: $confirmingClose) {
            Button("Close Pull Request", role: .destructive) {
                PullRequestStore.shared.perform(.close, key: controller.key, root: controller.root)
            }
        }
    }

    /// The box's words (or the general question) to Claude; the box empties once it's asked.
    private func ask() {
        if PullRequestStore.shared.ask(controller.key, root: controller.root, question: text) { text = "" }
    }
}
