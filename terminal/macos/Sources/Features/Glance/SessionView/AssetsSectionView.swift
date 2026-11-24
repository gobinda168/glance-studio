import AppKit
import GlanceCore
import GlanceKit
import SwiftUI

// MARK: - Groups

extension AssetItem.Group {
    /// The replica's `SV.ASSET_GROUPS`.
    var label: String {
        switch self {
        case .outcome: "Outcome"
        case .pr: "In the PR"
        case .testing: "Testing"
        case .branch: "On the branch"
        case .testRun: "Test runs"
        }
    }

    var sub: String {
        switch self {
        case .outcome: "Final result, marked by Claude"
        case .pr: "From the PR description and comments"
        case .testing: "Screenshots Claude took while checking"
        case .branch: "Media this branch added or changed"
        case .testRun: "Videos and screenshots from test runs"
        }
    }

    var symbol: String {
        switch self {
        case .outcome: "star"
        case .pr: "arrow.triangle.pull"
        case .testing: "eye"
        case .branch: "arrow.triangle.branch"
        case .testRun: "terminal"
        }
    }

    /// The group's colour as text on the panel.
    var tint: Color {
        switch self {
        case .outcome: StudioColors.coralInk
        case .pr: StudioColors.syntaxType
        case .testing: StudioColors.tealInk
        case .branch: StudioColors.ink
        case .testRun: StudioColors.body
        }
    }

    /// The same, as text on a tile's dark tag (which is dark in light mode too).
    fileprivate var tagTint: Color {
        switch self {
        case .outcome: StudioColors.tagOutcome
        case .pr: StudioColors.tagPR
        case .testing: StudioColors.tagTesting
        case .branch: StudioColors.tagBranch
        case .testRun: StudioColors.tagTestRun
        }
    }
}

// MARK: - Section header

/// The count in the section's header. Observes the model itself: the panel builds the header from the view model alone.
struct AssetsSectionSummary: View {
    @ObservedObject var assets: AssetsModel

    var body: some View {
        Text("\(assets.items.count)").font(.studioMono(12)).monospacedDigit().foregroundStyle(StudioColors.muted)
            .accessibilityLabel("\(assets.items.count) \(assets.items.count == 1 ? "item" : "items")")
    }
}

// MARK: - Body

