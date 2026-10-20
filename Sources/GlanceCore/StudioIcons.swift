import Foundation

/// The line icons of the "Glance Studio — PR Management" canvas, by name: its inline SVGs (Lucide's shapes on a
/// 24-unit grid), parsed once. Glance Studio's `StudioIcon` strokes them 1.7 units wide with round caps and joins, as
/// the canvas's `.i` rule does (spec 2026-10-07-pr-manager-design.md).
public enum StudioIcons {
  public enum Name: String, CaseIterable, Sendable {
    // The strip.
    case chats, terminal, editor, agents, automations, pullRequest, tools, settings, journal, issues, docs, notes, puzzle
    // Pull requests and git.
    case pullRequestDraft, merge, branch, commit
    // Controls and marks.
    case home, search, plus, refresh, filter, chevronDown, chevronRight, chevronLeft, chevronUp, collapse, check, close
    case clock, alert, bell, checklist, copy, download, pencil, trash, speaker, file, fileNew, play, arrowLeft, reply, spinner, circle
    case pause, split, lock, folder, window, mic, layers, eye, eyeOff, suggest, chart, star, person, globe, more, plug
    case maximize, minimize
  }

  /// One stroked part of an icon; `dash` is its dash pattern in grid units, empty for a solid line.
  public struct Shape: Equatable, Sendable {
    public let segments: [SVGPath.Segment]
    public let dash: [Double]
  }

  /// The grid the icons are drawn on, and the stroke width on it.
  public static let grid: Double = 24
  public static let strokeWidth: Double = 1.7

  /// An icon's shapes, back to front.
  public static func shapes(_ name: Name) -> [Shape] { parsed[name] ?? [] }

  private static let parsed: [Name: [Shape]] = Dictionary(uniqueKeysWithValues: Name.allCases.map { name in
    (name, source(name).map(\.shape))
  })

  private enum Element {
    case path(String, dash: [Double] = [])
    case circle(Double, Double, Double)
    case rect(Double, Double, Double, Double, rx: Double)
    case line(Double, Double, Double, Double)

    var shape: Shape {
      switch self {
      case .path(let data, let dash):
        Shape(segments: SVGPath.parse(data) ?? [], dash: dash)
      case .circle(let cx, let cy, let r):
        Shape(segments: SVGPath.circle(cx: cx, cy: cy, r: r), dash: [])
      case .rect(let x, let y, let width, let height, let rx):
        Shape(segments: SVGPath.rect(x: x, y: y, width: width, height: height, rx: rx), dash: [])
      case .line(let x1, let y1, let x2, let y2):
        Shape(segments: SVGPath.line(x1: x1, y1: y1, x2: x2, y2: y2), dash: [])
      }
    }
  }

