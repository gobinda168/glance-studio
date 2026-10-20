import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Tickets side bar (spec "Tickets page and side bar"): its header with Refresh, the tracker chips and filter,
/// Today and Up next in compact rows, and "Open as page" (⌥⌘T) at the foot. It shares the page's selection and filter.
struct TicketsSidebarView: View {
    @ObservedObject private var service = TicketService.shared
    @ObservedObject private var probe = ConnectorProbe.shared
    @ObservedObject private var navigation = TicketsNavigation.shared
    @State private var window: NSWindow?

    var body: some View {
        let arranged = navigation.arranged()
        VStack(spacing: 0) {
            SidebarHeader(title: "Tickets") {
                if probe.checking || service.states.values.contains(.fetching) {
                    ProgressView().controlSize(.mini).padding(.trailing, 8)
                } else {
                    SidebarIconButton(icon: .refresh, label: "Refresh (R)") { service.refresh() }
                }
            }
            TicketsTrackerBar(compact: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if arranged.today.isEmpty && arranged.upNext.isEmpty {
                        empty
                    } else {
                        TicketSection(title: "Today", rows: arranged.today, numbered: true, now: Date(),
                                      compact: true)
                        if !arranged.upNext.isEmpty {
                            TicketSection(title: "Up next", rows: arranged.upNext, numbered: false, now: Date(),
                                          compact: true)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            TicketsOpenAsPage { TicketsTabController.open(from: window) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
        .onAppear { if service.book.asOf == nil { service.refresh() } }
    }

    private var empty: some View {
        let signIn = service.allTrackers.isEmpty ? TrackerProbe.signInWords(probe.servers) : nil
        return VStack(alignment: .leading, spacing: 4) {
            Text(probe.checked && service.enabledTrackers.isEmpty ? signIn?.title ?? "No tracker connected"
                 : "Nothing to list")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(probe.checked && service.enabledTrackers.isEmpty
                 ? signIn?.line ?? "Connect Jira, Linear or GitHub in Settings → Connectors."
                 : "Open the page to refresh or change the filter.")
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            if probe.checked && service.enabledTrackers.isEmpty {
                StudioButton(title: "Open Connectors", icon: .plug, style: .secondary, height: 26) {
                    ConnectorsSettings.open()
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// A ticket, compact: its rank or status light, key and title, and its status in words under them. Click selects;
/// double-click opens.
struct TicketSidebarRow: View {
    let item: TicketRanking.Ranked
    let number: Int?
    @ObservedObject private var navigation = TicketsNavigation.shared
    @State private var hovering = false

    private var ticket: Ticket { item.ticket }
    private var selected: Bool { navigation.selection == ticket.id }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "·")
                .font(.studioMono(11, .medium))
                .foregroundStyle(StudioColors.muted)
                .frame(width: 16, alignment: .trailing)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ticket.key)
                        .font(.studioMono(11))
                        .foregroundStyle(StudioColors.muted)
                        .fixedSize()
                    Text(ticket.title)
                        .font(.studio(12.5, .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(ticket.status)
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? StudioColors.selection : hovering ? StudioColors.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { navigation.select(ticket) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.open(ticket) })
        .contextMenu { TicketMenu(ticket: ticket) }
        .help(item.reason ?? ticket.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ticket.key), \(ticket.title), \(ticket.status)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { navigation.open(ticket) }
    }
}

/// The side bar's foot: "Open as page" and its key, quiet over a hairline.
private struct TicketsOpenAsPage: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StudioIcon(.window, size: 14)
                Text("Open as page")
                    .font(.studio(12, .medium))
                Spacer(minLength: 4)
                Kbd("⌥⌘T")
            }
            .foregroundStyle(hovering ? StudioColors.ink : StudioColors.body)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? StudioColors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(StudioColors.line).frame(height: 1) }
        .help("Open Tickets as a page (⌥⌘T)")
    }
}
