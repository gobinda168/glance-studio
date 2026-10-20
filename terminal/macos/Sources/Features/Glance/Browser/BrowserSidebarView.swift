import AppKit
import GlanceCore
import SwiftUI

/// The Browser side bar (spec 2026-10-10-browser-design.md, "Surface"): the apps as tiles with "+", then the open
/// tabs that aren't an app's.
struct BrowserSidebarView: View {
    @ObservedObject private var apps = BrowserApps.shared
    @ObservedObject private var tabs = BrowserTabChanges.shared
    @ObservedObject private var rowsChange = TabSidebarModel.shared.rowsChange // the selected tab changes
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Browser") {
                SidebarIconButton(icon: .plus, label: "New Tab (⌘T)") {
                    BrowserTabController.open(url: nil, from: window)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Caption("Apps").padding(.horizontal, 6)
                        AppsGrid(window: window)
                    }
                    let open = BrowserTabController.all.filter { $0.appID == nil }
                    if !open.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Caption("Tabs").padding(.horizontal, 6).padding(.bottom, 4)
                            let front = BrowserTabController.front(in: window)
                            ForEach(open, id: \.tabKey) { tab in
                                BrowserTabRow(tab: tab, isSelected: tab === front)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 12)
            }
            Spacer(minLength: 0)
        }
        .background(WindowAccessor { window = $0 })
    }
}

/// The apps' tiles, "+" last; with no apps yet, three suggestions. Used by the side bar and the start page.
struct AppsGrid: View {
    let window: NSWindow?
    var tileMinimum: CGFloat = 66
    /// Lights the front tab's app. The start page turns it off: it is never an app's tab, and asking for its window's
    /// tab group while AppKit is still adding the window to it lays the window out inside this update, a SwiftUI
    /// cycle that left the new tab stuck at its first size.
    var lightsFrontApp = true
    @ObservedObject private var apps = BrowserApps.shared
    @ObservedObject private var tabs = BrowserTabChanges.shared
    @State private var adding = false
    @State private var removing: SavedApp?
    @State private var renaming: SavedApp?
    @State private var newName = ""

