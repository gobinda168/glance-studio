import AppKit
#if canImport(GlanceCore)
import GlanceCore
#endif
import SwiftUI

// Home, Glance Studio's start tab: a session log. Time is the axis: what is live now sits at the lit head of one
// hairline spine (Claude's orb inside the plan dial), and every recent project hangs below it by how long ago you left
// it. Built on design-system/glance/MASTER.md; the page's own rules are in design-system/glance/pages/home.md.

/// What Home shows, whether it is on screen, and where its actions go. The tab's window controller pushes a new
/// state whenever something on it changes.
@MainActor
public final class HomeModel: ObservableObject {
  @Published public private(set) var state: HomeState
  /// A first real state has arrived: until then Home shows only its ground, so nothing flashes empty.
  @Published public private(set) var isReady = false
  /// The tab is in front in a window on screen. Loops and the "seen" clock run only then.
  @Published public var isActive = false {
    didSet { if isActive != oldValue { armSeen() } }
  }
  /// Recent projects worth pointing out (`HomeState.news`), by path. Each clears once seen: hovered, focused, or on
  /// screen for a few seconds.
  @Published private(set) var news: Set<String> = []
  /// Bumped to put keyboard focus on the page, so ⏎ and Esc work without a click.
  @Published private(set) var focusRequest = 0
  public var onAction: ((HomeAction) -> Void)?

  private var seenTask: Task<Void, Never>?

  public init(state: HomeState? = nil) {
    self.state = state ?? HomeState(version: "", greetingName: nil, showAtLaunch: true, editorName: "Razor Code",
                                    paneOpen: false, folder: nil, claude: .idle, usage: nil, recent: [])
    isReady = state != nil
  }

  public func push(_ new: HomeState) {
    guard new != state || !isReady else { return }
    // The first list is the baseline: nothing in it is news.
    if isReady { news.formUnion(HomeState.news(from: state.recent, to: new.recent)) }
    news.formIntersection(new.recent.map(\.path))
    state = new
    isReady = true
    armSeen()
  }

  public func requestFocus() { focusRequest += 1 }

  func perform(_ action: HomeAction) {
    if case .setShowAtLaunch(let on) = action { state.showAtLaunch = on } // the switch moves now, not on the next push
    onAction?(action)
  }

  func seen(_ path: String) {
    if news.contains(path) { news.remove(path) }
  }

  private func armSeen() {
    seenTask?.cancel()
    seenTask = nil
    guard isActive, !news.isEmpty else { return }
    seenTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.news.removeAll()
    }
  }
}

/// The Home page: it scrolls when the window is short, and keeps the footer at the bottom when it isn't.
public struct HomeView: View {
  @ObservedObject var model: HomeModel

  public init(model: HomeModel) { self.model = model }

  public var body: some View {
    GeometryReader { proxy in
      ScrollView(.vertical) {
        HomeContent(model: model, layout: HomeLayout(size: proxy.size))
          .frame(maxWidth: .infinity)
          .frame(minHeight: proxy.size.height)
      }
      .scrollIndicators(.automatic)
    }
    .background(GlanceColor.ground)
  }
}

// MARK: - Layout

/// Sizes that follow the page's width (600 to 1800 wide; the content caps at 1240).
struct HomeLayout {
  let size: CGSize

  var width: CGFloat { size.width }
  var compact: Bool { width < 640 }
  /// From 1280 wide the dial and the greeting grow, so a big window is not one small instrument in a field.
  var wide: Bool { width >= 1280 }
  var pad: CGFloat { min(max(width * 0.032, 16), 44) }
  var top: CGFloat { min(max(size.height * 0.05, 24), 52) }
  var content: CGFloat { min(width, 1240) - 2 * pad }
  var showRail: Bool { width >= 900 }
  var railWidth: CGFloat { width >= 1100 ? 248 : 232 }
  var railGap: CGFloat { min(max(width * 0.04, 28), 56) }
  /// The dial's size; the spine runs down its centre.
  var dial: CGFloat { compact ? 64 : wide ? 96 : 80 }
  var gap: CGFloat { compact ? 16 : 24 }
  /// The shared left edge of the greeting, the readout, the actions, the ages and the headings.
  var edge: CGFloat { dial + gap }
  var spineX: CGFloat { dial / 2 }
  var log: CGFloat { content - (showRail ? railWidth + railGap : 0) }
  var actionColumns: Int { log - edge >= 820 ? 4 : 2 }
  /// A narrow log puts the path under the name.
  var stackedRows: Bool { log - edge + 12 < 520 }
  var rowHeight: CGFloat { stackedRows ? 54 : 44 }
  var greeting: CGFloat { compact ? 26 : wide ? 34 : 30 }
}

enum HomeFocus: Hashable {
  case page
  case row(String)
}

// MARK: - The page

struct HomeContent: View {
  @ObservedObject var model: HomeModel
  let layout: HomeLayout
  @State private var arrived: Bool
  @FocusState private var focus: HomeFocus?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// `arrived` skips the arrival (an offscreen render, which never appears).
  init(model: HomeModel, layout: HomeLayout, arrived: Bool = false) {
    self.model = model
    self.layout = layout
    _arrived = State(initialValue: arrived)
  }

