import AppKit
import GlanceCore
import SwiftUI

/// Add a site… (spec 2026-10-09-jira-confluence-design.md, "Sites"): a card over the window asking for a Jira or
/// Confluence address.
/// - Glance works out Cloud or Data Center, and which product answered.
/// - On Data Center it offers the other product's address, which is optional.
/// - Adding opens the site's tab, where its own sign-in runs.
/// - With `extending`, it adds the missing product's address to a saved Data Center site instead.
/// Esc or a click elsewhere closes it.
@MainActor
final class AddSitePalette: NSObject, NSWindowDelegate {
    private static var current: AddSitePalette?

    private let panel: AddSitePanel
    private weak var parent: NSWindow?
    private let model: AddSiteModel

    static let size = NSSize(width: 460, height: 330)

    static func show(over parent: NSWindow?, extending site: AtlassianSite? = nil) {
        current?.close()
        let palette = AddSitePalette(parent: parent, extending: site)
        current = palette
        palette.present()
    }

    private init(parent: NSWindow?, extending site: AtlassianSite?) {
        self.parent = parent
        panel = AddSitePanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        model = AddSiteModel(extending: site)
        super.init()
        model.palette = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the card draws its own
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: AddSiteCard(model: model))
    }

    private func present() {
        let area = parent?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        // A little above the middle, where a palette sits.
        let origin = NSPoint(x: area.midX - Self.size.width / 2,
                             y: area.midY - Self.size.height / 2 + area.height * 0.08)
        panel.setFrameOrigin(origin)
        if let parent { parent.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    /// The site is saved: the palette closes and the site's tab opens (Jira's when it has Jira), where its sign-in
    /// runs.
    func open(_ site: AtlassianSite, product: AtlassianProduct? = nil) {
        let parent = self.parent
        close()
        BrowserTabController.openAtlassian(site: site, product: product ?? (site.has(.jira) ? .jira : .confluence),
                                           from: parent)
    }
}

/// A borderless panel that takes the keyboard (the address fields).
private final class AddSitePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The palette's steps: the address, then what answered there; on Data Center, the other product's address.
@MainActor
final class AddSiteModel: ObservableObject {
    enum Step: Equatable {
        case address
        /// Nothing said which product it is, perhaps behind a company sign-in: the user says.
        case askProduct(URL)
        case found(AtlassianSite)
    }

    @Published var address = ""
    @Published var other = ""
    @Published private(set) var step: Step = .address
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    let extending: AtlassianSite?
    weak var palette: AddSitePalette?

    init(extending: AtlassianSite?) {
        self.extending = extending
    }

    /// The product a Data Center site lacks, which the second address (or the extending one) must be.
    func missing(_ site: AtlassianSite) -> AtlassianProduct? {
        guard site.flavor == .dataCenter else { return nil }
        return AtlassianProduct.allCases.first { !site.has($0) }
    }

    /// The address changed after an answer: back to the first step.
    func addressEdited() {
        if step != .address { step = .address }
        error = nil
    }

    /// Continue: what answers at the typed address.
    func check() {
        guard !busy else { return }
        guard let base = AtlassianAddress.base(address) else {
            error = "That doesn't look like a Jira or Confluence address."
            return
        }
        error = nil
        busy = true
        Task {
            let result = await AtlassianAPI.identify(base, send: AtlassianSessions.shared.send)
            busy = false
            switch result {
            case .site(let site):
                if let extending { extend(extending, with: site) } else { step = .found(site) }
            case .notAtlassian:
                step = .askProduct(base)
            case .unreachable:
                error = "Couldn't reach \(base.host ?? base.absoluteString). Check the address, or your VPN."
            }
        }
    }

    /// The user says which product an address is whose manifest didn't answer.
    func choose(_ product: AtlassianProduct, at base: URL) {
        let site = AtlassianAPI.site(base, product: product)
        if let extending { extend(extending, with: site) } else { step = .found(site) }
    }

    /// Add and Sign In. On Data Center, a second address is checked first and must be the missing product.
    func add(_ site: AtlassianSite) {
        guard !busy else { return }
        let typed = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let missing = missing(site), !typed.isEmpty else { return finish(site) }
        guard let base = AtlassianAddress.base(typed) else {
            error = "That doesn't look like a \(missing.title) address."
            return
        }
        busy = true
        error = nil
        Task {
            let result = await AtlassianAPI.identify(base, send: AtlassianSessions.shared.send)
            busy = false
            guard case .site(let found) = result, found.flavor == .dataCenter, let url = found.url(missing) else {
                error = "\(base.host ?? typed) didn't answer as \(missing.title). Leave it empty to add it later."
                return
            }
            var merged = site
            merged.set(missing, url)
            merged.titles += found.titles.filter { !merged.titles.contains($0) }
            finish(merged)
        }
    }

    func close() { palette?.close() }

    private func extend(_ site: AtlassianSite, with found: AtlassianSite) {
        guard let missing = missing(site), found.flavor == .dataCenter, let url = found.url(missing) else {
            step = .address
            error = "That isn't a \(missing(site)?.title ?? "Jira or Confluence") address."
            return
        }
        AtlassianSessions.shared.setAddress(site.id, missing, url, titles: found.titles)
        palette?.open(AtlassianSessions.shared.store.site(id: site.id) ?? site, product: missing)
    }

    private func finish(_ site: AtlassianSite) {
        palette?.open(AtlassianSessions.shared.add(site))
    }
}

/// The card: a title, the address field, what answered, the error, Cancel and the primary button.
private struct AddSiteCard: View {
    @ObservedObject var model: AddSiteModel
    @FocusState private var focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.studio(15, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text("Your Jira or Confluence address, as it shows in your browser.")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.muted)
            }
            AddressField(placeholder: "acme.atlassian.net or jira.acme.com", text: $model.address)
                .focused($focused)
                .onSubmit(primary)
                .onChange(of: model.address) { _, _ in model.addressEdited() }
            stepBody
            if let error = model.error {
                InlineError(message: error)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                StudioButton(title: "Cancel", style: .quiet) { model.close() }
                StudioButton(title: primaryTitle, style: .primary, busy: model.busy, enabled: primaryEnabled,
                             action: primary)
            }
        }
        .padding(20)
        .frame(width: AddSitePalette.size.width - 32, height: AddSitePalette.size.height - 32, alignment: .topLeading)
        .background(shape.fill(StudioColors.card.opacity(0.86)))
        .glassSurface(shape, solid: StudioColors.card)
        .overlay(shape.strokeBorder(StudioColors.line3, lineWidth: 1))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .frame(width: AddSitePalette.size.width, height: AddSitePalette.size.height)
        .onAppear { focused = true }
        .onExitCommand { model.close() }
    }

    private var title: String {
        guard let site = model.extending else { return "Add a site" }
        return "Add \(model.missing(site)?.title ?? "an address") to \(site.name)"
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .address:
            EmptyView()
        case .askProduct(let base):
            VStack(alignment: .leading, spacing: 8) {
                Text("No Jira or Confluence answered at \(base.host ?? base.absoluteString). If it's behind your "
                     + "company's sign-in, say which it is:")
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    StudioButton(title: "It's Jira") { model.choose(.jira, at: base) }
                    StudioButton(title: "It's Confluence") { model.choose(.confluence, at: base) }
                }
            }
        case .found(let site):
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(site))
                    .font(.studio(12.5, .medium))
                    .foregroundStyle(StudioColors.ink)
                if let missing = model.missing(site) {
                    AddressField(placeholder: "\(missing.title) address (optional)", text: $model.other)
                        .onSubmit(primary)
                }
            }
        }
    }

    private func summary(_ site: AtlassianSite) -> String {
        if site.flavor == .cloud { return "Cloud · \(site.displayAddress) · Jira and Confluence" }
        let products = AtlassianProduct.allCases.filter(site.has).map(\.title).joined(separator: " and ")
        return "Data Center · \(site.name) · \(products)"
    }

    private var primaryTitle: String {
        if case .found = model.step { return "Add and Sign In" }
        return "Continue"
    }

    private var primaryEnabled: Bool {
        if case .askProduct = model.step { return false }
        return !model.address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func primary() {
        if case .found(let site) = model.step { model.add(site) } else { model.check() }
    }
}

/// A text field on the card's `field` fill, as the palette's filter field.
private struct AddressField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.studio(13))
            .foregroundStyle(StudioColors.ink)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(StudioColors.field))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }
}