    var body: some View {
        let selected = lightsFrontApp ? BrowserTabController.front(in: window)?.appID : nil
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum, maximum: tileMinimum + 30), spacing: 4)],
                  spacing: 4) {
            ForEach(apps.store.apps) { app in
                AppTile(app: app, badge: apps.badge(app), isSelected: app.id == selected) {
                    apps.open(app, from: window, newTab: NSEvent.modifierFlags.contains(.command))
                }
                .contextMenu { menu(app) }
            }
            if apps.store.apps.isEmpty {
                SuggestedTile(name: "Slack", url: URL(string: "https://app.slack.com")!) {
                    BrowserTabController.openSlackSignIn(from: window)
                }
                SuggestedTile(name: "Meet", url: URL(string: "https://meet.google.com")!) {
                    let app = apps.add(name: "Meet", url: URL(string: "https://meet.google.com")!)
                    apps.open(app, from: window, newTab: false)
                }
                SuggestedTile(name: "Gmail", url: URL(string: "https://mail.google.com")!) {
                    let app = apps.add(name: "Gmail", url: URL(string: "https://mail.google.com")!)
                    apps.open(app, from: window, newTab: false)
                }
            }
            AddTile { adding = true }
                .popover(isPresented: $adding, arrowEdge: .trailing) {
                    AddAppCard(window: window) { adding = false }
                }
        }
        .alert("Remove \(removing?.name ?? "") from Glance?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { apps.remove(removing) }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: {
            Text(removeMessage)
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { apps.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    @ViewBuilder
    private func menu(_ app: SavedApp) -> some View {
        if case .slack = app.addOn {
            Button("Reload") { if case .slack(let team) = app.addOn { SlackSessions.shared.reload(teamID: team) } }
        } else {
            Button("Open in New Tab") { apps.open(app, from: window, newTab: true) }
        }
        if case .atlassian = app.addOn {} else {
            Button("Rename…") {
                newName = app.name
                renaming = app
            }
        }
        Divider()
        Button("Remove from Glance…") { removing = app }
    }

    private var removeMessage: String {
        switch removing?.addOn {
        case .slack?: "Its tab closes. You stay signed in to Slack in your browser."
        case .atlassian?: "Removes this site's Jira and Confluence from Glance. You stay signed in to Atlassian in your browser."
        default: "Its tab stays open as an ordinary tab."
        }
    }
}

/// An app: its icon (with its count, unread dot or dimmed when signed out) and its name.
private struct AppTile: View {
    let app: SavedApp
    let badge: BrowserApps.Badge
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                SiteIcon(url: app.url, initial: app.initial, size: 30)
                    .opacity(badge.signedOut ? 0.45 : 1)
                    .overlay(alignment: .topTrailing) { TileBadge(badge: badge).offset(x: 8, y: -6) }
                Text(app.name)
                    .font(.studio(11, .medium))
                    .foregroundStyle(isSelected || hovering ? StudioColors.ink : StudioColors.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(shape.fill(isSelected ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
            .overlay(shape.strokeBorder(isSelected ? StudioColors.coral.opacity(0.45) : .clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(badge.signedOut ? "\(app.name) · Signed out" : "\(app.name) · \(BrowserURL.displayHost(app.url))")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilityText: String {
        if badge.signedOut { return "\(app.name), signed out" }
        if badge.count > 0 { return "\(app.name), \(badge.count) new" }
        if badge.unread { return "\(app.name), unread" }
        return app.name
    }
}

/// A tile's coral count, or its muted unread dot.
private struct TileBadge: View {
    let badge: BrowserApps.Badge

    var body: some View {
        if badge.count > 0 {
            Text(badge.count > 99 ? "99+" : "\(badge.count)")
                .font(.studio(9.5, .bold))
                .foregroundStyle(StudioColors.onCoral)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(Capsule().fill(StudioColors.coral))
                .overlay(Capsule().strokeBorder(StudioColors.bar, lineWidth: 1.5))
        } else if badge.unread {
            Circle().fill(StudioColors.muted).frame(width: 7, height: 7)
                .overlay(Circle().strokeBorder(StudioColors.bar, lineWidth: 1.5))
        }
    }
}

/// A suggestion before any app is saved: the site's icon under a dashed outline.
private struct SuggestedTile: View {
    let name: String
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                SiteIcon(url: url, initial: String(name.prefix(1)), size: 30).opacity(hovering ? 1 : 0.7)
                Text(name)
                    .font(.studio(11, .medium))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .overlay(shape.strokeBorder(StudioColors.line3, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Add \(name)")
        .onHover { hovering = $0 }
        .accessibilityLabel("Add \(name)")
    }
}

/// "+": the add card.
private struct AddTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(spacing: 6) {
                StudioIcon(.plus, size: 16)
                    .foregroundStyle(hovering ? StudioColors.ink : StudioColors.muted)
                    .frame(width: 30, height: 30)
                Text("Add")
                    .font(.studio(11, .medium))
                    .foregroundStyle(StudioColors.muted)
            }
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(shape.fill(hovering ? StudioColors.hover : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help("Add an app")
        .onHover { hovering = $0 }
        .accessibilityLabel("Add an app")
    }
}

/// "Add an app": the tab in front, any address, or a Slack workspace or Atlassian site with their extras.
struct AddAppCard: View {
    let window: NSWindow?
    let done: () -> Void
    @State private var address = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an app")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            if let tab = BrowserTabController.front(in: window), tab.appID == nil, let url = tab.state.url,
               BrowserURL.destination(url) == .tab {
                StudioButton(title: "Save \u{201C}\(tab.displayTitle)\u{201D}", icon: .star) {
                    BrowserApps.shared.save(tab)
                    done()
                }
            }
            VStack(spacing: 6) {
                StudioField(placeholder: "Address, like mail.google.com", text: $address, submit: add)
                StudioField(placeholder: "Name (optional)", text: $name, submit: add)
            }
            StudioButton(title: "Add", style: .primary, enabled: BrowserURL.isAddress(address), action: add)
            Rectangle().fill(StudioColors.line2).frame(height: 1)
            Caption("With extras")
            ExtraRow(icon: .chats, title: "Slack workspace", detail: "Mentions on the tile and the strip, notifications") {
                BrowserTabController.openSlackSignIn(from: window)
                done()
            }
            ExtraRow(icon: .issues, title: "Jira or Confluence site", detail: "Cloud or Data Center; sign in once") {
                AddSitePalette.show(over: window)
                done()
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func add() {
        guard BrowserURL.isAddress(address), let url = BrowserURL.resolve(address, engine: BrowserData.searchEngine)
        else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = BrowserApps.shared.add(name: trimmed.isEmpty ? BrowserURL.displayHost(url) : trimmed, url: url)
        BrowserApps.shared.open(app, from: window, newTab: false)
        done()
    }
}

private struct ExtraRow: View {
    let icon: StudioIcons.Name
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                StudioIcon(icon, size: 16).foregroundStyle(StudioColors.body).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.studio(13, .medium)).foregroundStyle(StudioColors.ink)
                    Text(detail).font(.studio(11)).foregroundStyle(StudioColors.muted)
                }
                Spacer(minLength: 0)
                StudioIcon(.chevronRight, size: 12).foregroundStyle(StudioColors.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// An open tab: its icon, its title, and × on hover.
private struct BrowserTabRow: View {
    @ObservedObject var tab: BrowserTabController
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 9) {
            SiteIcon(url: tab.state.url, size: 16)
            Text(tab.displayTitle)
                .font(.studio(13, .medium))
                .foregroundStyle(isSelected || hovering ? StudioColors.ink : StudioColors.body)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            // Always in the row, only hidden: a button that appears on hover isn't there yet for the first click, which
            // then lands on the row and selects the tab instead of closing it.
            Button { tab.window?.close() } label: {
                StudioIcon(.close, size: 12).foregroundStyle(StudioColors.muted).frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help("Close Tab")
            .accessibilityLabel("Close \(tab.displayTitle)")
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 32)
        .background {
            if isSelected {
                shape.fill(StudioColors.selection)
                    .overlay(alignment: .leading) { Rectangle().fill(StudioColors.coral).frame(width: 2) }
                    .clipShape(shape)
            } else if hovering {
                shape.fill(StudioColors.hover)
            }
        }
        .contentShape(shape)
        .onTapGesture { tab.bringForward() }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