  private var state: HomeState { model.state }
  /// Loops and timers run only while someone can see them.
  private var live: Bool { model.isActive && !reduceMotion }

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: layout.railGap) {
        log
        if layout.showRail { ShortcutsRail(columns: 0).frame(width: layout.railWidth).arrival(arrived, delay: 0.24, reduceMotion) }
      }
      .padding(.top, layout.top)
      if !layout.showRail {
        let inset = layout.compact ? 0 : layout.edge
        ShortcutsRail(columns: max(1, min(3, Int((layout.content - inset + 32) / 222))))
          .padding(.top, 30)
          .padding(.leading, inset)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Spacer(minLength: 28)
      Footer(state: state, compact: layout.compact, perform: model.perform)
    }
    .frame(width: layout.content)
    .opacity(model.isReady ? 1 : 0)
    .focusable()
    .focused($focus, equals: .page)
    .focusEffectDisabled()
    .onKeyPress(keys: [.return, .escape, .upArrow, .downArrow], phases: .down, action: key)
    .onChange(of: model.focusRequest) { _, _ in focus = .page }
    .onChange(of: model.isReady) { _, ready in if ready { arrive() } }
    .onAppear { if model.isReady { arrive() } }
  }

  /// The now section and the log, on one spine.
  private var log: some View {
    VStack(alignment: .leading, spacing: 0) {
      NowSection(state: state, layout: layout, arrived: arrived, live: live, perform: model.perform)
        .padding(.bottom, 30)
      RecentSection(state: state, news: model.news, layout: layout, arrived: arrived, focus: $focus,
                    perform: model.perform, seen: model.seen)
    }
    .frame(width: layout.log, alignment: .leading)
    .backgroundPreferenceValue(SpineAnchors.self) { anchors in
      GeometryReader { proxy in
        Spine(anchors: anchors, proxy: proxy, x: layout.spineX, drawn: arrived, reduceMotion: reduceMotion)
      }
    }
  }

  private func arrive(animated: Bool = true) {
    guard !arrived else { return }
    if animated && model.isActive && !reduceMotion {
      arrived = true // each part animates on its own delay (`arrival`)
    } else {
      var quiet = Transaction()
      quiet.disablesAnimations = true
      withTransaction(quiet) { arrived = true }
    }
  }

  private func key(_ press: KeyPress) -> KeyPress.Result {
    let rows = state.recent.map(\.path)
    switch press.key {
    case .return:
      if case .row(let path)? = focus {
        model.perform(.openProject(path: path, target: press.modifiers.contains(.option) ? .editor : .terminal))
        return .handled
      }
      guard focus == .page, press.modifiers.isEmpty else { return .ignored } // a focused button keeps its Return
      model.perform(.focusTerminal)
      return .handled
    case .escape:
      if case .row? = focus { focus = .page; return .handled }
      guard focus == .page else { return .ignored }
      model.perform(.focusTerminal)
      return .handled
    case .downArrow, .upArrow:
      guard !rows.isEmpty else { return .ignored }
      let step = press.key == .downArrow ? 1 : -1
      if case .row(let path)? = focus, let index = rows.firstIndex(of: path) {
        let next = index + step
        focus = next < 0 ? .page : .row(rows[min(next, rows.count - 1)])
      } else if step > 0 {
        focus = .row(rows[0])
      }
      return .handled
    default:
      return .ignored
    }
  }
}

// MARK: - Now

private struct NowSection: View {
  let state: HomeState
  let layout: HomeLayout
  let arrived: Bool
  let live: Bool
  let perform: (HomeAction) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(alignment: .top, spacing: layout.gap) {
      Dial(claude: state.claude, usage: state.usage, size: layout.dial, arrived: arrived, live: live)
        .anchorPreference(key: SpineAnchors.self, value: .bounds) { [.dial: $0] }
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 8) {
          Greeting(name: state.greetingName, size: layout.greeting, live: live)
          ClaudeLine(status: state.claude)
        }
        .padding(.top, layout.compact ? 4 : 8)
        .arrival(arrived, delay: 0, reduceMotion)
        Readout(usage: state.usage, folder: state.folder, width: layout.log - layout.edge)
          .padding(.top, 4)
          .arrival(arrived, delay: 0.04, reduceMotion)
        // While Claude thinks, the orb is the page's motion; the glow ring holds still (MASTER §6: orb + one ring).
        ActionGrid(state: state, columns: layout.actionColumns, live: live && state.claude != .thinking, perform: perform)
          .padding(.top, 6)
          .arrival(arrived, delay: 0.08, reduceMotion)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct Greeting: View {
  let name: String?
  let size: CGFloat
  let live: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // The hour can turn while Home is on screen: one tick a minute, only while someone is looking. The clock is read
    // fresh each time, so a tick that resumes late still greets the right part of the day.
    TimelineView(.animation(minimumInterval: 60, paused: !live)) { _ in
      let text = Self.text(at: Date(), name: name)
      ZStack(alignment: .topLeading) {
        Text(text)
          .font(GlanceFont.sans(size, .semibold))
          .tracking(-0.02 * size)
          .foregroundStyle(GlanceColor.ink)
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)
          .id(text)
          .transition(.blurSwap(reduceMotion))
      }
      .animation(reduceMotion ? .linear(duration: 0.16) : .easeOut(duration: 0.24), value: text)
    }
  }

  static func text(at date: Date, name: String?) -> String {
    let hour = Calendar.current.component(.hour, from: date)
    let part = hour < 5 ? "night" : hour < 12 ? "morning" : hour < 17 ? "afternoon" : hour < 22 ? "evening" : "night"
    return "Good \(part)" + (name.map { ", \($0)" } ?? "") + "."
  }
}

private struct ClaudeLine: View {
  let status: TabStatusBook.Status
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // A new state changes the line in place with a blur-swap (MASTER §6), not a jump.
    ZStack(alignment: .topLeading) {
      Self.line(status)
        .lineLimit(2)
        .id(status)
        .transition(.blurSwap(reduceMotion))
    }
    .animation(reduceMotion ? .linear(duration: 0.16) : .easeOut(duration: 0.24), value: status)
  }

  static func line(_ status: TabStatusBook.Status) -> Text {
    let (lead, word, tail, after): (String, String, String, String) = switch status {
    case .idle: ("Claude is ", "idle", ".", "Ready when you are.")
    case .thinking: ("Claude is ", "thinking", ".", "Working on a reply.")
    case .finished: ("Claude ", "finished", " a reply.", "Read it in the Glance pane.")
    }
    let tint = switch status {
    case .idle: GlanceColor.coralInk
    case .thinking: GlanceColor.tealInk
    case .finished: GlanceColor.okInk
    }
    return Text(lead).font(GlanceFont.sans(14)).foregroundStyle(GlanceColor.body)
      + Text(word).font(GlanceFont.sans(14, .semibold)).foregroundStyle(tint)
      + Text(tail).font(GlanceFont.sans(14)).foregroundStyle(GlanceColor.body)
      + Text(" " + after).font(GlanceFont.sans(14)).foregroundStyle(GlanceColor.muted)
  }
}

