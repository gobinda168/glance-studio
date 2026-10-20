import Combine
import Foundation
import GlanceKit

/// Whether Claude is working on something Glance started, for the dot on the strip's Agents icon: the editor chat's
/// headless session now, the PR manager's fixes later. Each job reports under its own key ("chat:<root>").
@MainActor
final class AgentsActivity: ObservableObject {
    static let shared = AgentsActivity()

    @Published private(set) var isRunning = false
    private var running: Set<String> = []

    private var watch: AnyCancellable?

    /// An agent's run going (or waiting on you) lights the dot too, under the key "agents".
    private init() {
        watch = AutomationEngine.shared.$live.sink { [weak self] live in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let engine = AutomationEngine.shared
                    let on = live.contains { engine.entry($0.ref.automation)?.manifest?.isAgent == true }
                    self?.set("agents", running: on)
                }
            }
        }
    }

    func set(_ key: String, running isOn: Bool) {
        if isOn { running.insert(key) } else { running.remove(key) }
        if isRunning != !running.isEmpty { isRunning = !running.isEmpty }
    }
}
