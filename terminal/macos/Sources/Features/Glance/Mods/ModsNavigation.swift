import Foundation

/// Which mod the Mods tab shows, shared by every window.
@MainActor
final class ModsNavigation: ObservableObject {
    static let shared = ModsNavigation()

    /// The mod's name; nil shows the library.
    @Published private(set) var selected: String?

    private init() {}

    func show(_ name: String?) { selected = name }
}