/// MASTER's swap for content replaced in place: the new arrives from 5 points below through a 3-point blur, the old
/// fades. A plain fade under Reduce Motion. The update toast swaps its words with it too.
struct BlurSwap: ViewModifier {
  let away: Bool

  func body(content: Content) -> some View {
    content
      .opacity(away ? 0 : 1)
      .offset(y: away ? 5 : 0)
      .blur(radius: away ? 3 : 0)
  }
}

extension AnyTransition {
  static func blurSwap(_ reduceMotion: Bool) -> AnyTransition {
    reduceMotion ? .opacity : .asymmetric(insertion: .modifier(active: BlurSwap(away: true), identity: BlurSwap(away: false)),
                                          removal: .opacity)
  }
}

// MARK: - The dial

/// Claude's orb inside the plan dial: 60 ticks from twelve o'clock, lit for the 5-hour window, and a fine inner arc
/// for the week, both in teal, amber from 70%, red from 90%. It heads the spine: this is now.
private struct Dial: View {
  let claude: TabStatusBook.Status
  let usage: HomeState.Usage?
  let size: CGFloat
  let arrived: Bool
  let live: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let unit = size / 80
    let five = usage?.fiveHour, week = usage?.sevenDay
    let lit = arrived ? Double(five?.percent ?? 0) / 100 * 60 : 0
    let weekShown = arrived ? Double(week?.percent ?? 0) / 100 : 0
    let tick = Color.primary.opacity(0.15), major = Color.primary.opacity(0.3)
    ZStack {
      TickRing(lit: lit, part: .unlitMinor).stroke(tick, style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round))
      TickRing(lit: lit, part: .unlitMajor).stroke(major, style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round))
      TickRing(lit: lit, part: .lit).stroke(tint(five), style: StrokeStyle(lineWidth: 1.6 * unit, lineCap: .round))
      Circle()
        .stroke(tick, lineWidth: 1 * unit)
        .frame(width: 48 * unit, height: 48 * unit)
      Circle()
        .trim(from: 0, to: weekShown)
        .stroke(tint(week), style: StrokeStyle(lineWidth: 1.5 * unit, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .frame(width: 48 * unit, height: 48 * unit)
        .opacity(week == nil ? 0 : 1)
      Orb(status: claude, size: 36 * unit, live: live)
    }
    .frame(width: size, height: size)
    .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.62).delay(0.26), value: arrived)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: usage)
    .help(Self.help(usage))
    .accessibilityHidden(true) // the readout says the same in words
  }

  private func tint(_ window: HomeState.Usage.Window?) -> Color {
    switch window?.severity {
    case .warn: GlanceColor.warn
    case .critical: GlanceColor.critical
    default: GlanceColor.teal
    }
  }

  static func help(_ usage: HomeState.Usage?) -> String {
    guard let usage else { return "Plan usage shows here once Claude Code reports it" }
    var parts: [String] = []
    if let five = usage.fiveHour { parts.append("Ticks: 5-hour window, \(five.percent)% used") }
    if let week = usage.sevenDay { parts.append("inner ring: week, \(week.percent)% used") }
    return parts.joined(separator: "; ")
  }
}

/// One part of the dial's 60 ticks, so lit and unlit ones take different colours. `lit` animates: as it rises, the
/// ticks light one after another.
private struct TickRing: Shape {
  enum Part { case lit, unlitMinor, unlitMajor }
  var lit: Double
  let part: Part

  var animatableData: Double {
    get { lit }
    set { lit = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let center = CGPoint(x: rect.midX, y: rect.midY), unit = rect.width / 80, shown = Int(lit.rounded())
    var path = Path()
    for index in 0..<60 {
      let isLit = index < shown, isMajor = index % 5 == 0
      switch part {
      case .lit: guard isLit else { continue }
      case .unlitMinor: guard !isLit, !isMajor else { continue }
      case .unlitMajor: guard !isLit, isMajor else { continue }
      }
      let angle = Double(index) / 60 * 2 * .pi - .pi / 2
      let inner = (isMajor ? 30.5 : 32.5) * unit, outer = 37.5 * unit
      path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
      path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
    }
    return path
  }
}

/// Glance's presence (MASTER §7.2): a lit sphere whose colour is Claude's state. Idle breathes slowly; thinking
/// breathes faster with three lights orbiting; finished shows a check. Still under Reduce Motion and off screen.
private struct Orb: View {
  let status: TabStatusBook.Status
  let size: CGFloat
  let live: Bool

  private var colors: (hi: Color, mid: Color, lo: Color, glow: Color) {
    switch status {
    case .idle: (GlanceColor.rgb(0xFFB99E), GlanceColor.coral, GlanceColor.rgb(0x8E2F12), GlanceColor.coral.opacity(0.5))
    case .thinking: (GlanceColor.rgb(0xA6E6E9), GlanceColor.teal, GlanceColor.rgb(0x0F4448), GlanceColor.teal.opacity(0.55))
    case .finished: (GlanceColor.rgb(0xA7F0B5), GlanceColor.ok, GlanceColor.rgb(0x0F4D1E), GlanceColor.ok.opacity(0.45))
    }
  }

