import GlanceCore
import GlanceKit
import SwiftUI

/// One of the PR Management canvas's line icons (`StudioIcons`), stroked in the foreground style: the 24-unit grid
/// scaled to `size` points, the stroke scaled with it, round caps and joins (the canvas's `.i` rule).
struct StudioIcon: View {
    let name: StudioIcons.Name
    let size: CGFloat
    /// The stroke on the 24-unit grid: 1.7, or heavier where the canvas thickens one (a check mark's 2.2–2.4).
    let weight: Double

    init(_ name: StudioIcons.Name, size: CGFloat = 16, weight: Double = StudioIcons.strokeWidth) {
        self.name = name
        self.size = size
        self.weight = weight
    }

    var body: some View {
        let scale = size / CGFloat(StudioIcons.grid)
        ZStack {
            ForEach(Array(StudioIcons.shapes(name).enumerated()), id: \.offset) { _, shape in
                IconShape(segments: shape.segments)
                    .stroke(style: StrokeStyle(lineWidth: CGFloat(weight) * scale, lineCap: .round, lineJoin: .round,
                                               dash: shape.dash.map { CGFloat($0) * scale }))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// An icon's shape on the 24-unit grid, scaled into its frame.
private struct IconShape: Shape {
    let segments: [SVGPath.Segment]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / CGFloat(StudioIcons.grid)
        func point(_ p: SVGPath.Point) -> CGPoint {
            CGPoint(x: rect.minX + CGFloat(p.x) * scale, y: rect.minY + CGFloat(p.y) * scale)
        }
        var path = Path()
        for segment in segments {
            switch segment {
            case .move(let p): path.move(to: point(p))
            case .line(let p): path.addLine(to: point(p))
            case .curve(let c1, let c2, let end): path.addCurve(to: point(end), control1: point(c1), control2: point(c2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// The small coral orb that marks Claude in compact UI (the canvas's `.dot`, MASTER §7.2): lit from the upper left,
/// with a soft coral halo.
struct CoralDot: View {
    var size: CGFloat = 11

    var body: some View {
        Circle()
            .fill(RadialGradient(
                stops: [.init(color: Color(red: 1, green: 0.761, blue: 0.651), location: 0),        // #ffc2a6
                        .init(color: Color(red: 0.910, green: 0.392, blue: 0.235), location: 0.55), // #e8643c
                        .init(color: Color(red: 0.722, green: 0.263, blue: 0.122), location: 1)],   // #b8431f
                center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.92))
            .frame(width: size, height: size)
            .shadow(color: Color(red: 0.910, green: 0.392, blue: 0.235).opacity(0.7), radius: 3.5)
            .accessibilityHidden(true)
    }
}

extension Font {
    /// DM Sans, the canvas's face for words (`GlanceFont`, registered at launch).
    @MainActor static func studio(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        GlanceFont.sans(size, weight)
    }

    /// JetBrains Mono, for paths, branches, hashes, numbers and keys.
    @MainActor static func studioMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        GlanceFont.mono(size, weight)
    }
}
