import GlanceCore
import SwiftUI

/// A notice's source as one of Glance Studio's line icons (`StudioIcons`, MASTER §8 "Iconography"): Slack is the chat
/// bubble, GitHub the pull request, Meetings the clock, Claude the terminal prompt. Stroked in the foreground style, the
/// 24-unit grid scaled to `size` points with round caps and joins, as Studio's `StudioIcon` draws them.
public struct NoticeGlyph: View {
  let source: Notice.Source
  let size: CGFloat

  public init(source: Notice.Source, size: CGFloat) {
    self.source = source
    self.size = size
  }

  static func icon(_ source: Notice.Source) -> StudioIcons.Name {
    switch source {
    case .slack: .chats
    case .github: .pullRequest
    case .meeting: .clock
    case .claude: .terminal
    case .tickets: .checklist
    case .automations: .automations
    }
  }

  public var body: some View {
    let scale = size / CGFloat(StudioIcons.grid)
    ZStack {
      ForEach(Array(StudioIcons.shapes(Self.icon(source)).enumerated()), id: \.offset) { _, shape in
        GlyphShape(segments: shape.segments)
          .stroke(style: StrokeStyle(lineWidth: CGFloat(StudioIcons.strokeWidth) * scale, lineCap: .round,
                                     lineJoin: .round, dash: shape.dash.map { CGFloat($0) * scale }))
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel(source.title)
  }
}

/// Who a notice is from: their picture (`avatarURL`), or their initials on a quiet surface until it loads or when
/// there is none.
public struct NoticeAvatar: View {
  let notice: Notice
  let size: CGFloat

  public init(notice: Notice, size: CGFloat) {
    self.notice = notice
    self.size = size
  }

  public var body: some View {
    ZStack {
      Circle().fill(GlanceColor.solid)
      Text(Self.initials(notice.people.first ?? notice.title))
        .font(GlanceFont.sans(max(11, size * 0.38), .semibold))
        .foregroundStyle(GlanceColor.muted)
      if let url = notice.avatarURL {
        AsyncImage(url: url) { phase in
          if case .success(let image) = phase {
            image.resizable().scaledToFill()
          }
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    .accessibilityHidden(true)
  }

  /// `riya sen` → `RS`, `@riya` → `R`, `#infra` → `I`.
  static func initials(_ name: String) -> String {
    let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "." || $0 == "-" || $0 == "_" })
      .map { $0.drop(while: { !$0.isLetter && !$0.isNumber }) }
      .filter { !$0.isEmpty }
    return words.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
  }
}

/// An icon's shape on the 24-unit grid, scaled into its frame.
private struct GlyphShape: Shape {
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
