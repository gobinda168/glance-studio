import SwiftUI
import Combine
import GlanceCore

/// What the switch shows for one window, without holding the window's controller: the window owns the controller
/// (unowned) and the toolbar item owns this, so a strong reference back would keep a closed tab alive. It looks the
/// controller up again when the window becomes key (the controller is attached after the toolbar is made) and when the
/// feature flips.
@MainActor
final class GlanceModeSwitchModel: ObservableObject {
    /// A terminal tab with Feature.commandCenter on: the switch shows.
    @Published private(set) var available = false
    @Published private(set) var on = false
    private weak var window: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var modeToken: AnyCancellable?
    /// A terminal tab with Feature.browserColumn on: the globe shows.
    @Published private(set) var columnAvailable = false
    @Published private(set) var columnOn = false
    private var columnToken: AnyCancellable?

    /// Something to show: the switch, the globe or both.
    var showsAnything: Bool { available || columnAvailable }

    init(window: NSWindow?) {
        self.window = window
        // Not `object: window`: the publisher would hold the window strongly (window -> toolbar -> this -> window).
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .filter { [weak self] in ($0.object as AnyObject?) === self?.window }
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // `$enabled` fires before the value changes: take the new set it hands over.
        StudioFeatures.shared.$enabled
            .sink { [weak self] enabled in
                self?.refresh(commandCenter: enabled.contains(.commandCenter), browserColumn: enabled.contains(.browserColumn))
            }
            .store(in: &cancellables)
        refresh()
        // The window gets its controller after the toolbar is made: look again once it's on screen.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func refresh(commandCenter: Bool? = nil, browserColumn: Bool? = nil) {
        let commandCenter = commandCenter ?? StudioFeatures.shared.isOn(.commandCenter)
        let controller = GlanceMode.controller(window)
        let isAvailable = commandCenter && controller != nil
        if available != isAvailable { available = isAvailable }
        let isOn = controller?.glanceMode == true
        if on != isOn { on = isOn }
        // The subscription holds the published value, not the controller.
        modeToken = controller?.$glanceMode.dropFirst().sink { [weak self] in
            guard let self, self.on != $0 else { return }
            self.on = $0
        }
        let column = (browserColumn ?? StudioFeatures.shared.isOn(.browserColumn)) && controller != nil
        if columnAvailable != column { columnAvailable = column }
        let open = controller?.browserColumnOpen == true
        if columnOn != open { columnOn = open }
        columnToken = controller?.$browserColumnOpen.dropFirst().sink { [weak self] in
            guard let self, self.columnOn != $0 else { return }
            self.columnOn = $0
        }
    }
}

/// Terminal | Hyperviz in the top bar (spec §2 "Switching"): a two-segment capsule on terminal tabs only.
struct GlanceModeSwitch: View {
    weak var window: NSWindow?
    @ObservedObject var model: GlanceModeSwitchModel

    init(window: NSWindow?, model: GlanceModeSwitchModel) {
        self.window = window
        self.model = model
    }

    var body: some View {
        Group {
            if model.showsAnything {
                HStack(spacing: 6) {
                    if model.available {
                        HStack(spacing: 2) {
                            segment("Terminal", icon: AnyView(StudioIcon(.terminal, size: 11)), selected: !model.on) { set(false) }
                            segment("Hyperviz", icon: AnyView(Circle().fill(StudioColors.coral).frame(width: 7, height: 7)), selected: model.on) { set(true) }
                        }
                        .padding(2)
                        .background(Capsule().fill(StudioColors.chip))
                        .help("Terminal or Hyperviz view (⌥⌘G)")
                    }
                    if model.columnAvailable { columnButton }
                }
            } else {
                Color.clear.frame(width: 1, height: 1)   // the toolbar drops zero-size items
            }
        }
    }

    /// The browser column's globe (⌥⌘O): lit while the column shows.
    private var columnButton: some View {
        Button { BrowserColumn.toggle(window) } label: {
            StudioIcon(.globe, size: 13)
                .foregroundStyle(model.columnOn ? StudioColors.coralInk : StudioColors.muted)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(model.columnOn ? StudioColors.card : StudioColors.chip))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(model.columnOn ? "Hide the browser column (⌥⌘O)" : "Show a browser beside this tab (⌥⌘O)")
        .accessibilityLabel("Browser column")
        .accessibilityAddTraits(model.columnOn ? .isSelected : [])
    }

    /// Looked up at the click, so the view never holds the controller.
    private func set(_ on: Bool) {
        if let controller = GlanceMode.controller(window) { GlanceMode.set(on, in: controller) }
    }

    private func segment(_ title: String, icon: AnyView, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { icon; Text(title).font(.studio(11.5, selected ? .semibold : .regular)) }
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(selected ? StudioColors.card : .clear).shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 1))
                .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
