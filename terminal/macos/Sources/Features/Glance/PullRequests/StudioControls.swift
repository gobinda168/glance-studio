import GlanceCore
import SwiftUI

// The PR Management canvas's controls, natively (spec 2026-10-07-pr-manager-design.md, "Look"): its `.btn`, `.kbd`,
// pills, cards, `.cap`, avatars, the glow ring, the segmented tabs and fields, sized from its CSS.

/// The canvas's `.btn`: 30 pt tall (26 in the fixing strip), 8 pt corners. Primary is coral with dark text, secondary
/// outlined, quiet borderless and muted. A busy button shows a spinner and takes no clicks.
struct StudioButton: View {
    enum Style { case primary, secondary, quiet }

    let title: String
    var icon: StudioIcons.Name?
    var hint: String?
    var style: Style = .secondary
    var busy = false
    var enabled = true
    var height: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else if let icon {
                    StudioIcon(icon, size: 14)
                }
                Text(title)
                    .font(.studio(12, style == .primary ? .semibold : .medium))
                    .lineLimit(1)
                if let hint { Kbd(hint, onCoral: style == .primary) }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .overlay {
                if style == .secondary {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StudioColors.line3, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    private var foreground: Color {
        switch style {
        case .primary: StudioColors.onCoral
        case .secondary: StudioColors.ink
        case .quiet: hovering && enabled ? StudioColors.ink : StudioColors.muted
        }
    }

    private var fill: Color {
        switch style {
        case .primary: hovering && enabled ? StudioColors.coralHover : StudioColors.coral
        case .secondary, .quiet: hovering && enabled ? StudioColors.hover : .clear
        }
    }
}

/// A key hint (`.kbd`): JetBrains Mono on the field tint, or dark on coral inside a primary button.
struct Kbd: View {
    let keys: String
    var onCoral = false

    init(_ keys: String, onCoral: Bool = false) {
        self.keys = keys
        self.onCoral = onCoral
    }

    var body: some View {
        Text(keys)
            .font(.studioMono(10.5, .semibold))
            .foregroundStyle(onCoral ? StudioColors.onCoral : StudioColors.muted)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(onCoral ? StudioColors.onCoral.opacity(0.12) : StudioColors.field))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(onCoral ? StudioColors.onCoral.opacity(0.2) : StudioColors.line, lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// A capsule of state: Open, Blocked · 2, "14/14", Pending.
struct StatePill: View {
    enum Tone { case ok, danger, amber, coral, teal, neutral }

    let text: String
    var icon: StudioIcons.Name?
    var tone: Tone = .neutral
    var height: CGFloat = 22

    var body: some View {
        let large = height > 21
        HStack(spacing: 5) {
            if let icon { StudioIcon(icon, size: large ? 13 : 11, weight: 2.2) }
            Text(text).font(.studio(large ? 12 : 11, .semibold)).lineLimit(1)
        }
        .foregroundStyle(colors.ink)
        .padding(.horizontal, large ? 10 : 8)
        .frame(height: height)
        .background(Capsule().fill(colors.fill))
        .accessibilityElement(children: .combine)
    }

    private var colors: (ink: Color, fill: Color) {
        switch tone {
        case .ok: (StudioColors.ok, StudioColors.okFill)
        case .danger: (StudioColors.danger, StudioColors.dangerFill)
        case .amber: (StudioColors.amber, StudioColors.amberFill)
        case .coral: (StudioColors.coralInk, StudioColors.selection)
        case .teal: (StudioColors.tealInk, StudioColors.tealFill)
        case .neutral: (StudioColors.muted, StudioColors.chip)
        }
    }
}

/// A small-caps caption (`.cap`): 11 pt semibold, 0.06 em apart, muted.
struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.studio(11, .semibold))
            .tracking(0.66)
            .foregroundStyle(StudioColors.muted)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A card: the `card` fill, a 1 pt `line` border, 12 pt corners, and with `rim` a lit top edge.
struct StudioCard<Content: View>: View {
    var rim = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(StudioColors.card))
            .overlay(alignment: .top) {
                if rim { Rectangle().fill(StudioColors.rim).frame(height: 1).padding(.horizontal, 10) }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(StudioColors.line, lineWidth: 1))
    }
}

/// Who wrote something: the coral dot for Claude (and Claude Code Review), else two initials on a colour of their own.
struct Avatar: View {
    let login: String
    var size: CGFloat = 22

    var body: some View {
        if login.lowercased().contains("claude") {
            CoralDot(size: size)
        } else {
            Text(String(login.prefix(2)).uppercased())
                .font(.studio(size * 0.43, .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Self.color(for: login)))
                .accessibilityHidden(true)
        }
    }

    /// The canvas's avatar colours, picked steadily by name.
    static func color(for login: String) -> Color {
        let palette: [UInt32] = [0x3B6E8F, 0x7A5A9E, 0x5F7A3A, 0x8F5B3B, 0x3B8F7A, 0x8F3B5E]
        let index = login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF } % palette.count
        let hex = palette[index]
        return Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                     blue: Double(hex & 0xFF) / 255)
    }
}

