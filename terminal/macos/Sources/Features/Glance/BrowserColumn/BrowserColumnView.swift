import AppKit
import GlanceCore
import SwiftUI

/// The browser column (spec 2026-11-24-browser-column-design.md §1): a slim bar (back, forward, reload, the address
/// field, the menu), a tab strip with +, and the selected tab's page or New Tab. Layout and values from the signed-off
/// replica (design-system/glance/prototype/browsercol.{js,css}).
struct BrowserColumnView: View {
    @ObservedObject var model: BrowserColumnModel

    var body: some View {
        VStack(spacing: 0) {
            ColumnBar(model: model, tab: model.selected)
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            ColumnTabStrip(model: model)
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            ColumnContent(model: model, tab: model.selected)
        }
        .background(StudioColors.bar)
        .onAppear { model.shown() }
        .onDisappear { model.hidden() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Browser column")
    }
}

private struct ColumnBar: View {
    @ObservedObject var model: BrowserColumnModel
    @ObservedObject var tab: ColumnTab

    var body: some View { Row(model: model, tab: tab, state: tab.state) }

    private struct Row: View {
        @ObservedObject var model: BrowserColumnModel
        let tab: ColumnTab
        @ObservedObject var state: WebViewState

        var body: some View {
            HStack(spacing: 2) {
                TopBarButton(icon: .chevronLeft, label: "Back", enabled: state.canGoBack) { model.webView?.goBack() }
                TopBarButton(icon: .chevronRight, label: "Forward", enabled: state.canGoForward) { model.webView?.goForward() }
                TopBarButton(icon: state.isLoading ? .close : .refresh, label: state.isLoading ? "Stop" : "Reload",
                             enabled: tab.page != nil) {
                    if state.isLoading { model.webView?.stopLoading() } else { model.webView?.reload() }
                }
                AddressBar(controller: model, state: state).padding(.horizontal, 4)
                Menu {
                    Button("Open in Browser Tab") {
                        if let url = tab.url { _ = BrowserTabController.open(url: url, from: model.window) }
                    }.disabled(tab.url == nil)
                    Button("Copy Link") {
                        guard let url = tab.url else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }.disabled(tab.url == nil)
                    Divider()
                    Button("Close Column") {
                        if let c = BrowserColumn.controller(model.window) { BrowserColumn.set(false, in: c) }
                    }
                } label: { StudioIcon(.more, size: 14).foregroundStyle(StudioColors.muted).frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("More")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }
}

private struct ColumnTabStrip: View {
    @ObservedObject var model: BrowserColumnModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    ColumnTabChip(tab: tab, state: tab.state, selected: tab.id == model.selectedID,
                                  closable: model.tabs.count > 1,
                                  select: { model.select(tab.id) }, close: { model.close(tab.id) })
                }
                TopBarButton(icon: .plus, label: "New Tab") { model.newTab() }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
    }
}

private struct ColumnTabChip: View {
    let tab: ColumnTab
    @ObservedObject var state: WebViewState
    let selected: Bool
    let closable: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            StudioIcon(.globe, size: 12).foregroundStyle(StudioColors.muted)
            Text(tab.title).lineLimit(1).truncationMode(.tail)
                .font(.studio(11.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
            if closable && (hovering || selected) {
                Button(action: close) { StudioIcon(.close, size: 10).frame(width: 16, height: 16) }
                    .buttonStyle(.plain).foregroundStyle(StudioColors.muted)
                    .accessibilityLabel("Close \(tab.title)")
            }
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 24).frame(maxWidth: 168)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? StudioColors.card : hovering ? StudioColors.hover : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(selected ? StudioColors.line : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct ColumnContent: View {
    @ObservedObject var model: BrowserColumnModel
    @ObservedObject var tab: ColumnTab

    var body: some View {
        if let page = tab.page {
            ColumnPage(page: page)
        } else {
            ColumnStart(model: model)
        }
    }
}

private struct ColumnPage: View {
    @ObservedObject var page: WebPage

    var body: some View {
        WebViewHost(view: page.webView)
            .overlay {
                if let error = page.loadError {
                    LoadErrorView(error: error, retry: { page.restart() },
                                  back: page.webView.canGoBack ? { [weak page] in _ = page?.webView.goBack() } : nil,
                                  continueAnyway: error.certificate && BrowserURL.isLocal(error.url)
                                      ? { [weak page] in page?.continueAnyway() } : nil)
                } else if page.stopped {
                    ColumnStopped(restart: page.restart)
                }
            }
            .overlay(alignment: .bottom) { DownloadErrorLine(message: $page.downloadError) }
    }
}

/// "This page stopped." with Reload (the Browser tab's StoppedView is private to its file).
private struct ColumnStopped: View {
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("This page stopped.").font(.studio(13, .semibold)).foregroundStyle(StudioColors.ink)
            StudioButton(title: "Reload", style: .primary, action: restart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioColors.background)
    }
}

/// New Tab in the column: the pages visited last (stage 2 adds the import offer above them).
private struct ColumnStart: View {
    @ObservedObject var model: BrowserColumnModel
    @State private var recent: [GlanceCore.HistoryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recent").font(.studio(11, .semibold)).foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 6)
                ForEach(recent, id: \.url) { entry in
                    Button { model.go(entry.url) } label: {
                        HStack(spacing: 10) {
                            StudioIcon(.globe, size: 14).foregroundStyle(StudioColors.muted)
                            Text(entry.title.isEmpty ? BrowserURL.displayHost(entry.url) : entry.title).font(.studio(13))
                                .foregroundStyle(StudioColors.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(BrowserURL.displayHost(entry.url)).font(.studioMono(11.5)).foregroundStyle(StudioColors.muted)
                        }
                        .padding(.horizontal, 8).frame(height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520).padding(.horizontal, 20).frame(maxWidth: .infinity)
        }
        .task { recent = await BrowserData.recent(limit: 6) }
    }
}

extension View {
    /// The column's width from the model, with a grip on its left edge to drag it (double-click resets to 42%). In
    /// overlay mode it also casts a shadow over the terminal.
    func browserColumnWidth(model: BrowserColumnModel, space: CGFloat, overlay: Bool) -> some View {
        modifier(ColumnWidth(model: model, space: space, overlay: overlay))
    }
}

private struct ColumnWidth: ViewModifier {
    @ObservedObject var model: BrowserColumnModel
    let space: CGFloat
    let overlay: Bool
    @State private var start: Double?
    @State private var hovering = false

    func body(content: Content) -> some View {
        let width = BrowserColumnLayout.width(saved: model.savedWidth, space: Double(space))
        content
            .frame(width: CGFloat(width))
            .overlay(alignment: .leading) { Rectangle().fill(overlay ? StudioColors.line3 : StudioColors.line).frame(width: 1) }
            .overlay(alignment: .leading) { grip(width) }
            .shadow(color: .black.opacity(overlay ? 0.22 : 0), radius: overlay ? 18 : 0, x: -4)
    }

    private func grip(_ width: Double) -> some View {
        Rectangle()
            .fill(hovering || start != nil ? StudioColors.coral : .clear)
            .frame(width: 2).frame(width: 9).contentShape(Rectangle()).offset(x: -4)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? width
                    start = from
                    model.savedWidth = BrowserColumnLayout.width(saved: from - Double(drag.translation.width), space: Double(space))
                }
                .onEnded { _ in start = nil; model.window?.invalidateRestorableState() })
            .onTapGesture(count: 2) { model.savedWidth = nil; model.window?.invalidateRestorableState() }
            .accessibilityLabel("Resize the browser column")
    }
}
