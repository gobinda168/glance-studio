import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The right panel: where the session runs, how full its context is, which connectors Claude Code has, and what the
/// folder has changed. Sections fold; rows are 28pt with a muted 15pt symbol (the replica's `.gv-panel`).
struct SessionPanelView: View {
    @ObservedObject var model: SessionViewModel
    @ObservedObject private var proof: ProofModel
    @ObservedObject private var assets: AssetsModel
    @ObservedObject private var connectors = ConnectorProbe.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open: Set<Section> = [.explainer, .environment, .context, .changes, .assets, .proof]

    fileprivate enum Section: String, CaseIterable {
        case explainer = "Explainer", environment = "Environment", context = "Context", connectors = "Connectors", changes = "Changes", assets = "Assets", proof = "Proof"
    }

    init(model: SessionViewModel) {
        self.model = model
        proof = model.proof
        assets = model.assets
    }

    var body: some View {
        ScrollViewReader { scroller in
        ScrollView {
            VStack(spacing: 0) {
                if ExplainerModel.isEnabled, model.link != nil {
                    section(.explainer, spoken: model.explainers.modeOn ? "on" : "off",
                            summary: { ExplainerModeSummary(explainers: model.explainers) },
                            body: { ExplainerModeBody(explainers: model.explainers) })
                }
                section(.environment, spoken: nil, summary: { EmptyView() }, body: { EnvironmentBody(model: model) })
                // A recap has no running session: no context window and no connectors of its own.
                if !inRecap {
                    section(.context, spoken: "\(model.timeline.usage.contextPercent) percent", summary: { ContextSummary(usage: model.timeline.usage) }, body: { ContextBody(usage: model.timeline.usage) })
                    section(.connectors, spoken: ConnectorsSummary.spoken(connectors), summary: { ConnectorsSummary(connectors: connectors) }, body: { ConnectorsBody(connectors: connectors) })
                }
                section(.changes, spoken: ChangesSummary.spoken(model.changes), summary: { ChangesSummary(changes: model.changes) }, body: { ChangesBody(changes: model.changes) })
                // Between Changes and Proof, hidden when there is nothing to show. A recap has it too: its last session's captures, and
                // the folder's files while the worktree is there.
                if StudioFeatures.shared.isOn(.commandCenter), !assets.items.isEmpty {
                    section(.assets, spoken: "\(assets.items.count) \(assets.items.count == 1 ? "item" : "items")",
                            summary: { AssetsSectionSummary(assets: assets) }, body: { AssetsSectionBody(assets: assets) })
                        .id(Self.assetsID)
                }
                if StudioFeatures.shared.isOn(.commandCenter), model.link != nil || inRecap {
                    section(.proof, title: inRecap ? "Last session's proof" : nil, spoken: proof.setup.setup == nil ? nil : proof.pill.label,
                            summary: { ProofSectionSummary(proof: proof) }, body: { ProofPanelView(model: model, readOnly: model.link == nil) })
                }
            }
        }
        // Proof's count was pressed: open the section, then bring it into view once it has its height.
        .onChange(of: assets.request) { _, request in
            guard request != nil else { return }
            open.insert(.assets)
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { scroller.scrollTo(Self.assetsID, anchor: .top) }
            }
        }
        }
        .background(StudioColors.bar)
        .overlay(alignment: .leading) { Rectangle().fill(StudioColors.line2).frame(width: 1) }
        // check() caches: a second panel, or a second appearance, doesn't run Claude again.
        .onAppear { connectors.check(); assets.panelAppeared() }
        .onDisappear { assets.panelDisappeared() }
    }

    private static let assetsID = "assets-section"

    /// The tab shows a finished worktree's recap, not a session.
    private var inRecap: Bool { model.link == nil && model.recap != nil }

    private func section<S: View, B: View>(_ kind: Section, title: String? = nil, spoken: String?, @ViewBuilder summary: () -> S, @ViewBuilder body: () -> B) -> some View {
        let isOpen = open.contains(kind)
        return VStack(spacing: 0) {
            Button {
                if isOpen { open.remove(kind) } else { open.insert(kind) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StudioColors.muted)
                        .rotationEffect(.degrees(isOpen ? 0 : -90))
                    Text(title ?? kind.rawValue).font(.studio(12.5, .semibold)).foregroundStyle(StudioColors.ink)
                    Spacer(minLength: 8)
                    summary().font(.studio(12)).lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title ?? kind.rawValue)
            .accessibilityValue([isOpen ? "expanded" : "collapsed", spoken].compactMap { $0 }.joined(separator: ", "))
            if isOpen {
                VStack(alignment: .leading, spacing: 0) { body() }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(StudioColors.line2).frame(height: 1)
        }
    }
}