  /// Each icon as the canvas writes it (`<path d>`, `<circle>`, `<rect>`, `<line>`), back to front.
  private static func source(_ name: Name) -> [Element] {
    switch name {
    case .chats: [.path("M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z")]
    case .terminal: [.path("m4 17 6-6-6-6"), .path("M12 19h8")]
    case .editor: [.path("m16 18 6-6-6-6"), .path("m8 6-6 6 6 6")]
    case .agents:
      [.rect(4, 8, 16, 12, rx: 2), .path("M12 8V5"), .circle(12, 4, 1), .path("M9 13v2M15 13v2")]
    case .automations: [.path("M13 2 3 14h9l-1 8 10-12h-9z")]
    case .pullRequest:
      [.circle(18, 18, 3), .circle(6, 6, 3), .path("M13 6h3a2 2 0 0 1 2 2v7"), .line(6, 9, 6, 21)]
    case .tools:
      [.path("M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z")]
    case .settings: [.path("M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6")]
    case .journal:
      [.path("M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1 0-5H20"), .path("M10 2v8l3-3 3 3V2")]
    case .issues: // Lucide "ticket"
      [.path("M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"),
       .path("M13 5v2"), .path("M13 17v2"), .path("M13 11v2")]
    case .docs: // Lucide "file-text"
      [.path("M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"), .path("M14 2v4a2 2 0 0 0 2 2h4"),
       .path("M10 9H8"), .path("M16 13H8"), .path("M16 17H8")]
    case .pullRequestDraft:
      [.circle(18, 18, 3), .circle(6, 6, 3), .line(6, 9, 6, 21), .path("M18 9v3M18 4v1", dash: [2, 2])]
    case .merge: [.circle(18, 18, 3), .circle(6, 6, 3), .path("M6 21V9a9 9 0 0 0 9 9")]
    case .branch: [.line(6, 3, 6, 15), .circle(18, 6, 3), .circle(6, 18, 3), .path("M18 9a9 9 0 0 1-9 9")]
    case .commit: [.circle(12, 12, 3), .path("M3 12h6M15 12h6")]
    case .home:
      [.path("M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8"),
       .path("M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z")]
    case .search: [.circle(11, 11, 7), .path("m20 20-3.5-3.5")]
    case .plus: [.path("M12 5v14M5 12h14")]
    case .refresh: [.path("M21 12a9 9 0 1 1-3-6.7L21 8"), .path("M21 3v5h-5")]
    case .filter: [.path("M3 5h18l-7 8v6l-4 2v-8z")]
    case .chevronDown: [.path("m6 9 6 6 6-6")]
    case .chevronRight: [.path("m9 6 6 6-6 6")]
    case .chevronLeft: [.path("M15 6l-6 6 6 6")]
    case .chevronUp: [.path("m18 15-6-6-6 6")]
    case .collapse: [.path("m7 15 5-5 5 5")]
    case .check: [.path("M20 6 9 17l-5-5")]
    case .close: [.path("M18 6 6 18M6 6l12 12")]
    case .clock: [.circle(12, 12, 9), .path("M12 7v5l3 2")]
    case .alert: [.circle(12, 12, 9), .path("M12 8v5M12 16h.01")]
    case .bell: [.path("M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"), .path("M10.3 21a1.94 1.94 0 0 0 3.4 0")]
    case .notes: // Lucide "sticky-note"
      [.path("M16 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V8z"), .path("M15 3v4a2 2 0 0 0 2 2h4")]
    case .puzzle: // Lucide "puzzle"
      [.path("M15.39 4.39a1 1 0 0 0 1.68-.474 2.5 2.5 0 1 1 3.014 3.015 1 1 0 0 0-.474 1.68l1.683 1.682a2.414 2.414 0 0 1 0 3.414L19.61 15.39a1 1 0 0 1-1.68-.474 2.5 2.5 0 1 0-3.014 3.015 1 1 0 0 1 .474 1.68l-1.683 1.682a2.414 2.414 0 0 1-3.414 0L8.61 19.61a1 1 0 0 0-1.68.474 2.5 2.5 0 1 1-3.014-3.015 1 1 0 0 0 .474-1.68l-1.683-1.682a2.414 2.414 0 0 1 0-3.414L4.39 8.61a1 1 0 0 1 1.68.474 2.5 2.5 0 1 0 3.014-3.015 1 1 0 0 1-.474-1.68l1.683-1.682a2.414 2.414 0 0 1 3.414 0z")]
    case .checklist:
      [.path("M10 6h11"), .path("M10 12h11"), .path("M10 18h11"), .path("M3 6l1.5 1.5L7 5"), .path("M3 12l1.5 1.5L7 11"),
       .path("M3 18l1.5 1.5L7 17")]
    case .copy: [.rect(9, 9, 12, 12, rx: 2), .path("M5 15V5a2 2 0 0 1 2-2h10")]
    case .download: [.path("M12 3v12M7 10l5 5 5-5M5 21h14")]
    case .pencil: [.path("M12 20h9"), .path("M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z")]
    case .trash: [.path("M3 6h18M8 6V4h8v2M6 6l1 14h10l1-14")]
    case .speaker: [.path("M11 5 6 9H2v6h4l5 4z"), .path("M15.5 8.5a5 5 0 0 1 0 7")]
    case .file:
      [.path("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"), .path("M14 2v6h6")]
    case .fileNew:
      [.path("M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"), .path("M14 2v6h6M12 12v6M9 15h6")]
    case .play: [.path("M6 4l14 8-14 8z")]
    case .arrowLeft: [.path("M19 12H5M12 19l-7-7 7-7")]
    case .reply: [.path("M9 17 4 12l5-5"), .path("M20 18v-2a4 4 0 0 0-4-4H4")]
    case .spinner: [.path("M21 12a9 9 0 1 1-6.2-8.6")]
    case .circle: [.circle(12, 12, 8)]
    case .pause: [.path("M9 5v14M15 5v14")]
    case .split: [.rect(3, 4, 18, 16, rx: 2), .path("M12 4v16")]
    case .lock: [.rect(3, 11, 18, 11, rx: 2), .path("M7 11V7a5 5 0 0 1 10 0v4")]
    case .window: [.rect(2, 4, 20, 16, rx: 2), .path("M10 4v4"), .path("M2 8h20"), .path("M6 4v4")]
    case .mic: [.path("M12 19v3"), .path("M19 10v2a7 7 0 0 1-14 0v-2"), .rect(9, 2, 6, 13, rx: 3)]
    case .layers: [.path("M12 2 2 7l10 5 10-5z"), .path("m2 17 10 5 10-5"), .path("m2 12 10 5 10-5")]
    case .eye:
      [.path("M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0"),
       .circle(12, 12, 3)]
    case .eyeOff:
      [.path("M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49"),
       .path("M14.084 14.158a3 3 0 0 1-4.242-4.242"),
       .path("M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143"),
       .path("m2 2 20 20")]
    case .folder:
      [.path("M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z")]
    // A prompt with a menu under its cursor: the terminal's suggestions.
    case .suggest: [.path("m3 4 4 3.5-4 3.5"), .path("M10 11h4"), .rect(8, 14, 13, 7, rx: 2), .path("M11 17.5h7")]
    case .chart: [.path("M3 3v18h18"), .path("m7 15 4-4 3 3 5-6")]
    case .star: [.path("m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z")]
    case .person: [.circle(12, 7, 4), .path("M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2")]
    case .globe: // Lucide "globe"
      [.circle(12, 12, 10), .path("M12 2a14.5 14.5 0 0 0 0 20a14.5 14.5 0 0 0 0 -20"), .path("M2 12h20")]
    case .more: // Lucide "ellipsis"
      [.circle(12, 12, 1), .circle(19, 12, 1), .circle(5, 12, 1)]
    case .plug: // Lucide "plug"
      [.path("M12 22v-5"), .path("M9 8V2"), .path("M15 8V2"), .path("M18 8v5a4 4 0 0 1-4 4h-4a4 4 0 0 1-4-4V8Z")]
    case .maximize: // Lucide "maximize-2"
      [.path("M15 3h6v6"), .path("m21 3-7 7"), .path("m3 21 7-7"), .path("M9 21H3v-6")]
    case .minimize: // Lucide "minimize-2"
      [.path("m14 10 7-7"), .path("M20 10h-6V4"), .path("m3 21 7-7"), .path("M4 14h6v6")]
    }
  }
}
