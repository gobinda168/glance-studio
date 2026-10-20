import GlanceCore
import SwiftUI

/// The side bar beside the activity strip at its own width (`TabSidebarModel.width`): a fixed column rather than a
/// split-view pane, so resizing the window only resizes what's beside it. Dragging its right edge sets the width for
/// every window, between 260 and 400 pt.
struct SidebarColumn: View {
    @ObservedObject private var model = TabSidebarModel.shared
    /// The width when the drag began.
    @State private var dragStart: CGFloat?

    var body: some View {
        StudioSidebarView()
            .frame(width: model.width)
            .overlay(alignment: .trailing) { handle }
    }

    /// The column's last few points, over its hairline: the column-resize pointer, and a drag that sets the width.
    private var handle: some View {
        Color.clear
            .frame(width: 5)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? model.width
                        dragStart = start
                        model.width = CGFloat(TabSidebarLayout.clamp(Double(start + value.translation.width)))
                    }
                    .onEnded { _ in dragStart = nil })
            .accessibilityHidden(true)
    }
}
