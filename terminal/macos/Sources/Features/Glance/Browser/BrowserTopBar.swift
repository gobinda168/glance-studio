import AppKit
import GlanceCore
import SwiftUI

/// A Browser tab's top bar (spec, "Surface"): back, forward, reload or stop; the address field; ☆ Save as app; ⋯;
/// and the load's progress along its bottom edge.
struct BrowserTopBar: View {
    @ObservedObject var controller: BrowserTabController

    var body: some View {
        BrowserTopBarRow(controller: controller, state: controller.state)
    }
}

private struct BrowserTopBarRow: View {
    @ObservedObject var controller: BrowserTabController
    @ObservedObject var state: WebViewState

    var body: some View {
        HStack(spacing: 2) {
            TopBarButton(icon: .chevronLeft, label: "Back", key: "⌘[", enabled: state.canGoBack) { controller.back() }
            TopBarButton(icon: .chevronRight, label: "Forward", key: "⌘]", enabled: state.canGoForward) {
                controller.forward()
            }
            TopBarButton(icon: state.isLoading ? .close : .refresh, label: state.isLoading ? "Stop" : "Reload",
                         key: "⌘R", enabled: controller.webView != nil) { controller.reload() }
            AddressBar(controller: controller, state: state)
                .padding(.horizontal, 6)
            FloatButton(controller: controller)
            SaveAppButton(controller: controller, state: state)
            BrowserMoreMenu(controller: controller, state: state)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background(StudioColors.bar)
        .overlay(alignment: .bottom) {
            ZStack(alignment: .leading) {
                Rectangle().fill(StudioColors.line).frame(height: 1)
                LoadProgress(state: state)
            }
        }
    }
}

/// A top bar button: a 16 pt line icon in a 28 pt square; its name and key in the tooltip.
struct TopBarButton: View {
    let icon: StudioIcons.Name
    let label: String
    var key: String?
    var enabled = true
    /// Coral ink: the star of a saved app.
    var lit = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            StudioIcon(icon, size: 16)
                .foregroundStyle(!enabled ? StudioColors.muted.opacity(0.45)
                                 : lit ? StudioColors.coralInk : hovering ? StudioColors.ink : StudioColors.body)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && enabled ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(key.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// The address field: the host and a lock at rest, the whole address while editing; Return goes, Esc puts it back.
struct AddressBar: View {
    @ObservedObject var controller: BrowserTabController
    @ObservedObject var state: WebViewState
    @State private var text = ""
    @State private var editing = false
    @State private var hovering = false
    @State private var rows: [AddressSuggestion] = []
    @State private var highlighted: Int?
    @State private var popup = SuggestionPopup()
    @State private var frame: CGRect = .zero

    private var resting: String { state.url.map(BrowserURL.displayHost) ?? "" }

    var body: some View {
        HStack(spacing: 6) {
            if !editing, let url = state.url {
                if url.scheme == "https" {
                    StudioIcon(.lock, size: 12).foregroundStyle(StudioColors.muted)
                } else if url.scheme == "http", !BrowserURL.isLocal(url) {
                    Text("Not Secure")
                        .font(.studio(11, .semibold))
                        .foregroundStyle(StudioColors.amber)
                }
            }
            BrowserTextField(text: $text, focusRequest: controller.addressFocus, placeholder: "Search or enter address",
                             onFocus: focusChanged, onEdit: { _ in refresh() }, onSubmit: submit, onCancel: cancel,
                             onMove: move)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(editing ? StudioColors.card : StudioColors.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(editing ? StudioColors.coral.opacity(0.55) : hovering ? StudioColors.line3 : .clear,
                          lineWidth: 1))
        .onHover { hovering = $0 }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { frame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { frame = $0 }
        })
        .animation(.easeOut(duration: 0.16), value: editing)
        .onAppear { text = resting }
        .onChange(of: state.url) { _ in if !editing { text = resting } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Address")
    }

    private func focusChanged(_ focused: Bool) {
        editing = focused
        text = focused ? (state.url?.absoluteString ?? "") : resting
        if !focused {
            rows = []
            highlighted = nil
            popup.hide()
        }
    }

    /// The user typed: suggestions for the new text, none highlighted.
    private func refresh() {
        let others = BrowserTabController.all.filter { $0 !== controller }.compactMap { tab in
            tab.state.url.map { AddressSuggestions.OpenTab(id: tab.tabKey, title: tab.displayTitle, url: $0) }
        }
        let history = (try? BrowserData.history?.matches(text, limit: 6)) ?? []
        rows = AddressSuggestions.make(text, apps: BrowserApps.shared.store.apps, tabs: others, history: history,
                                       engine: BrowserData.searchEngine)
        highlighted = nil
        showRows()
    }

    /// ↑ and ↓ move the highlight (↑ from none goes to the last row); the field shows the highlighted address.
    private func move(_ step: Int) -> Bool {
        guard !rows.isEmpty else { return false }
        let next = highlighted.map { ($0 + step + rows.count) % rows.count } ?? (step > 0 ? 0 : rows.count - 1)
        highlighted = next
        showRows()
        return true
    }

    private func showRows() {
        guard editing, let window = controller.window else { return popup.hide() }
        popup.show(rows, highlighted: highlighted, below: frame, in: window) { choose($0) }
    }

    private func submit() {
        if let highlighted, rows.indices.contains(highlighted) { return choose(rows[highlighted]) }
        let typed = text
        controller.window?.makeFirstResponder(controller.webView)
        controller.go(typed)
    }

    /// A row: a tab comes forward, an app opens its tab, anything else loads here.
    private func choose(_ row: AddressSuggestion) {
        popup.hide()
        controller.window?.makeFirstResponder(controller.webView)
        switch row.kind {
        case .tab(let key):
            BrowserTabController.all.first { $0.tabKey == key }?.bringForward()
        case .app(let id):
            if let app = BrowserApps.shared.store.app(id: id) {
                BrowserApps.shared.open(app, from: controller.window, newTab: false)
            }
        case .address, .search, .history:
            controller.go(row.url)
        }
    }

    private func cancel() {
        if !rows.isEmpty {
            rows = []
            highlighted = nil
            return popup.hide()
        }
        text = resting
        controller.window?.makeFirstResponder(controller.webView)
    }
}

/// PiP: floats the page in a small window above every app, so a call goes on while you work; the window's own button
/// attaches it back. Shown for plain pages.
struct FloatButton: View {
    @ObservedObject var controller: BrowserTabController
    @State private var hovering = false

    var body: some View {
        if case .web = controller.content {
            let on = controller.canFloat
            Button { controller.floatPage() } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(!on ? StudioColors.muted.opacity(0.45) : hovering ? StudioColors.ink : StudioColors.body)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && on ? StudioColors.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!on)
            .help("Float this page above your other windows")
            .accessibilityLabel("Float this page")
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
    }
}

/// ☆: saves the page as an app (the tab becomes its main tab); lit when this tab is an app's or its site is saved.
struct SaveAppButton: View {
    @ObservedObject var controller: BrowserTabController
    @ObservedObject var state: WebViewState
    @ObservedObject private var apps = BrowserApps.shared

    var body: some View {
        let saved = controller.appID != nil || state.url.flatMap { apps.store.plainApp(for: $0) } != nil
        TopBarButton(icon: .star, label: saved ? "Saved as an App" : "Save as App",
                     enabled: state.url.map { BrowserURL.destination($0) == .tab } ?? false, lit: saved) {
            if !saved { apps.save(controller) }
        }
    }
}

/// ⋯: the page's other actions.
struct BrowserMoreMenu: View {
    @ObservedObject var controller: BrowserTabController
    @ObservedObject var state: WebViewState

    var body: some View {
        Menu {
            Button("Open in Default Browser") { controller.openInDefaultBrowser() }.disabled(state.url == nil)
            Button("Copy Link") { controller.copyLink() }.disabled(state.url == nil)
            Divider()
            Button("Find in Page…") {
                controller.findVisible = true
                controller.findFocus += 1
            }.disabled(controller.webView == nil)
            Divider()
            Button("Console & Network in Terminal") { controller.showLogsInTerminal() }
                .disabled(!controller.keepsLog)
            Divider()
            Button("Zoom In") { controller.zoom(1) }.disabled(controller.webView == nil)
            Button("Zoom Out") { controller.zoom(-1) }.disabled(controller.webView == nil)
            Button("Actual Size") { controller.zoom(0) }.disabled(controller.webView == nil)
        } label: {
            StudioIcon(.more, size: 16)
                .foregroundStyle(StudioColors.body)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }
}

/// The load's progress: a 2 pt coral line growing from the left, faded out when done.
private struct LoadProgress: View {
    @ObservedObject var state: WebViewState

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(StudioColors.coral)
                .frame(width: proxy.size.width, height: 2)
                .scaleEffect(x: max(0.04, state.progress), y: 1, anchor: .leading)
                .opacity(state.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.24), value: state.progress)
                .animation(.easeIn(duration: 0.16), value: state.isLoading)
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