/// Replica: sessionview.js `SV.assetsSection` / `SV.wireAssets`. Filter chips with counts, a grid or list toggle, then
/// each group under its own header.
struct AssetsSectionBody: View {
    @ObservedObject var assets: AssetsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls
            let shown = assets.shown
            ForEach(AssetItem.Group.allCases, id: \.self) { group in
                let items = shown.filter { $0.group == group }
                if !items.isEmpty {
                    groupHeader(group)
                    switch assets.layout {
                    case .grid:
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(items) { AssetTile(item: $0, detail: assets.detail(of: $0), scanning: assets.scanning) }
                        }
                    case .list:
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(items) { AssetRow(item: $0, detail: assets.detail(of: $0), scanning: assets.scanning) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 8) {
            FlowRow(spacing: 4) {
                chip("All", count: assets.items.count, group: nil)
                ForEach(AssetItem.Group.allCases, id: \.self) { group in
                    let n = assets.count(in: group)
                    if n > 0 { chip(group.label, count: n, group: group) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                layoutButton(.grid, symbol: "square.grid.2x2", label: "Grid")
                layoutButton(.list, symbol: "list.bullet", label: "List")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(StudioColors.chip))
        }
        .padding(.top, 4)
    }

    private func chip(_ title: String, count: Int, group: AssetItem.Group?) -> some View {
        let on = assets.activeFilter == group
        return Button { assets.filter = group } label: {
            HStack(spacing: 5) {
                Text(title).font(.studio(11.5, on ? .semibold : .medium))
                Text("\(count)").font(.studioMono(11)).foregroundStyle(StudioColors.muted)
            }
            .foregroundStyle(on ? StudioColors.ink : StudioColors.body)
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(Capsule().fill(on ? StudioColors.selection : Color.clear))
            .overlay(Capsule().stroke(on ? StudioColors.coral.opacity(0.5) : StudioColors.line, lineWidth: on ? 1.5 : 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func layoutButton(_ layout: AssetsModel.Layout, symbol: String, label: String) -> some View {
        let on = assets.layout == layout
        return Button { assets.layout = layout } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? StudioColors.ink : StudioColors.muted)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? StudioColors.solid : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? StudioColors.line3 : Color.clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func groupHeader(_ group: AssetItem.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: group.symbol).font(.system(size: 11, weight: .semibold))
                Text(group.label).font(.studio(12, .semibold))
            }
            .foregroundStyle(group.tint)
            .fixedSize()
            Text(group.sub).font(.studio(11.5)).foregroundStyle(StudioColors.muted).lineLimit(1).truncationMode(.tail)
        }
        .padding(.top, 16).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Facts

private extension AssetItem {
    /// Why there is no picture. Not fetched yet (`pending`) is not a failure: it reads "Loading…" while a scan runs and
    /// "Not loaded yet" after; only a real failure, or a file that is gone, reads "Couldn't load".
    func unavailable(scanning: Bool) -> String? {
        if pending { return scanning ? "Loading…" : "Not loaded yet" }
        return file == nil || failed ? "Couldn't load" : nil
    }

    var symbol: String {
        switch kind {
        case .video: "film"
        case .image: "photo"
        case .file: "doc"
        }
    }

    var kindWord: String {
        switch kind {
        case .video: "Video"
        case .image: "Image"
        case .file: "File"
        }
    }
}

private func clock(_ seconds: Double) -> String {
    let whole = Int(seconds.rounded())
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

// MARK: - Thumbnail

/// A picture or a video's first frame, decoded off the main thread at thumbnail size.
private struct AssetThumbnail: View {
    let item: AssetItem

    private enum Loaded { case loading, picture(CGImage), plain, missing }
    @State private var loaded: Loaded = .loading

    var body: some View {
        ZStack {
            StudioColors.mediaBack
            switch loaded {
            case .picture(let image): Image(decorative: image, scale: 2).resizable().scaledToFill()
            case .loading: EmptyView()
            case .plain: Image(systemName: item.symbol).font(.system(size: 20)).foregroundStyle(Color.white.opacity(0.6))
            case .missing: Image(systemName: "photo.badge.exclamationmark").font(.system(size: 20)).foregroundStyle(Color.white.opacity(0.6))
            }
        }
        .task(id: item.file) { loaded = await Self.load(item) }
    }

    private static func load(_ item: AssetItem) async -> Loaded {
        guard let file = item.file else { return .missing }
        if item.kind == .video {
            guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
            if let frame = await VideoThumbnail.image(of: file, maxSide: 320) { return .picture(frame) }
            return .plain
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        guard item.kind == .image else { return .plain }
        // Through the gate: threads of its own, a few at a time, with a time limit (the placeholder after it).
        if let image = await PictureThumbnail.image(of: file, maxPixel: 320) { return .picture(image) }
        return .plain
    }
}

// MARK: - Tile

/// One item in the grid: its picture with the group's tag (icon and word, never colour alone), a play glyph and length
/// on a video, then its name and environment.
struct AssetTile: View {
    let item: AssetItem
    let detail: AssetsModel.Detail?
    let scanning: Bool

    var body: some View {
        let unavailable = item.unavailable(scanning: scanning)
        Button {
            if let file = item.file { QuickLookPreview.shared.show(file.path) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .overlay { if unavailable == nil { AssetThumbnail(item: item) } else { placeholder(unavailable ?? "") } }
                    .overlay(alignment: .topLeading) { tag.padding(5) }
                    .overlay {
                        if item.kind == .video, unavailable == nil {
                            Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(StudioColors.mediaScrim.opacity(0.78)))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if item.kind == .video, unavailable == nil, let seconds = detail?.duration {
                            Text(clock(seconds)).font(.studioMono(11)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(StudioColors.mediaScrim.opacity(0.75)))
                                .padding(5)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(item.group == .outcome ? StudioColors.coralInk.opacity(0.55) : StudioColors.line3, lineWidth: 1))
                Text(item.name).font(.studio(11.5, .medium)).foregroundStyle(StudioColors.body).lineLimit(1).truncationMode(.middle)
                if let environment = item.environment, !environment.isEmpty {
                    Text(environment).font(.studio(11)).foregroundStyle(StudioColors.muted).lineLimit(1).padding(.top, -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .help(item.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, item.group.label, item.kindWord, detail?.duration.map(clock), item.environment, unavailable]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(unavailable == nil ? "Opens a preview" : "")
    }

    private var tag: some View {
        HStack(spacing: 3) {
            Image(systemName: item.group.symbol).font(.system(size: 10, weight: .semibold))
            Text(item.group.label).font(.studio(11, .semibold)).lineLimit(1)
        }
        .foregroundStyle(item.group.tagTint)
        .padding(.horizontal, 6).frame(height: 18)
        .background(Capsule().fill(StudioColors.mediaScrim.opacity(0.82)))
    }

    private func placeholder(_ word: String) -> some View {
        ZStack {
            StudioColors.chip
            VStack(spacing: 4) {
                Image(systemName: item.symbol).font(.system(size: 18)).foregroundStyle(StudioColors.muted)
                Text(word).font(.studio(11, .medium)).foregroundStyle(StudioColors.muted)
            }
        }
    }
}

// MARK: - Row

/// The list form: icon, name and path, then length · environment · size.
private struct AssetRow: View {
    let item: AssetItem
    let detail: AssetsModel.Detail?
    let scanning: Bool

    var body: some View {
        let unavailable = item.unavailable(scanning: scanning)
        Button {
            if let file = item.file { QuickLookPreview.shared.show(file.path) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(StudioColors.muted)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(StudioColors.chip))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name).font(.studio(12.5, .medium)).foregroundStyle(StudioColors.ink).lineLimit(1).truncationMode(.middle)
                    Text(item.path).font(.studioMono(11)).foregroundStyle(StudioColors.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Text(meta(unavailable)).font(.studioMono(11)).foregroundStyle(StudioColors.muted).lineLimit(1).fixedSize()
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .help(item.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.name, item.group.label, item.kindWord, meta(unavailable)].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint(unavailable == nil ? "Opens a preview" : "")
    }

    private func meta(_ unavailable: String?) -> String {
        if let unavailable { return unavailable }
        return [item.kind == .video ? detail?.duration.map(clock) : nil, item.environment,
                (item.bytes ?? detail?.bytes).map(size)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