  var body: some View {
    let colors = colors
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live || status == .finished)) { context in
      let time = context.date.timeIntervalSinceReferenceDate
      let period = status == .thinking ? 1.4 : 4
      let breath = live && status != .finished ? 0.5 - 0.5 * cos(2 * .pi * time / period) : 0
      ZStack {
        Circle()
          .fill(RadialGradient(colors: [colors.glow, .clear], center: .center, startRadius: 0, endRadius: size * 0.84))
          .frame(width: size * 1.68, height: size * 1.68)
          .scaleEffect(1 - 0.08 * breath)
          .opacity(1 - 0.45 * breath)
        if status == .thinking {
          OrbitLights(size: size, turn: live ? time.truncatingRemainder(dividingBy: 2.2) / 2.2 : 0)
            .transition(.opacity)
        }
        Circle()
          .fill(RadialGradient(colors: [colors.hi, colors.mid, colors.lo], center: UnitPoint(x: 0.36, y: 0.3),
                               startRadius: 0, endRadius: size * 0.62))
          .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
          .overlay(alignment: .topLeading) {
            Ellipse()
              .fill(RadialGradient(colors: [.white.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: size * 0.2))
              .frame(width: size * 0.4, height: size * 0.26)
              .offset(x: size * 0.18, y: size * 0.1)
          }
          .frame(width: size, height: size)
        if status == .finished {
          Image(systemName: "checkmark")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
      }
    }
    .frame(width: size, height: size)
    .animation(.easeInOut(duration: 0.6), value: status)
  }
}

private struct OrbitLights: View {
  let size: CGFloat
  let turn: Double

  var body: some View {
    let radius = size * 0.62
    ZStack {
      ForEach(0..<3, id: \.self) { index in
        let angle = (turn + Double(index) / 3) * 2 * .pi
        Circle()
          .fill(GlanceColor.rgb(0x8FD9DC))
          .frame(width: size * [0.12, 0.09, 0.07][index], height: size * [0.12, 0.09, 0.07][index])
          .opacity([1, 0.7, 0.45][index])
          .offset(x: radius * cos(angle), y: radius * sin(angle))
      }
    }
  }
}

// MARK: - The readout

/// The 5-hour window, the week and the folder in front, split by hairlines; the folder takes its own line below 700
/// points.
private struct Readout: View {
  let usage: HomeState.Usage?
  let folder: HomeState.Folder?
  let width: CGFloat

  var body: some View {
    if width >= 700 {
      HStack(alignment: .top, spacing: 0) {
        usageCells
        if let folder {
          Hairline()
          FolderCell(folder: folder).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 0) { usageCells }.fixedSize(horizontal: false, vertical: true)
        if let folder { FolderCell(folder: folder) }
      }
    }
  }

  @ViewBuilder private var usageCells: some View {
    if let usage {
      UsageCell(label: "5-hour window", window: usage.fiveHour)
      Hairline()
      UsageCell(label: "Week", window: usage.sevenDay)
    } else {
      Cell(label: "Plan usage") {
        Text("Shows here once Claude Code reports it")
          .font(GlanceFont.sans(12.5))
          .foregroundStyle(GlanceColor.muted)
      }
    }
  }
}

private struct Hairline: View {
  var body: some View {
    Rectangle()
      .fill(Color.primary.opacity(0.09))
      .frame(width: 1)
      .padding(.horizontal, 20)
      .accessibilityHidden(true)
  }
}

private struct Cell<Value: View>: View {
  let label: String
  @ViewBuilder let value: Value

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(GlanceFont.sans(11.5, .medium))
        .foregroundStyle(GlanceColor.muted)
      value
    }
    .accessibilityElement(children: .combine)
  }
}

private struct UsageCell: View {
  let label: String
  let window: HomeState.Usage.Window?

  /// "2h 46m": the figures in mono, the space between them in the sans. Every JetBrains Mono space is a whole character
  /// wide, thin ones too, and splits the countdown in two.
  @MainActor static func countdown(_ text: String) -> Text {
    text.split(separator: " ").enumerated().reduce(Text("")) { line, part in
      let figure = Text(String(part.element)).font(GlanceFont.mono(12))
      return part.offset == 0 ? line + figure : line + Text(" ").font(GlanceFont.sans(12)) + figure
    }
  }

  var body: some View {
    let (ink, flag): (Color, String?) = switch window?.severity {
    case .warn: (GlanceColor.warnInk, "High")
    case .critical: (GlanceColor.criticalInk, "Near limit")
    default: (GlanceColor.ink, nil)
    }
    Cell(label: label) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(window.map { "\($0.percent)%" } ?? "–")
          .font(GlanceFont.mono(15, .semibold))
          .monospacedDigit()
          .foregroundStyle(ink)
          .contentTransition(.numericText(value: Double(window?.percent ?? 0)))
        if let flag {
          Text(flag)
            .font(GlanceFont.sans(11, .semibold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink.opacity(0.14)))
        }
        // Words in the sans, the countdown in mono: mono is for the data, not for the sentence.
        Group {
          if let window {
            Text("resets in ").font(GlanceFont.sans(12.5)) + Self.countdown(window.resets)
          } else {
            Text("No data yet").font(GlanceFont.sans(12.5))
          }
        }
        .foregroundStyle(GlanceColor.muted)
        .lineLimit(1)
      }
    }
  }
}

private struct FolderCell: View {
  let folder: HomeState.Folder

  var body: some View {
    Cell(label: "Folder") {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(folder.display)
          .font(GlanceFont.mono(13, .medium))
          .foregroundStyle(GlanceColor.ink)
          .lineLimit(1)
          .truncationMode(.head)
          .textSelection(.enabled)
        // The count stays whole, a long branch stops at 220 points, and the path gives way first.
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let branch = folder.branch {
            Capped(max: 220) { BranchChip(branch, size: 12) }
          }
          if let changes = folder.changes {
            if changes == 0 {
              Label("Clean", systemImage: "checkmark")
                .labelStyle(TightLabel())
                .font(GlanceFont.sans(12.5, .medium))
                .foregroundStyle(GlanceColor.okInk)
            } else {
              (Text("\(changes)").font(GlanceFont.mono(12, .medium)) + Text(" changed").font(GlanceFont.sans(12.5)))
                .foregroundStyle(GlanceColor.body)
            }
          }
          if folder.branch == nil && folder.changes == nil {
            Text("Not a git repository")
              .font(GlanceFont.sans(12.5))
              .foregroundStyle(GlanceColor.muted)
          }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
      }
    }
    .help("The folder of the terminal in front")
  }
}

