import SwiftUI
import WebKit

/// A GS Code tab: the tab sidebar, VS Code (or how far the editor server has got), and the Glance pane.
struct StudioTabView: View {
    @ObservedObject var controller: StudioWindowController
    @ObservedObject private var server = EditorServerManager.shared
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    private var isRunning: Bool {
        if case .running = server.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                ZStack(alignment: .top) {
                    EditorWebHost(view: controller.webView)
                        .opacity(isRunning ? 1 : 0)
                    if !isRunning {
                        EditorServerStatusView(state: server.state, downloadSize: server.downloadSize) { server.restart() }
                    }
                    if isRunning && server.portMoved {
                        PortMovedBanner { server.acknowledgePortMoved() }
                    }
                }
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
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

private struct EditorWebHost: NSViewRepresentable {
    let view: WKWebView
    func makeNSView(context: Context) -> WKWebView { view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Download, install, start, or what went wrong, with Retry.
private struct EditorServerStatusView: View {
    let state: EditorServerManager.State
    let downloadSize: Int64
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 260)
                Text("Downloading GS Code (\(Int(fraction * 100))% of \(downloadSize / 1_000_000) MB)…")
                Text("Only the first time.").font(.caption).foregroundStyle(.secondary)
            case .installing:
                ProgressView()
                Text("Installing GS Code…")
            case .idle, .starting:
                ProgressView()
                Text("Starting GS Code…")
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle").font(.system(size: 28)).foregroundStyle(.orange)
                Text(reason).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Retry", action: retry).keyboardShortcut(.defaultAction)
            case .running:
                EmptyView()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PortMovedBanner: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
            Text("GS Code had to move to another port, so its settings and open files start fresh.")
            Button("OK", action: dismiss)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 10)
    }
}
