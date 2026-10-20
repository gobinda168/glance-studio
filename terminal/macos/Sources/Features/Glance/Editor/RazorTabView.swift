import GlanceKit
import SwiftUI
import WebKit

/// A Razor Code tab: the Monaco page on the left, the Glance pane on the right.
struct RazorTabView: View {
    @ObservedObject var controller: RazorWindowController
    @ObservedObject private var tabSidebar = TabSidebarModel.shared

    var body: some View {
        HStack(spacing: 0) {
            if tabSidebar.isOpen {
                SidebarColumn()
            }
            HSplitView {
                EditorWebHost(view: controller.web.view)
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