private struct TightLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      configuration.icon.imageScale(.small)
      configuration.title
    }
  }
}

// MARK: - Actions

private struct ActionGrid: View {
  let state: HomeState
  let columns: Int
  let live: Bool
  let perform: (HomeAction) -> Void

  var body: some View {
    let open = state.paneOpen
    let actions: [Action] = [
      Action(title: "New terminal", glyph: .symbol("apple.terminal"), keys: ["⌘", "T"],
             help: "New terminal tab (⌘T)", action: .newTerminal),
      Action(title: "New editor", glyph: .symbol("chevron.left.forwardslash.chevron.right"), keys: ["⇧", "⌘", "E"],
             help: "New \(state.editorName) tab (⇧⌘E)", action: .newEditor),
      Action(title: open ? "Close Glance" : "Open Glance", glyph: .orb, keys: ["⌥", "Space"],
             help: open ? "Close the Glance pane (⌥Space)" : "Open the Glance pane (⌥Space)", action: .toggleGlance,
             lit: !open),
      Action(title: "Settings", glyph: .symbol("gearshape"), keys: [], help: "Glance Settings", action: .settings),
    ]
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      ForEach(Array(stride(from: 0, to: actions.count, by: columns)), id: \.self) { start in
        GridRow {
          ForEach(actions[start..<min(start + columns, actions.count)]) { action in
            ActionButton(action: action, live: live) { perform(action.action) }
          }
        }
      }
    }
  }

  struct Action: Identifiable {
    enum Glyph { case symbol(String), orb }
    let title: String
    let glyph: Glyph
    let keys: [String]
    let help: String
    let action: HomeAction
    var lit = false
    var id: String { help }
  }
}

private struct ActionButton: View {
  let action: ActionGrid.Action
  let live: Bool
  let run: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: run) {
      HStack(spacing: 10) {
        switch action.glyph {
        case .symbol(let name):
          Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
            .frame(width: 20)
        case .orb:
          Circle()
            .fill(RadialGradient(colors: [GlanceColor.rgb(0xFFC2A6), GlanceColor.coral, GlanceColor.coralLo],
                                 center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 7))
            .frame(width: 12, height: 12)
            .frame(width: 20)
        }
        Text(action.title)
          .font(GlanceFont.sans(13, .semibold))
          .lineLimit(1)
        Spacer(minLength: 6)
        if !action.keys.isEmpty { KeyCaps(keys: action.keys) }
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity, minHeight: 42)
      .contentShape(Rectangle())
    }
    .buttonStyle(HomeButtonStyle(lit: action.lit, live: live))
    .onHover { hovering = $0 }
    .help(action.help)
    .accessibilityLabel(action.title)
  }
}

/// Home's buttons: a raised graphite face with a hairline and a lit top edge; hover brightens it, a press presses it.
/// `lit` swaps the face for MASTER's glow ring: an aurora border that turns once every 3 seconds over a soft halo of
/// the same light. The ring stands still under Reduce Motion and while Home is off screen.
struct HomeButtonStyle: ButtonStyle {
  var lit = false
  var live = false
  var radius: CGFloat = 8

  func makeBody(configuration: Configuration) -> some View {
    HomeButton(configuration: configuration, style: self)
  }
}

private struct HomeButton: View {
  let configuration: ButtonStyleConfiguration
  let style: HomeButtonStyle
  @State private var hovering = false
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
    let dark = scheme == .dark
    configuration.label
      .foregroundStyle(GlanceColor.ink)
      .background {
        if style.lit {
          shape.fill(GlanceColor.solid)
        } else {
          shape.fill(dark ? Color.white.opacity(configuration.isPressed ? 0.1 : hovering ? 0.065 : 0.035)
                          : Color.white.opacity(configuration.isPressed ? 0.45 : hovering ? 0.85 : 0.62))
        }
      }
      .overlay {
        if style.lit {
          GlowLight(shape: shape, live: style.live && !reduceMotion, part: .ring)
        } else {
          shape.strokeBorder(Color.primary.opacity(hovering ? 0.16 : 0.09), lineWidth: 1)
          shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.07 : 0.9), .clear],
                                            startPoint: .top, endPoint: .center), lineWidth: 1)
        }
      }
      .background {
        if style.lit {
          GlowLight(shape: shape, live: style.live && !reduceMotion, part: .halo, bright: hovering)
            .padding(-3)
        }
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(.easeOut(duration: 0.16), value: hovering)
      .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
      .onHover { hovering = $0 }
  }
}

/// The glow ring's light, as a 1.5-point ring or as the blurred halo behind it, turning on the same clock. Home's glowing
/// buttons and the meeting nudge's Join use it.
struct GlowLight<S: InsettableShape>: View {
  enum Part { case ring, halo }
  let shape: S
  let live: Bool
  let part: Part
  var bright = false

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
      let turn = live ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 : 0.12
      let light = AngularGradient(colors: GlanceColor.aurora, center: .center, angle: .degrees(turn * 360))
      switch part {
      case .ring:
        shape.strokeBorder(light, lineWidth: 1.5)
      case .halo:
        shape.fill(light).blur(radius: 8).opacity(bright ? 0.7 : 0.42)
      }
    }
    .allowsHitTesting(false)
  }
}

/// Keys as small raised caps: ⌘ ⌥ ⇧ ⏎ glyphs, never words (except Space).
private struct KeyCaps: View {
  let keys: [String]
  var small = false
  @Environment(\.colorScheme) private var scheme