// MARK: Rows

/// A 28pt row: a muted 15pt symbol, then the content.
struct PanelRow<Content: View>: View {
    let symbol: String
    var tint: Color = StudioColors.muted
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 15, height: 15)
            content()
        }
        .frame(minHeight: 28, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Environment

private struct EnvironmentBody: View {
    @ObservedObject var model: SessionViewModel
    // Low-frequency: the row's host is created only while both hold. The session's pages (which change on every tool
    // call and title) are observed by the host alone.
    @ObservedObject private var features = StudioFeatures.shared
    @ObservedObject private var browserGate = SessionBrowserGate.shared

    var body: some View {
        // A recap's folder is its worktree, and only while that is still there.
        let cwd = model.link?.cwd ?? model.recap.flatMap { $0.exists ? model.cwd : nil }
        PanelRow(symbol: "laptopcomputer") {
            Text("This Mac").font(.studio(13)).foregroundStyle(StudioColors.ink)
        }
        if let cwd {
            PanelRow(symbol: "folder") {
                HStack(spacing: 6) {
                    Text(model.folderName).font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink).lineLimit(1)
                    Text((cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.studio(12)).foregroundStyle(StudioColors.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                .help(cwd)
            }
        }
        if let branch = model.branch {
            PanelRow(symbol: "arrow.triangle.branch") {
                Text(branch).font(.studioMono(12)).foregroundStyle(StudioColors.ink).lineLimit(1).truncationMode(.middle)
            }
        }
        if features.isOn(.commandCenter), browserGate.hasWindows, model.link != nil {
            BrowserRowHost(claudePID: model.claudePID, session: model.link?.sessionID)
        }
        if let cwd {
            HStack(spacing: 4) {
                quiet("Open in Razor", symbol: "doc.text") { openInRazor(cwd) }
                quiet("Reveal in Finder", symbol: "magnifyingglass") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
                }
            }
            .padding(.top, 4)
            .padding(.leading, -8)
        }
    }

    private func quiet(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.studio(12)).lineLimit(1)
            }
            .foregroundStyle(StudioColors.body)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuietButtonStyle())
    }

    private func openInRazor(_ folder: String) {
        // openFromPane skips directories; a folder opens as an editor tab rooted at its project.
        let window = model.controller?.window ?? NSApp.keyWindow
        EditorTabs.open(EditorTabs.preferredKind, root: ProjectRoot.find(from: folder), from: window)
    }
}

/// Owns the session's pages source, so only a change to this session's pages redraws the row.
private struct BrowserRowHost: View {
    let claudePID: Int32?
    let session: String?
    @StateObject private var source = SessionBrowserPages()

    var body: some View {
        Group {
            if !source.pages.isEmpty { BrowserRow(pages: source.pages, front: source.front) }
        }
        .onAppear { source.follow(claudePID: claudePID, session: session) }
        .onChange(of: claudePID) { _, _ in source.follow(claudePID: claudePID, session: session) }
        .onChange(of: session) { _, _ in source.follow(claudePID: claudePID, session: session) }
    }
}

/// The session's browser window: one page shows its host and path; several show "N pages" and a menu to pick one.
/// Show browser brings the window forward with that page in front.
private struct BrowserRow: View {
    let pages: [AgentBrowserModel.Page]
    /// The page that changed last: Show browser brings it forward.
    let front: String?

