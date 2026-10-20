import AppKit
import GlanceCore
import SwiftUI
import WebKit

/// A Browser tab: the side bar column, the top bar over the page, and the Glance pane.
struct BrowserTabView: View {
    @ObservedObject var controller: BrowserTabController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                VStack(spacing: 0) {
                    BrowserTopBar(controller: controller)
                    BrowserContentView(controller: controller)
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
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

/// The page under the top bar.
private struct BrowserContentView: View {
    @ObservedObject var controller: BrowserTabController

    var body: some View {
        switch controller.content {
        case .start:
            BrowserStartView(controller: controller)
        case .web(let page):
            WebPageView(page: page, controller: controller)
        case .slack(let session):
            SlackSessionView(session: session)
        case .atlassian(let page):
            AtlassianPageView(page: page)
        }
    }
}

/// A plain page, with its error page, "This page stopped." and a download's failure over it.
private struct WebPageView: View {
    @ObservedObject var page: WebPage
    @ObservedObject var controller: BrowserTabController

    var body: some View {
        Group {
            if controller.floatingCall != nil {
                FloatingPlaceholder(bringBack: controller.attachPage)
            } else {
                WebViewHost(view: page.webView)
            }
        }
            .overlay {
                if let error = page.loadError {
                    LoadErrorView(error: error, retry: { page.restart() }, back: back,
                                  continueAnyway: continueAnyway(error))
                } else if page.stopped {
                    StoppedView(name: "This page", restart: page.restart)
                }
            }
            .overlay(alignment: .bottom) { DownloadErrorLine(message: $page.downloadError) }
            .overlay(alignment: .topTrailing) {
                if controller.findVisible { BrowserFindBar(controller: controller) }
            }
    }

    /// Go Back, when there's a page to go back to.
    private var back: (() -> Void)? {
        guard page.webView.canGoBack else { return nil }
        let webView = page.webView
        return { _ = webView.goBack() }
    }

    /// Continue Anyway: only for this Mac's own servers with a certificate it doesn't trust.
    private func continueAnyway(_ error: WebPage.LoadError) -> (() -> Void)? {
        guard error.certificate, BrowserURL.isLocal(error.url) else { return nil }
        let page = page
        return { page.continueAnyway() }
    }
}

/// What a tab shows while its page floats in the PiP window.
private struct FloatingPlaceholder: View {
    let bringBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pip")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(StudioColors.muted)
            Text("This page is floating")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text("It stays above your other windows, so you can work while it plays.")
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
            StudioButton(title: "Bring It Back", style: .primary, action: bringBack)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioColors.background)
    }
}

/// A Slack workspace's web client.
struct SlackSessionView: View {
    @ObservedObject var session: SlackSession

    var body: some View {
        WebViewHost(view: session.webView)
            .overlay { if session.stopped { StoppedView(name: "Slack", restart: session.restart) } }
            .overlay(alignment: .bottom) { DownloadErrorLine(message: $session.downloadError) }
    }
}

/// A Jira or Confluence page.
struct AtlassianPageView: View {
    @ObservedObject var page: AtlassianPage

    var body: some View {
        WebViewHost(view: page.webView)
            .overlay { if page.stopped { StoppedView(name: page.product.title, restart: page.restart) } }
            .overlay(alignment: .bottom) { DownloadErrorLine(message: $page.downloadError) }
    }
}

/// "<Name> stopped." with Reload, after its process died twice in a minute.
private struct StoppedView: View {
    let name: String
    let restart: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text("\(name) stopped.")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            StudioButton(title: "Reload", style: .primary, action: restart)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioColors.background)
    }
}

/// A download's failure along the bottom, gone after 6 s.
private struct DownloadErrorLine: View {
    @Binding var message: String?

    var body: some View {
        if let current = message {
            InlineError(message: current)
                .padding(12)
                .task(id: current) {
                    try? await Task.sleep(for: .seconds(6))
                    if message == current { message = nil }
                }
        }
    }
}

