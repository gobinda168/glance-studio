import AppKit
import SwiftUI

extension View {
    /// Keeps `shown` on `live` while `window` is the front tab of its group, and catches it up when the window comes
    /// to the front. Every tab is its own window with its own strip and side bar: without this, a strip click or a tab
    /// switch redrew and animated the chrome of every hidden tab too, on the main thread, before the next tab showed.
    func followingFront<Value: Equatable>(
        _ live: @autoclosure @escaping () -> Value, into shown: Binding<Value>, window: NSWindow?,
        animation: Animation? = nil
    ) -> some View {
        onChange(of: live()) { _, new in
            guard TabSidebarModel.isFront(window), shown.wrappedValue != new else { return }
            withAnimation(animation) { shown.wrappedValue = new }
        }
        // Posted while the window is brought forward, before it draws: it shows the current value, not a slide to it.
        // `live` is read now, not as the last redraw saw it: the side bar mode follows the tab just before the post.
        .onReceive(NotificationCenter.default.publisher(for: TabSidebarModel.cameToFrontNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            let current = live()
            if shown.wrappedValue != current { shown.wrappedValue = current }
        }
    }
}