  /// Key glyphs JetBrains Mono doesn't draw, which the system face draws as macOS menus do.
  private static let glyphs: Set<String> = ["⌘", "⇧", "⌥", "⌃", "⏎", "↑", "↓", "←", "→", "⎋"]

  /// Letters and words in JetBrains Mono (MASTER: mono for keys); the modifier glyphs in SF.
  @MainActor static func face(_ key: String, size: CGFloat) -> Font {
    glyphs.contains(key) ? .system(size: size, weight: .medium) : GlanceFont.mono(size, .medium)
  }

  var body: some View {
    let dark = scheme == .dark
    let cap = RoundedRectangle(cornerRadius: 5, style: .continuous)
    HStack(spacing: 3) {
      ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
        Text(key)
          .font(Self.face(key, size: key.count > 1 ? (small ? 10 : 11) : (small ? 10.5 : 11.5)))
          .foregroundStyle(GlanceColor.body)
          .padding(.horizontal, key.count > 1 ? 7 : 4)
          .frame(minWidth: small ? 18 : 20, minHeight: small ? 18 : 20)
          .background(cap.fill(dark ? Color.white.opacity(0.06) : Color.white.opacity(0.9)))
          .overlay(cap.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1))
          .background(cap.fill(dark ? Color.black.opacity(0.5) : Color.black.opacity(0.14)).offset(y: 1)) // the cap's edge
      }
    }
    .accessibilityHidden(true)
  }
}

// MARK: - Recent projects

private struct RecentSection: View {
  let state: HomeState
  let news: Set<String>
  let layout: HomeLayout
  let arrived: Bool
  var focus: FocusState<HomeFocus?>.Binding
  let perform: (HomeAction) -> Void
  let seen: (String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let recent = state.recent
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("Recent projects")
          .font(GlanceFont.sans(13, .semibold))
          .foregroundStyle(GlanceColor.ink)
        if !recent.isEmpty {
          Text("\(recent.count)")
            .font(GlanceFont.mono(12, .medium))
            .foregroundStyle(GlanceColor.muted)
        }
      }
      .padding(.leading, layout.edge)
      .padding(.bottom, 4)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      .arrival(arrived, delay: 0.12, reduceMotion)
      if recent.isEmpty {
        EmptyLog()
          .padding(.leading, layout.edge)
          .padding(.top, 4)
          .anchorPreference(key: SpineAnchors.self, value: .bounds) { [.empty: $0] }
          .arrival(arrived, delay: 0.16, reduceMotion)
      } else {
        VStack(spacing: 0) {
          ForEach(Array(recent.enumerated()), id: \.element.path) { index, project in
            ProjectRow(project: project, editorName: state.editorName, isNews: news.contains(project.path),
                       layout: layout, focus: focus, perform: perform, seen: { seen(project.path) })
              .anchorPreference(key: SpineAnchors.self, value: .bounds) { anchor in
                var points: [SpinePoint: Anchor<CGRect>] = [:]
                if index == 0 { points[.firstRow] = anchor }
                if index == recent.count - 1 { points[.lastRow] = anchor }
                return points
              }
              .arrival(arrived, delay: 0.16 + Double(index) * 0.046, reduceMotion, slide: true)
              .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: recent.map(\.path))
        if recent.count <= 5 {
          HomeKeyHint()
            .padding(.leading, layout.edge)
            .padding(.top, 14)
        }
      }
    }
  }
}

private struct ProjectRow: View {
  let project: HomeState.Project
  let editorName: String
  let isNews: Bool
  let layout: HomeLayout
  var focus: FocusState<HomeFocus?>.Binding
  let perform: (HomeAction) -> Void
  let seen: () -> Void
  @State private var hovering = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var focused: Bool { focus.wrappedValue == .row(project.path) }

  var body: some View {
    let lit = hovering || focused
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    ZStack(alignment: .leading) {
      // On the spine: the row's tick and, just right of it, its age. Both go coral while the row is news; under the
      // pointer the tick lights and the age brightens.
      Rectangle()
        .fill(lit || isNews ? GlanceColor.coral : Color.primary.opacity(0.36))
        .frame(width: 10, height: 1)
        .scaleEffect(x: lit && !reduceMotion ? 1.4 : 1)
        .offset(x: layout.spineX - 5)
        .accessibilityHidden(true)
      Text(project.shortAge)
        .font(GlanceFont.mono(11.5, .medium))
        .foregroundStyle(isNews ? GlanceColor.coralInk : lit ? GlanceColor.ink : GlanceColor.muted)
        .lineLimit(1)
        .frame(width: max(20, layout.edge - layout.spineX - 24), alignment: .leading)
        .offset(x: layout.spineX + 10)
      content(lit: lit)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shape.fill(Color.primary.opacity(lit ? 0.065 : 0)))
        .overlay { if focused { shape.strokeBorder(GlanceColor.coral, lineWidth: 2) } }
        .overlay(alignment: .trailing) {
          if lit {
            HStack(spacing: 4) {
              RowButton(symbol: "apple.terminal", help: "Open in a terminal (⏎)") {
                perform(.openProject(path: project.path, target: .terminal))
              }
              RowButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Open in \(editorName) (⌥⏎)") {
                perform(.openProject(path: project.path, target: .editor))
              }
            }
            .padding(.trailing, 8)
            .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 4)))
          }
        }
        .padding(.leading, layout.edge - 12)
    }
    .frame(height: layout.rowHeight)
    .contentShape(Rectangle())
    .onTapGesture { perform(.openProject(path: project.path, target: .terminal)) }
    .onHover { inside in
      hovering = inside
      if inside { seen() }
    }
    .focusable()
    .focused(focus, equals: .row(project.path))
    .focusEffectDisabled()
    .onChange(of: focused) { _, now in if now { seen() } }
    .animation(.easeOut(duration: 0.16), value: lit)
    .animation(.easeOut(duration: 0.16), value: isNews)
    .help(project.display)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(project))
    .accessibilityAddTraits(.isButton)
    .accessibilityAction { perform(.openProject(path: project.path, target: .terminal)) }
    .accessibilityAction(named: "Open in \(editorName)") { perform(.openProject(path: project.path, target: .editor)) }
  }

  @ViewBuilder private func content(lit: Bool) -> some View {
    let name = Text(project.name)
      .font(GlanceFont.sans(13.5, .semibold))
      .foregroundStyle(GlanceColor.ink)
      .lineLimit(1)
    let path = Text(project.display)
      .font(GlanceFont.mono(12))
      .foregroundStyle(GlanceColor.muted)
      .lineLimit(1)
      .truncationMode(.head)
    let branch = project.branch.map { BranchChip($0, size: 12).opacity(lit ? 0 : 1) }
    if layout.stackedRows {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) { name; path }
          .frame(maxWidth: .infinity, alignment: .leading)
        Capped(max: 140) { branch }.layoutPriority(1)
      }
    } else {
      // The name and the branch keep their own width (up to a cap); the path takes what is left and loses its start.
      HStack(spacing: 14) {
        Capped(max: 240) { name }.layoutPriority(2)
        path.frame(maxWidth: .infinity, alignment: .leading)
        Capped(max: 200) { branch }.layoutPriority(1)
      }
    }
  }

  static func spoken(_ project: HomeState.Project) -> String {
    ([project.name, project.display, project.branch.map { "on \($0)" }, project.when] as [String?])
      .compactMap { $0 }.joined(separator: ", ")
  }
}

