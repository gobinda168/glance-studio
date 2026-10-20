import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // GLANCE: the tab's group in the Terminal side bar (spec 2026-10-11-tab-groups-design.md). Optional with a
        // default, so states saved before it decode as ungrouped and the version stays 7.
        var glanceGroup: UUID? = nil

        // GLANCE: the split panes' tab names and order, minimized panes and tabs view (PaneLayoutModel). Optional with
        // a default for the same reason as the group.
        var glancePanes: PaneLayoutModel.Saved? = nil
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            // GLANCE: encoding runs on the main thread; TabGroups is main-actor.
            glanceGroup: MainActor.assumeIsolated { controller.window.flatMap { TabGroups.shared.group(of: $0) } },
            glancePanes: MainActor.assumeIsolated { PaneLayoutModel.saved(panes: controller.surfaceTree.map(\.id)) },
        )
    }
}