    var body: some View {
        PanelRow(symbol: "globe") {
            if pages.count == 1, let page = pages.first {
                let label = BrowserPageLabel(url: page.url)
                HStack(spacing: 0) {
                    Text(label.host).font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
                    Text(label.path).font(.studio(13)).foregroundStyle(StudioColors.muted)
                }
                .lineLimit(1).truncationMode(.middle)
                .help(page.url)
            } else {
                Text("\(pages.count) pages").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink).lineLimit(1)
                    .help(pages.map(\.url).joined(separator: "\n"))
            }
            Spacer(minLength: 8)
            HStack(spacing: 1) {
                Button("Show browser") { AgentBrowserWindow.show(targetId: front ?? pages[pages.count - 1].id) }
                    .buttonStyle(EmptyButtonStyle(primary: false))
                    .help("Bring this session's browser window to the front")
                    .fixedSize()
                if pages.count > 1 {
                    Menu {
                        Section("Pages in this session's browser") {
                            ForEach(pages) { page in
                                let label = BrowserPageLabel(url: page.url)
                                Button(label.host + label.path) { AgentBrowserWindow.show(targetId: page.id) }
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StudioColors.ink)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(StudioColors.chip))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(StudioColors.line, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose a page")
                    .accessibilityLabel("Choose a page")
                }
            }
        }
    }
}

/// A page's address as the panel shows it: the host, then the path dimmed. Not a web address (a new tab, a blank page):
/// what Chromium calls it, whole.
private struct BrowserPageLabel {
    let host: String
    let path: String

    init(url: String) {
        if url.isEmpty || url == "about:blank" || url.hasPrefix("chrome://newtab") {
            host = "New tab"
            path = ""
        } else if let parts = URLComponents(string: url), let host = parts.host, parts.scheme == "http" || parts.scheme == "https" {
            self.host = host
            path = parts.path == "/" ? "" : parts.path
        } else {
            host = url
            path = ""
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? StudioColors.field : Color.clear))
    }
}

// MARK: Context

/// How full the context window is: teal; amber from 80% (with "High"); danger from 95% (with "Full").
struct ContextLevel {
    let percent: Int
    var word: String? { percent >= 95 ? "Full" : percent >= 80 ? "High" : nil }
    var tone: Color { percent >= 95 ? StudioColors.danger : percent >= 80 ? StudioColors.amber : StudioColors.tealInk }
}

private struct ContextSummary: View {
    let usage: SessionUsage

    var body: some View {
        let level = ContextLevel(percent: usage.contextPercent)
        HStack(spacing: 6) {
            if let word = level.word { Text(word).font(.studio(11, .semibold)).foregroundStyle(level.tone) }
            Text("\(level.percent)%").font(.studioMono(12)).monospacedDigit().foregroundStyle(StudioColors.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context \(level.percent) percent\(level.word.map { ", " + $0.lowercased() } ?? "")")
    }
}

private struct ContextBody: View {
    let usage: SessionUsage

    var body: some View {
        let level = ContextLevel(percent: usage.contextPercent)
        PanelRow(symbol: "gauge.with.dots.needle.50percent") {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(StudioColors.chip)
                    Capsule().fill(level.tone).frame(width: 48 * CGFloat(level.percent) / 100)
                }
                .frame(width: 48, height: 4)
                .accessibilityHidden(true)
                Text("\(level.percent)% of \(UsageFormat.tokens(usage.contextWindow))")
                    .font(.studio(13)).monospacedDigit().foregroundStyle(StudioColors.ink)
                if let word = level.word {
                    Text(word).font(.studio(11, .semibold)).foregroundStyle(level.tone)
                }
            }
        }
        let name = usage.model.map(UsagePricing.displayName)
        Text([name, UsageFormat.cost(usage.cost)].compactMap { $0 }.joined(separator: " · "))
            .font(.studio(12)).foregroundStyle(StudioColors.muted)
            .padding(.leading, 25)
    }
}

// MARK: Connectors

private extension ConnectorServer {
    var needsAttention: Bool { status == .needsAuth || status == .failed }
    var statusWord: String {
        switch status {
        case .connected: return "Connected"
        case .needsAuth: return "Needs sign-in"
        case .failed: return "Failed"
        case .pending: return "Connecting"
        case .other: return "Unknown"
        }
    }
}