/// The page's one action Claude can take right now, in the glow ring (MASTER §7.1): the coral dot, the words, the key.
struct GlowPill: View {
    let title: String
    var hint: String?
    var busy = false
    var enabled = true
    /// 28 pt beside a thread or a field; 32 pt as a page's main action (the inbox's Fix all blocking).
    var height: CGFloat = 28
    let action: () -> Void

    var body: some View {
        let large = height > 30
        Button(action: action) {
            HStack(spacing: large ? 8 : 7) {
                if busy { ProgressView().controlSize(.mini) } else { CoralDot(size: 11) }
                Text(title).font(.studio(large ? 12.5 : 12, .semibold)).foregroundStyle(StudioColors.ink)
                if let hint { Kbd(hint) }
            }
            .padding(.leading, large ? 12 : 10)
            .padding(.trailing, large ? 9 : 8)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlowRing())
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// MASTER §9's glow ring: the aurora gradient turning once every 3 s around a capsule on the raised face, with its
/// blurred halo. It holds still under Reduce Motion and while its window is off screen (a background tab, covered,
/// minimised): every frame redraws a blur.
struct GlowRing: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = true

    static let aurora: [Color] = [
        Color(red: 0.910, green: 0.392, blue: 0.235), Color(red: 1, green: 0.698, blue: 0.561),
        Color(red: 0.788, green: 0.427, blue: 0.949), Color(red: 0.416, green: 0.659, blue: 1),
        Color(red: 0.910, green: 0.392, blue: 0.235),
    ]

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion || !onScreen)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
            let light = AngularGradient(colors: Self.aurora, center: .center, angle: .degrees(turn * 360))
            content
                .background(Capsule().fill(StudioColors.solid))
                .overlay(Capsule().strokeBorder(light, lineWidth: 1.5))
                .background(Capsule().fill(light).blur(radius: 9).opacity(0.5))
        }
        .background(OnScreenReader { onScreen = $0 })
    }
}

/// The teal orb: Claude thinking or working (`.tdot`).
struct TealDot: View {
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(RadialGradient(
                stops: [.init(color: Color(red: 0.788, green: 0.945, blue: 0.949), location: 0),   // #c9f1f2
                        .init(color: Color(red: 0.165, green: 0.561, blue: 0.580), location: 0.55), // #2a8f94
                        .init(color: Color(red: 0.082, green: 0.353, blue: 0.365), location: 1)],   // #155a5d
                center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.92))
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.165, green: 0.561, blue: 0.580).opacity(0.7), radius: 3.5)
            .accessibilityHidden(true)
    }
}

struct SegmentItem<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let count: Int?

    var id: Value { value }
}

/// The canvas's segmented tabs (Overview · Files 19 · Commits 6 · Checks 14): a `seg` track, the selected one raised.
/// With `fill`, the items share the full width (a side bar's tabs).
struct SegmentedTabs<Value: Hashable>: View {
    let items: [SegmentItem<Value>]
    @Binding var selection: Value
    var fill = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 6) {
                        Text(item.title).font(.studio(12, selected ? .semibold : .medium))
                        if let count = item.count { Text("\(count)").font(.studioMono(11)) }
                    }
                    .foregroundStyle(selected ? StudioColors.ink : StudioColors.muted)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: fill ? .infinity : nil)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? StudioColors.solid : .clear)
                        .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 1, y: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(StudioColors.field))
        .animation(.easeOut(duration: 0.24), value: selection)
    }
}

/// A multi-line field (the canvas's textarea): DM Sans 13 (or JetBrains Mono for Markdown sources) with a placeholder.
/// Its container draws the border.
struct StudioTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 72
    var mono = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(mono ? .studioMono(12.5) : .studio(13))
                    .foregroundStyle(StudioColors.muted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(mono ? .studioMono(12.5) : .studio(13))
                .foregroundStyle(StudioColors.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
        }
        .frame(minHeight: minHeight)
    }
}

/// What went wrong with a read or a write, in one line: the danger tint, the message, and Retry when there's one.
struct InlineError: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StudioIcon(.alert, size: 13).foregroundStyle(StudioColors.danger)
            Text(message)
                .font(.studio(12))
                .foregroundStyle(StudioColors.danger)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.plain)
                    .font(.studio(12, .semibold))
                    .foregroundStyle(StudioColors.coralInk)
            }
        }
    }
}

/// Chips that wrap onto more lines (labels).
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += line + spacing
                line = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A name in JetBrains Mono on a chip (a tool an automation step used). Branches use GlanceKit's BranchChip.
struct MonoChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.studioMono(11.5))
            .foregroundStyle(StudioColors.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(StudioColors.chip))
    }
}

enum StudioTime {
    /// "2 days ago", "just now"; empty without a date.
    static func ago(_ date: Date?) -> String {
        guard let date else { return "" }
        if Date().timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
