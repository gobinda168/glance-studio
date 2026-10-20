import Foundation

/// What the To-dos & Notes tab shows, shared by every window: the to-dos, or a note (nil: the newest one).
@MainActor
final class CapturesNavigation: ObservableObject {
    static let shared = CapturesNavigation()

    enum Page: Equatable {
        case todos
        case notes(UUID?)
    }

    @Published private(set) var page = Page.todos
    /// The to-do the page shows in its details panel; nil closes it.
    @Published private(set) var selectedTodo: UUID?

    func select(_ id: UUID?) { selectedTodo = id }
    /// The to-do group the page and side bar show (Work, Personal…); nil: All. Remembered across launches.
    @Published private(set) var todoGroup: UUID? = UserDefaults.standard.string(forKey: "glance.todos.group")
        .flatMap(UUID.init(uuidString:))

    func showGroup(_ group: UUID?) {
        todoGroup = group
        UserDefaults.standard.set(group?.uuidString, forKey: "glance.todos.group")
    }

    private init() {}

    func show(_ page: Page) { self.page = page }

    var isNotes: Bool {
        if case .notes = page { return true }
        return false
    }
}