/// Its content at its natural width, but never wider than `max`: a column that shrinks for short names and
/// truncates long ones, without taking room it doesn't need.
private struct Capped: Layout {
  let max: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let view = subviews.first else { return .zero }
    return view.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? max, max), height: proposal.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
  }
}

private struct RowButton: View {
  let symbol: String
  let help: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(GlanceColor.body)
        .frame(width: 30, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(HomeButtonStyle(radius: 6))
    .help(help)
    .accessibilityLabel(help)
  }
}

private struct EmptyLog: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Projects you work in show up here, newest first.")
        .font(GlanceFont.sans(13.5))
        .foregroundStyle(GlanceColor.body)
      HStack(spacing: 4) {
        Text("Open a terminal with")
        KeyCaps(keys: ["⌘", "T"], small: true)
        Text("and")
        Text("cd")
          .font(GlanceFont.mono(12, .medium))
          .foregroundStyle(GlanceColor.ink)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
        Text("into a project folder.")
      }
      .font(GlanceFont.sans(12.5))
      .foregroundStyle(GlanceColor.muted)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Open a terminal with Command T and cd into a project folder.")
    }
    .frame(maxWidth: 420, alignment: .leading)
  }
}

private struct HomeKeyHint: View {
  var body: some View {
    HStack(spacing: 6) {
      KeyCaps(keys: ["↑"], small: true)
      KeyCaps(keys: ["↓"], small: true)
      Text("move").padding(.trailing, 8)
      KeyCaps(keys: ["⏎"], small: true)
      Text("terminal").padding(.trailing, 8)
      KeyCaps(keys: ["⌥", "⏎"], small: true)
      Text("editor")
    }
    .font(GlanceFont.sans(12))
    .foregroundStyle(GlanceColor.muted)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Arrow keys move between projects; Return opens one in a terminal, Option-Return in the editor.")
  }
}

// MARK: - The spine

private enum SpinePoint: Hashable { case dial, firstRow, lastRow, empty }

private struct SpineAnchors: PreferenceKey {
  static let defaultValue: [SpinePoint: Anchor<CGRect>] = [:]
  static func reduce(value: inout [SpinePoint: Anchor<CGRect>], nextValue: () -> [SpinePoint: Anchor<CGRect>]) {
    value.merge(nextValue()) { $1 }
  }
}

/// One hairline from the dial's foot to the last project's tick: lit coral where it leaves now, cooling as it goes
/// back in time, and marked like a ruler between the projects (each row's own tick is the long one). With no projects
/// yet it trails off in dashes beside the empty note. It draws itself down once, on arrival.
private struct Spine: View {
  let anchors: [SpinePoint: Anchor<CGRect>]
  let proxy: GeometryProxy
  let x: CGFloat
  let drawn: Bool
  let reduceMotion: Bool

