import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

/// The Notifications side bar (spec "Notifications page and side bar"): its header with Do not disturb (the bell) and
/// Mark all read, the filter chips as one segmented row, the threads in compact rows under the page's sections, and
/// "Open as page" (⇧⌘N) at the foot. It shares the page's filter, selection and folded Earlier.
struct NotificationsSidebarView: View {
    @ObservedObject private var hub = NotificationHub.shared
    @ObservedObject private var navigation = NotificationsNavigation.shared
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(title: "Notifications") {
                DoNotDisturbButton()
                SidebarIconButton(icon: .check, label: "Mark all read (⇧⌘A)") { navigation.markAllRead() }
                    .disabled(hub.book.unreadCount(navigation.filter) == 0)
                    .opacity(hub.book.unreadCount(navigation.filter) == 0 ? 0.45 : 1)
            }
            NoticeFilterBar(compact: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let sections = navigation.sections(now: context.date)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        if sections.isEmpty {
                            empty
                        }
                        ForEach(sections) { section in
                            NoticeSectionView(section: section, now: context.date, compact: true)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
            }
            OpenAsPageButton { NotificationsTabController.open(from: window) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowAccessor { window = $0 })
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(navigation.filter.map { "Nothing from \($0.title)" } ?? "All clear")
                .font(.studio(13, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(NoticeText.watching(hub.status, only: navigation.filter))
                .font(.studio(12))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }
}

/// A thread, compact: the source's glyph, the title with its age, and the last line with the unread light. Click
/// selects; double-click opens.
struct NoticeSidebarRow: View {
    let row: NoticeBook.Row
    let now: Date
    @ObservedObject private var navigation = NotificationsNavigation.shared
    @State private var hovering = false

    private var notice: Notice { row.newest }
    private var selected: Bool { navigation.selection == row.id }
    private var done: Bool { notice.state == .done && !row.unread }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            NoticeGlyph(source: notice.source, size: 14)
                .foregroundStyle(selected || hovering || row.unread ? StudioColors.ink : StudioColors.muted)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notice.title)
                        .font(.studio(12.5, row.unread ? .semibold : .medium))
                        .foregroundStyle(StudioColors.ink)
                        .lineLimit(1)
                    if row.folded > 0 {
                        Text("+\(row.folded)")
                            .font(.studioMono(10, .medium))
                            .foregroundStyle(StudioColors.muted)
                    }
                    Spacer(minLength: 4)
                    Text(NoticeText.age(notice.date, now: now))
                        .font(.studioMono(10.5))
                        .foregroundStyle(row.unread ? StudioColors.ink : StudioColors.muted)
                        .fixedSize()
                }
                HStack(alignment: .center, spacing: 6) {
                    Text(previewLine)
                        .font(.studio(11.5))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if row.unread {
                        Circle().fill(StudioColors.coral).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { SettingsRowPlate(selected: selected, hovering: hovering) }
        .opacity(done ? 0.62 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { navigation.select(row) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { navigation.open(row) })
        .contextMenu { NoticeMenu(row: row) }
        .animation(.easeOut(duration: 0.16), value: hovering)
        .help(notice.place.map { "\(notice.title) · \($0)" } ?? notice.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(NoticeText.spoken(row, now: now))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { navigation.open(row) }
    }

    /// "#infra · the build is red", or the preview alone.
    private var previewLine: String {
        let preview = notice.preview.isEmpty ? notice.kind.label : notice.preview
        guard let place = notice.place, !place.isEmpty else { return preview }
        return "\(place) · \(preview)"
    }
}

/// The header's bell: Do not disturb, struck through while it's on.
private struct DoNotDisturbButton: View {
    @ObservedObject private var hub = NotificationHub.shared
    @State private var hovering = false

    var body: some View {
        let on = hub.prefs.doNotDisturb
        Button { hub.prefs.doNotDisturb.toggle() } label: {
            QuietBell(muted: on, size: 16)
                .foregroundStyle(on ? StudioColors.amber : hovering ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? StudioColors.amberFill : hovering ? StudioColors.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Do not disturb is on: nudges are held. Click to turn it off"
                 : "Do not disturb: hold nudges; everything still lands here")
        .accessibilityLabel("Do not disturb")
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The side bar's foot: "Open as page" and its key, quiet over a hairline.
private struct OpenAsPageButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                StudioIcon(.window, size: 14)
                Text("Open as page")
                    .font(.studio(12, .medium))
                Spacer(minLength: 4)
                Kbd("⇧⌘N")
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
        .help("Open Notifications as a page (⇧⌘N)")
    }
}
