import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GlanceCore

enum ComposerMenu: Equatable {
    case commands([SlashCommand])
    case files([String])

    enum Item: Equatable { case command(SlashCommand), file(String) }
    struct Section { let title: String?; let items: [Item] }

    /// Commands grouped under Built in / Yours / Project / each plugin, best match first inside a group.
    var sections: [Section] {
        switch self {
        case .files(let paths):
            return [Section(title: nil, items: paths.map(Item.file))]
        case .commands(let commands):
            var groups: [String: [SlashCommand]] = [:]
            for command in commands { groups[Self.heading(command.source), default: []].append(command) }
            let fixed = ["Built in", "Yours", "Project"]
            let titles = fixed.filter(groups.keys.contains) + groups.keys.filter { !fixed.contains($0) }.sorted()
            return titles.map { Section(title: $0, items: groups[$0, default: []].map(Item.command)) }
        }
    }

    /// The rows in on-screen order, which the arrow keys walk.
    var ordered: [Item] { sections.flatMap(\.items) }
    var count: Int { ordered.count }

    static func heading(_ source: SlashCommand.Source) -> String {
        switch source {
        case .builtIn: "Built in"
        case .user: "Yours"
        case .project: "Project"
        case .plugin(let name): name
        }
    }
}

struct ComposerMenuView: View {
    let menu: ComposerMenu
    @Binding var index: Int
    let accept: (Int) -> Bool
    @State private var pointer = PointerTracker()

    var body: some View {
        let sections = menu.sections
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { s, section in
                        if let title = section.title {
                            Text(title.uppercased()).font(.studio(11, .semibold)).tracking(0.66)
                                .foregroundStyle(StudioColors.muted)
                                .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { i, item in
                            let row = Self.start(of: s, in: sections) + i
                            MenuRow(item: item, selected: row == index)
                                .id(row)
                                .onTapGesture { _ = accept(row) }
                                .onContinuousHover(coordinateSpace: .global) { phase in
                                    if case .active(let point) = phase, pointer.moved(to: point) { index = row }
                                }
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: index) { proxy.scrollTo(index) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: min(height(sections), 304))
        .background(RoundedRectangle(cornerRadius: 10).fill(StudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(StudioColors.line3, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private static func start(of section: Int, in sections: [ComposerMenu.Section]) -> Int {
        sections.prefix(section).reduce(0) { $0 + $1.items.count }
    }

    /// 30 per row and 28 per heading, capped so at most 8 rows show before it scrolls.
    private func height(_ sections: [ComposerMenu.Section]) -> CGFloat {
        CGFloat(menu.count) * 30 + CGFloat(sections.filter { $0.title != nil }.count) * 28 + 12
    }
}

/// Tells a pointer that moved from a menu that scrolled under it: hover reports the row under a resting pointer
/// whenever the arrow keys scroll, and that must not take the selection back.
private final class PointerTracker {
    private var last: CGPoint?

    func moved(to point: CGPoint) -> Bool {
        defer { last = point }
        guard let last else { return false }
        return hypot(point.x - last.x, point.y - last.y) >= 1
    }
}

private struct MenuRow: View {
    let item: ComposerMenu.Item
    let selected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            switch item {
            case .command(let command):
                Text("/" + command.name).font(.studioMono(12.5)).foregroundStyle(StudioColors.ink).lineLimit(1).fixedSize()
                Text(command.summary).font(.studio(12)).foregroundStyle(StudioColors.muted)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if command.interactive { Tag(text: "Terminal") } else if let chip = chip(command.source) { Tag(text: chip) }
            case .file(let path):
                let name = (path as NSString).lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                Text(name).font(.studioMono(12.5)).foregroundStyle(StudioColors.ink).lineLimit(1).fixedSize()
                if !folder.isEmpty {
                    Text(folder).font(.studioMono(12)).foregroundStyle(StudioColors.muted)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? StudioColors.selection : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chip(_ source: SlashCommand.Source) -> String? {
        switch source {
        case .builtIn: nil
        case .user: "yours"
        case .project: "project"
        case .plugin(let name): name
        }
    }
}

private struct Tag: View {
    let text: String
    var body: some View {
        Text(text).font(.studio(11, .medium)).foregroundStyle(StudioColors.muted)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(StudioColors.chip))
            .lineLimit(1).fixedSize()
    }
}
