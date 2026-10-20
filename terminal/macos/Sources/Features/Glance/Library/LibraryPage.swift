import GlanceCore
import SwiftUI

// The full-width libraries of Automations, Agents and Mods (spec 2026-10-14-fullwidth-libraries-design.md; the
// replica's libraries.js): a strip click opens the item's library with no side bar: the header (title, search, New),
// Needs you, and the library as a grid of cards. A card opens the item's own tab, where the side bar comes back.

/// The library's All · On · Off.
enum LibraryFilter: Hashable {
    case all, on, off

    func keeps(_ isOn: Bool) -> Bool {
        switch self {
        case .all: true
        case .on: isOn
        case .off: !isOn
        }
    }
}

/// A library page's frame: scrolls, at most 1240 wide, the page's padding.
struct LibraryScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 26) { content }
                .frame(maxWidth: 1240, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StudioColors.background)
    }
}

/// The title and what the library holds, then its search (⌘F) and its New button.
struct LibraryHeader: View {
    let title: String
    let subtitle: String
    let searchPrompt: String
    @Binding var query: String
    let addTitle: String
    var addEnabled = true
    var addHelp: String?
    let add: () -> Void
    @FocusState private var searching: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 24) {
                titles
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 16) {
                titles
                controls
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.studio(22, .bold))
                .tracking(-0.22)
                .foregroundStyle(StudioColors.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.studio(13))
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                StudioIcon(.search, size: 14)
                    .foregroundStyle(StudioColors.muted)
                TextField(searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.studio(12))
                    .foregroundStyle(StudioColors.ink)
                    .focused($searching)
                    .onExitCommand { query = "" }
                    .accessibilityLabel(searchPrompt)
                if !searching && query.isEmpty { Kbd("⌘F") }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(width: 260, height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(StudioColors.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(searching ? StudioColors.coral : StudioColors.line, lineWidth: 1))
            .background {
                // ⌘F puts the cursor in the search.
                Button("") { searching = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()
                    .accessibilityHidden(true)
            }
            StudioButton(title: addTitle, icon: .plus, style: .primary, enabled: addEnabled, action: add)
                .help(addHelp ?? addTitle)
        }
    }
}

/// A section's caption and count, with something on the right (the filter).
struct LibraryCaption<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Caption(title)
            Text("\(count)")
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.muted)
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: 30)
    }
}

extension LibraryCaption where Trailing == EmptyView {
    init(title: String, count: Int) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// All · On · Off with how many each holds.
struct LibraryFilterTabs: View {
    @Binding var filter: LibraryFilter
    let on: Int
    let off: Int

    var body: some View {
        SegmentedTabs(items: [
            SegmentItem(value: LibraryFilter.all, title: "All", count: on + off),
            SegmentItem(value: LibraryFilter.on, title: "On", count: on),
            SegmentItem(value: LibraryFilter.off, title: "Off", count: off),
        ], selection: $filter)
    }
}

/// The cards, as many columns as fit at 272 pt or more.
struct LibraryGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 272), spacing: 12, alignment: .top)], alignment: .leading,
                  spacing: 12) {
            content
        }
    }
}

/// One item: its name and switch, two lines on what it does, and along the bottom its chips and its status.
struct LibraryCard<Footer: View>: View {
    let name: String
    let detail: String
    @Binding var isOn: Bool
    var switchEnabled = true
    /// Something is waiting on the user (an amber edge).
    var waiting = false
    let open: () -> Void
    @ViewBuilder var footer: Footer
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(name)
                    .font(.studio(13.5, .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(isOn ? StudioColors.ink : StudioColors.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                SettingsSwitch(label: "\(name) on", isOn: $isOn, enabled: switchEnabled)
            }
            Text(detail)
                .font(.studio(12))
                .lineSpacing(2)
                .foregroundStyle(isOn ? StudioColors.body : StudioColors.muted)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) { footer }
                .padding(.top, 10)
                .overlay(alignment: .top) { Rectangle().fill(StudioColors.line2).frame(height: 1) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .background(shape.fill(hovering ? StudioColors.hover.opacity(0.35) : .clear).background(shape.fill(StudioColors.card)))
        .overlay(shape.strokeBorder(waiting ? StudioColors.amber.opacity(0.5) : hovering ? StudioColors.line3 : StudioColors.line,
                                    lineWidth: 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(detail)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Open", open)
    }
}

/// A chip in a card's footer: a trigger, a count of settings.
struct LibraryChip: View {
    var icon: StudioIcons.Name?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                StudioIcon(icon, size: 11)
                    .foregroundStyle(StudioColors.muted)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.studioMono(11))
                .foregroundStyle(StudioColors.body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StudioColors.chip))
    }
}

/// Something waiting on the user, as a row across the page: an amber edge, what it is, and the button that goes there.
struct LibraryNeedRow: View {
    let line: AutomationNeedLine
    let action: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            AutomationStatusGlyph(tone: line.tone, size: 13)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.studio(13, .semibold))
                    .foregroundStyle(StudioColors.ink)
                    .lineLimit(1)
                if !line.detail.isEmpty {
                    Text((try? AttributedString(markdown: line.detail)) ?? AttributedString(line.detail))
                        .font(.studio(12))
                        .foregroundStyle(StudioColors.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            StudioButton(title: action, height: 26, action: open)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(shape.fill(StudioColors.card))
        .overlay(alignment: .leading) {
            Rectangle().fill(line.tone == .failed ? StudioColors.danger : StudioColors.amber).frame(width: 3)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(hovering ? StudioColors.line3 : StudioColors.line, lineWidth: 1))
        .contentShape(shape)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
    }
}

/// An empty library: what it would hold and how to start one.
struct LibraryEmpty: View {
    let title: String
    let text: String
    var link: (title: String, action: () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.studio(14, .semibold))
                .foregroundStyle(StudioColors.ink)
            Text(text)
                .font(.studio(12.5))
                .lineSpacing(2)
                .foregroundStyle(StudioColors.body)
                .fixedSize(horizontal: false, vertical: true)
            if let link {
                Button(link.title, action: link.action)
                    .buttonStyle(.plain)
                    .font(.studio(12, .medium))
                    .foregroundStyle(StudioColors.coralInk)
            }
        }
        .padding(22)
        .frame(maxWidth: 520, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 1))
    }
}

/// "No automation matches “foo”.", or under On / Off "No automation is on."
struct LibraryNoMatch: View {
    let noun: String
    var query = ""
    var filter = LibraryFilter.all

    var body: some View {
        Text(query.isEmpty ? "No \(noun) is \(filter == .on ? "on" : "off")."
             : "No \(noun) matches “\(query.trimmingCharacters(in: .whitespaces))”.")
            .font(.studio(12.5))
            .foregroundStyle(StudioColors.muted)
            .padding(.vertical, 18)
    }
}

/// The top row of an item's side bar: the way back to its full-width library ("All automations").
struct LibrarySidebarRow: View {
    let title: String
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                StudioIcon(.layers, size: 14)
                    .foregroundStyle(StudioColors.ink)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StudioColors.field))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(StudioColors.line, lineWidth: 0.75))
                Text(title)
                    .font(.studio(12.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? StudioColors.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.bottom, 6)
        .accessibilityLabel(title)
    }
}