private struct ConnectorsSummary: View {
    @ObservedObject var connectors: ConnectorProbe

    /// What VoiceOver hears for the folded section.
    @MainActor static func spoken(_ connectors: ConnectorProbe) -> String {
        let servers = connectors.servers
        if !connectors.checked { return connectors.checking ? "checking" : "not checked" }
        if connectors.error != nil && servers.isEmpty { return "unavailable" }
        let attention = servers.filter(\.needsAttention).count
        let connected = servers.filter { $0.status == .connected }.count
        return (attention > 0 ? ["\(attention) need attention"] : []).joined() + (attention > 0 ? ", " : "") + "\(connected) connected"
    }

    var body: some View {
        let servers = connectors.servers
        let connected = servers.filter { $0.status == .connected }.count
        let attention = servers.filter(\.needsAttention).count
        HStack(spacing: 6) {
            if !connectors.checked {
                Text(connectors.checking ? "Checking…" : "—").foregroundStyle(StudioColors.muted)
            } else if connectors.error != nil && servers.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("Unavailable")
                }
                .foregroundStyle(StudioColors.amber)
            } else {
                if attention > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        Text("\(attention) need attention")
                    }
                    .foregroundStyle(StudioColors.amber)
                }
                Text("\(connected) connected").foregroundStyle(StudioColors.muted)
            }
        }
    }
}

private struct ConnectorsBody: View {
    @ObservedObject var connectors: ConnectorProbe

    var body: some View {
        if !connectors.checked {
            Text(connectors.checking ? "Asking Claude Code which connectors it has…" : "Not checked yet.")
                .font(.studio(12)).foregroundStyle(StudioColors.muted).frame(minHeight: 28, alignment: .leading)
        } else if connectors.servers.isEmpty {
            Text(connectors.error ?? "No connectors.")
                .font(.studio(12)).foregroundStyle(StudioColors.muted).frame(minHeight: 28, alignment: .leading)
        } else {
            ForEach(connectors.servers) { server in
                PanelRow(symbol: server.needsAttention ? "exclamationmark.triangle.fill" : "puzzlepiece.extension",
                         tint: server.needsAttention ? StudioColors.amber : StudioColors.muted) {
                    Text(server.title).font(.studio(13)).foregroundStyle(StudioColors.ink).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(server.statusWord).font(.studio(12))
                        .foregroundStyle(server.needsAttention ? StudioColors.amber : StudioColors.muted).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: Changes

private struct ChangesSummary: View {
    let changes: WorkingChanges.Summary?

    static func spoken(_ changes: WorkingChanges.Summary?) -> String {
        guard let changes, !changes.isClean else { return "no changes" }
        return "\(changes.files) \(changes.files == 1 ? "file" : "files"), \(changes.additions) added, \(changes.deletions) removed"
    }

    var body: some View {
        if let changes, !changes.isClean {
            HStack(spacing: 6) {
                Text("\(changes.files) \(changes.files == 1 ? "file" : "files")").foregroundStyle(StudioColors.muted)
                lines(changes)
            }
        } else {
            Text("No changes").foregroundStyle(StudioColors.muted)
        }
    }
}

@MainActor private func lines(_ c: WorkingChanges.Summary) -> some View {
    HStack(spacing: 6) {
        Text("+\(c.additions)").foregroundStyle(StudioColors.ok)
        Text("\u{2212}\(c.deletions)").foregroundStyle(StudioColors.danger)
    }
    .font(.studioMono(12)).monospacedDigit()
}

private struct ChangesBody: View {
    let changes: WorkingChanges.Summary?

    var body: some View {
        PanelRow(symbol: "doc.text") {
            if let changes, !changes.isClean {
                Text("\(changes.files) \(changes.files == 1 ? "file" : "files")")
                    .font(.studio(13)).foregroundStyle(StudioColors.ink)
                Spacer(minLength: 8)
                lines(changes)
            } else {
                Text("No changes").font(.studio(13)).foregroundStyle(StudioColors.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