/// A load that failed, in Studio's words instead of WebKit's blank page.
private struct LoadErrorView: View {
    let error: WebPage.LoadError
    let retry: () -> Void
    let back: (() -> Void)?
    let continueAnyway: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            StudioIcon(error.certificate ? .lock : .globe, size: 26)
                .foregroundStyle(StudioColors.muted)
                .padding(.bottom, 6)
            Text(error.certificate ? "This connection isn't private." : "Can't open this page.")
                .font(.studio(19, .bold))
                .foregroundStyle(StudioColors.ink)
            Text(BrowserURL.displayHost(error.url))
                .font(.studioMono(12))
                .foregroundStyle(StudioColors.muted)
            Text(error.message)
                .font(.studio(13))
                .foregroundStyle(StudioColors.body)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) {
                if let back { StudioButton(title: "Go Back", action: back) }
                StudioButton(title: "Try Again", style: .primary, action: retry)
                if let continueAnyway { StudioButton(title: "Continue Anyway", style: .quiet, action: continueAnyway) }
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioColors.background)
    }
}

/// New Tab: no web view, the caret in the address field, and the pages visited last.
struct BrowserStartView: View {
    @ObservedObject var controller: BrowserTabController
    @State private var recent: [GlanceCore.HistoryEntry] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Tab")
                        .font(.studio(28, .bold))
                        .tracking(-0.28)
                        .foregroundStyle(StudioColors.ink)
                    Text("Type an address, or words to search with \(BrowserData.searchEngine.title).")
                        .font(.studio(13))
                        .foregroundStyle(StudioColors.muted)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Apps")
                    AppsGrid(window: controller.window, tileMinimum: 84, lightsFrontApp: false)
                }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Caption("Recent").padding(.bottom, 4)
                        ForEach(recent, id: \.url) { entry in
                            RecentRow(entry: entry) { controller.go(entry.url) }
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
        .background(StudioColors.background)
        .task { recent = await BrowserData.recent(limit: 8) }
    }
}

private struct RecentRow: View {
    let entry: GlanceCore.HistoryEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SiteIcon(url: entry.url, size: 18)
                Text(entry.title.isEmpty ? BrowserURL.displayHost(entry.url) : entry.title)
                    .font(.studio(13, .medium))
                    .foregroundStyle(hovering ? StudioColors.ink : StudioColors.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(BrowserURL.displayHost(entry.url))
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// ⌘F: find in the page, top right over it; Return next, ⇧Return previous, Esc closes.
struct BrowserFindBar: View {
    @ObservedObject var controller: BrowserTabController
    @State private var text = ""
    @State private var found: Bool?

    var body: some View {
        HStack(spacing: 4) {
            StudioIcon(.search, size: 13).foregroundStyle(StudioColors.muted).padding(.leading, 4)
            BrowserTextField(text: $text, focusRequest: controller.findFocus, placeholder: "Find in page",
                             onEdit: { _ in find(backwards: false) },
                             onSubmit: { find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) },
                             onCancel: close)
                .frame(width: 180)
            if found == false {
                Text("No matches").font(.studio(11)).foregroundStyle(StudioColors.muted)
            }
            TopBarButton(icon: .chevronUp, label: "Previous", key: "⇧↩", enabled: !text.isEmpty) { find(backwards: true) }
            TopBarButton(icon: .chevronDown, label: "Next", key: "↩", enabled: !text.isEmpty) { find(backwards: false) }
            TopBarButton(icon: .close, label: "Close", key: "Esc") { close() }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioColors.solid))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .padding(12)
        .transition(.opacity)
    }

    private func find(backwards: Bool) {
        guard let webView = controller.webView, !text.isEmpty else { found = nil; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(text, configuration: configuration) { result in found = result.matchFound }
    }

    private func close() {
        controller.findVisible = false
        text = ""
        found = nil
        controller.window?.makeFirstResponder(controller.webView)
    }
}