  var body: some View {
    if let dial = anchors[.dial].map({ proxy[$0] }) {
      let top = dial.maxY + 8
      let tail = anchors[.empty].map { proxy[$0] }
      let end = anchors[.lastRow].map { proxy[$0].midY } ?? tail.map { $0.minY + 2 } ?? top
      let length = max(0, end - top)
      ZStack(alignment: .topLeading) {
        SpineLine()
          .trim(from: 0, to: drawn ? 1 : 0)
          .stroke(LinearGradient(stops: Self.stops(length), startPoint: .top, endPoint: .bottom), lineWidth: 1)
          .frame(width: 1, height: length)
          .offset(x: x - 0.5, y: top)
        if tail != nil {
          SpineLine()
            .stroke(Color.primary.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            .frame(width: 1, height: 34)
            .offset(x: x - 0.5, y: end)
            .opacity(drawn ? 1 : 0)
        }
        if let first = anchors[.firstRow].map({ proxy[$0] }), let last = anchors[.lastRow].map({ proxy[$0] }) {
          RulerTicks(from: first.midY, to: last.midY, step: first.height / 4, x: x)
            .stroke(Color.primary.opacity(0.17), lineWidth: 1)
            .opacity(drawn ? 1 : 0)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .animation(reduceMotion ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: 0.72).delay(0.06), value: drawn)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  /// Coral for the first 110 points, cooling to a hairline by 230 that stays legible to the end.
  static func stops(_ length: CGFloat) -> [Gradient.Stop] {
    guard length > 0 else { return [.init(color: .clear, location: 0)] }
    let warm = min(1, 110 / length), cool = min(1, 230 / length)
    return [
      .init(color: GlanceColor.coral.opacity(0.8), location: 0),
      .init(color: GlanceColor.coral.opacity(0.3), location: warm),
      .init(color: Color.primary.opacity(0.24), location: cool),
      .init(color: Color.primary.opacity(0.24), location: 1),
    ]
  }
}

/// The ruler's small marks: a 4-point tick every quarter row between the first and the last project.
private struct RulerTicks: Shape {
  let from: CGFloat
  let to: CGFloat
  let step: CGFloat
  let x: CGFloat

  func path(in rect: CGRect) -> Path {
    Path { path in
      guard step > 1, to > from else { return }
      var mark = 1
      var y = from + step
      while y < to - 0.5 {
        if mark % 4 != 0 { // every fourth mark is a row's own tick
          path.move(to: CGPoint(x: x - 2, y: y.rounded() + 0.5))
          path.addLine(to: CGPoint(x: x + 2, y: y.rounded() + 0.5))
        }
        mark += 1
        y += step
      }
    }
  }
}

private struct SpineLine: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    }
  }
}

// MARK: - Shortcuts

private struct ShortcutsRail: View {
  /// 0: a rail beside the log, groups one under another. Below the log on a narrow page: this many columns.
  let columns: Int

  private static let groups: [(String, [(String, [String], String)])] = [
    ("Studio", [("New tab", ["⌘", "T"], "Command T"), ("New editor tab", ["⇧", "⌘", "E"], "Shift Command E"),
                ("Tab sidebar", ["⇧", "⌘", "L"], "Shift Command L"), ("Home", ["⇧", "⌘", "H"], "Shift Command H")]),
    ("Glance", [("Show or hide the pane", ["⌥", "Space"], "Option Space"),
                ("Play or pause the voice", ["⌥", "."], "Option Period")]),
    ("Editor", [("Quick open", ["⌘", "P"], "Command P"), ("Find in project", ["⇧", "⌘", "F"], "Shift Command F"),
                ("Inline ask", ["⌘", "I"], "Command I")]),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Shortcuts")
        .font(GlanceFont.sans(13, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .accessibilityAddTraits(.isHeader)
      if columns > 0 {
        Grid(alignment: .topLeading, horizontalSpacing: 32, verticalSpacing: 20) {
          ForEach(Array(stride(from: 0, to: Self.groups.count, by: columns)), id: \.self) { start in
            GridRow(alignment: .top) {
              ForEach(Self.groups[start..<min(start + columns, Self.groups.count)], id: \.0) { group in
                Group(name: group.0, rows: group.1).frame(maxWidth: 260, alignment: .topLeading)
              }
            }
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
            if index > 0 {
              Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1).padding(.vertical, 12)
            }
            Group(name: group.0, rows: group.1)
          }
        }
      }
    }
    .padding(.top, 8)
  }

  private struct Group: View {
    let name: String
    let rows: [(String, [String], String)]

    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(GlanceFont.sans(11.5, .medium))
          .foregroundStyle(GlanceColor.muted)
          .padding(.bottom, 4)
        ForEach(rows, id: \.0) { row in
          HStack(spacing: 12) {
            Text(row.0)
              .font(GlanceFont.sans(12.5))
              .foregroundStyle(GlanceColor.body)
              .lineLimit(1)
            Spacer(minLength: 0)
            KeyCaps(keys: row.1)
          }
          .frame(minHeight: 28)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(row.0), \(row.2)")
        }
      }
    }
  }
}

// MARK: - Footer

private struct Footer: View {
  let state: HomeState
  let compact: Bool
  let perform: (HomeAction) -> Void

  var body: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1)
      HStack(spacing: 16) {
        Toggle("Show Home at launch", isOn: Binding(get: { state.showAtLaunch }, set: { perform(.setShowAtLaunch($0)) }))
          .toggleStyle(.switch)
          .controlSize(.small)
          .tint(GlanceColor.coral)
          .font(GlanceFont.sans(12.5, .medium))
          .foregroundStyle(GlanceColor.body)
        Spacer(minLength: 0)
        if !compact && !state.version.isEmpty {
          (Text("Glance Studio ").font(GlanceFont.sans(12, .medium)) + Text(state.version).font(GlanceFont.mono(11.5, .medium)))
            .foregroundStyle(GlanceColor.muted)
          Spacer(minLength: 0)
        }
        Button { perform(.focusTerminal) } label: {
          HStack(spacing: 8) {
            KeyCaps(keys: ["⏎"], small: true)
            Text("Open shell")
              .font(GlanceFont.sans(12.5, .medium))
              .foregroundStyle(GlanceColor.body)
          }
          .padding(.leading, 6)
          .padding(.trailing, 12)
          .frame(minHeight: 30)
          .contentShape(Rectangle())
        }
        .buttonStyle(HomeButtonStyle())
        .help("Back to the shell (⏎ or Esc)")
      }
      .padding(.top, 14)
      .padding(.bottom, 18)
    }
  }
}

// MARK: - Arrival

private extension View {
  /// One arrival for a part of the page: a fade with a short rise (or a slide off the spine, for a row), on its own
  /// delay. Under Reduce Motion, a quick fade only.
  func arrival(_ arrived: Bool, delay: Double, _ reduceMotion: Bool, slide: Bool = false) -> some View {
    self
      .opacity(arrived ? 1 : 0)
      .offset(x: !arrived && slide && !reduceMotion ? -10 : 0, y: !arrived && !slide && !reduceMotion ? 6 : 0)
      .animation(reduceMotion ? .linear(duration: 0.16) : .timingCurve(0.16, 1, 0.3, 1, duration: 0.42).delay(delay),
                 value: arrived)
  }
}
