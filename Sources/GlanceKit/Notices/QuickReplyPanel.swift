import AppKit
import GlanceCore
import SwiftUI

/// The quick-reply panel (spec 2026-10-09-notifications-design.md, "Quick-reply panel"): a floating glass card at the
/// top centre of the mouse's screen, under the nudge stack (or the meeting nudge), that takes the keyboard without
/// activating Studio, so the app the user was in stays in front. It shows the thread, the AI chips (⌘1 Summarise,
/// ⌘2 Analyse, ⌘3 Draft reply) and a composer whose Send (⌘↩) replies. Esc stops a running chip, else closes; ⌘O opens
/// the notice where it lives. Clicking elsewhere leaves it up (the user may be copying something).
@MainActor
public final class QuickReplyPanel {
  public static let shared = QuickReplyPanel()

  /// Open: Studio routes the notice (PR page, Chats tab…). Studio sets it to `NotificationHub.shared.open`.
  public var onOpen: ((Notice) -> Void)?

  static let width: CGFloat = 440
  static let maxHeight: CGFloat = 560
  /// Room round the card for its shadow.
  static let margin: CGFloat = 28
  /// Under the nudge stack's or the meeting nudge's card.
  static let gap: CGFloat = 12

  private let presenter = QuickReplyPresenter()
  private var panel: QuickReplyWindow?
  private var model: QuickReplyModel?
  private var screen: NSScreen?
  /// The card's top edge on screen; the card grows and shrinks downwards from it.
  private var top: CGFloat?
  private var cardHeight: CGFloat = 220
  private var closing = false

  private init() {}

  /// Whether `window` is the panel: Studio's app-wide key monitor lets the panel's keys through untouched.
  nonisolated public static func owns(_ window: NSWindow?) -> Bool { window is QuickReplyWindow }

  /// The model of the panel while it shows and has the keyboard (an fn hold dictates into its composer then).
  var keyModel: QuickReplyModel? {
    guard let panel, panel.isVisible, panel.isKeyWindow, !closing else { return nil }
    return model
  }

  /// Shows `notice`'s thread and takes the keyboard. Already showing it: just takes the keyboard again; showing
  /// another notice: swaps to this one in place.
  public func show(_ notice: Notice) {
    if let model, model.notice.id == notice.id, let panel, panel.isVisible, !closing {
      panel.makeKeyAndOrderFront(nil)
      return
    }
    model?.cancel()
    let model = QuickReplyModel(notice: notice)
    model.onSent = { [weak self, weak model] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        MainActor.assumeIsolated {
          guard let self, let model, self.model === model else { return }
          self.close()
        }
      }
    }
    self.model = model
    let panel = self.panel ?? makePanel()
    self.panel = panel
    let wasShowing = panel.isVisible && !closing
    closing = false
    if wasShowing {
      withAnimation(.smooth(duration: 0.24)) { presenter.model = model }
    } else {
      presenter.visible = false
      presenter.model = model
      screen = Self.mouseScreen
      top = nil
      place(panel)
    }
    panel.makeKeyAndOrderFront(nil)
    if !wasShowing {
      // The card unfolds on the next frame, once the window is up to draw it.
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self, !self.closing else { return }
          withAnimation(Self.arrival) { self.presenter.visible = true }
        }
      }
    }
    model.load()
  }

  /// Folds the card away (faster than it came) and stops anything it was running. A draft is dropped: nothing is
  /// sent.
  public func close() {
    guard let panel, panel.isVisible, !closing else { return }
    closing = true
    model?.cancel()
    withAnimation(Self.exit) { presenter.visible = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.closing else { return }
        self.closing = false
        panel.orderOut(nil)
        self.presenter.model = nil
        self.model = nil
        self.screen = nil
        self.top = nil
      }
    }
  }

  private func open() {
    guard let notice = model?.notice else { return }
    close()
    onOpen?(notice)
  }

  // MARK: Keys

  /// The panel's keys, ahead of the text box: Esc, ⌘1–3, ⌘↩, ⌘O, ⌘W, and the edit keys (Studio may not be the active
  /// app, so its menu can't be relied on for them).
  private func key(_ event: NSEvent, in window: NSWindow) -> Bool {
    guard let model else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    // Mid-composition (an input method's marked text) the keys belong to the text box.
    if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
    if event.keyCode == 53, flags.isEmpty {
      if model.aiRunning != nil { model.stop() } else { close() }
      return true
    }
    let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if flags == .command {
      switch (event.keyCode, character) {
      case (36, _), (76, _): model.send()
      case (_, "1"): model.run(.summarise)
      case (_, "2"): model.run(.analyse)
      case (_, "3"): model.run(.draft)
      case (_, "o"): open()
      case (_, "w"): close()
      case (_, "c"): return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: window)
      case (_, "v"): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: window)
      case (_, "x"): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: window)
      case (_, "a"): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: window)
      case (_, "z"): return NSApp.sendAction(Selector(("undo:")), to: nil, from: window)
      default: return false
      }
      return true
    }
    if flags == [.command, .shift], character == "z" {
      return NSApp.sendAction(Selector(("redo:")), to: nil, from: window)
    }
    return false
  }

  // MARK: The window

  private func makePanel() -> QuickReplyWindow {
    let panel = QuickReplyWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 300),
                                 styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                                 backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The card draws its own shadow inside the window's margin.
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.onKey = { [weak self, weak panel] event in
      guard let self, let panel else { return false }
      return self.key(event, in: panel)
    }
    let host = QuickReplyHostingView(rootView: QuickReplyRoot(presenter: presenter, actions: .init()))
    host.rootView = QuickReplyRoot(
      presenter: presenter,
      actions: QuickReplyActions(
        open: { [weak self] in self?.open() },
        close: { [weak self] in self?.close() },
        measured: { [weak self] height in self?.measured(height) }))
    // The window's size comes from what the card measures, not from the hosting view.
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  private func measured(_ height: CGFloat) {
    guard height > 0, abs(height - cardHeight) > 0.5 else { return }
    cardHeight = height
    if let panel, panel.isVisible { place(panel) }
  }

  /// Top centre of the mouse's screen just under the menu bar, or 12 pt under the nudge stack's (or else the meeting
  /// nudge's) card. The top is chosen once per showing; the card then grows and shrinks downwards.
  private func place(_ panel: NSWindow) {
    let screen = self.screen ?? Self.mouseScreen
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let visible = screen?.visibleFrame ?? frame
    let height = min(max(cardHeight, 1), Self.maxHeight)
    var card = NudgePlacement.frame(card: CGSize(width: Self.width, height: height), screen: frame, visible: visible)
    if top == nil {
      var anchor: CGFloat?
      if let stack = NudgeStack.shared.frame {
        anchor = stack.minY + NudgeStack.margin
        card.origin.x = (stack.midX - Self.width / 2).rounded()
      } else if let pill = MeetingNudger.shared.pillFrame {
        anchor = pill.minY + NudgeStageView.margin
        card.origin.x = (pill.midX - Self.width / 2).rounded()
      }
      top = anchor.map { $0 - Self.gap } ?? card.maxY
    }
    let cardTop = top ?? card.maxY
    card.origin.y = max((cardTop - height).rounded(), visible.minY + 8)
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  private static var mouseScreen: NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
  }

  private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  /// MASTER §6: a panel arrives on the spring and leaves faster, on ease-in.
  static var arrival: Animation {
    reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.84)
  }
  static var exit: Animation { .easeIn(duration: 0.16) }
}

// MARK: - Presenter

/// Which notice the card shows and whether it's unfolded.
@MainActor
final class QuickReplyPresenter: ObservableObject {
  @Published var model: QuickReplyModel?
  @Published var visible = false
}

struct QuickReplyActions {
  var open: @MainActor () -> Void = {}
  var close: @MainActor () -> Void = {}
  var measured: @MainActor (CGFloat) -> Void = { _ in }
}

// MARK: - Views

/// The card, unfolding from the top: down a little from above, out of a blur, from a touch narrower. Reduce Motion only
/// fades.
struct QuickReplyRoot: View {
  @ObservedObject var presenter: QuickReplyPresenter
  let actions: QuickReplyActions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .top) {
      if let model = presenter.model {
        QuickReplyCard(model: model, actions: actions)
          .id(model.notice.id)
          .transition(.opacity.combined(with: .blurSwap))
      }
    }
    .frame(width: QuickReplyPanel.width)
    .modifier(Unfold(on: presenter.visible, reduceMotion: reduceMotion))
    .padding(QuickReplyPanel.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

struct Unfold: ViewModifier {
  let on: Bool
  let reduceMotion: Bool

  func body(content: Content) -> some View {
    if reduceMotion {
      content.opacity(on ? 1 : 0)
    } else {
      content
        .scaleEffect(x: on ? 1 : 0.96, y: on ? 1 : 0.9, anchor: .top)
        .offset(y: on ? 0 : -12)
        .blur(radius: on ? 0 : 6)
        .opacity(on ? 1 : 0)
    }
  }
}

/// Header, the thread, the AI chips and their answer, the composer: thick warm glass with the rim on top; the thread,
/// the answer and the text box sit on their own clear layer (MASTER §1: content first, glass second).
struct QuickReplyCard: View {
  @ObservedObject var model: QuickReplyModel
  let actions: QuickReplyActions
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var composerFocused: Bool

  /// What the scrolling parts would take unclipped, and everything else (measured as the card minus them).
  @State private var threadNatural: CGFloat = 0
  @State private var answerNatural: CGFloat = 0
  @State private var cardMeasured: CGFloat = 0
  /// What the two scrolling parts were given on the last layout.
  @State private var threadShown: CGFloat = 0
  @State private var answerShown: CGFloat = 0

  static let radius: CGFloat = 18
  /// Inner panels sit 8 in from the card's edge: concentric corners.
  static let inset: CGFloat = 8
  static var innerRadius: CGFloat { radius - inset }
  private static let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

  /// A rewrite shows in the composer, not here: only its failure does.
  private var showsAnswer: Bool { (model.aiRunning != nil && !model.refining) || !model.aiText.isEmpty || model.aiError != nil }

  var body: some View {
    let heights = allotted
    VStack(spacing: 0) {
      QuickReplyHeader(model: model, open: actions.open, close: actions.close)
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
      ThreadView(model: model, natural: $threadNatural)
        .frame(height: heights.thread)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { threadShown = $0 }
        .background(InnerPanel())
        .padding(.horizontal, Self.inset)
      ChipsRow(model: model)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, showsAnswer ? 10 : 12)
      if showsAnswer {
        AnswerView(model: model, natural: $answerNatural)
          .frame(height: heights.answer)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { answerShown = $0 }
          .background(InnerPanel())
          .padding(.horizontal, Self.inset)
          .padding(.bottom, 10)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .blurSwap))
      }
      Composer(model: model, focused: $composerFocused, open: actions.open)
        .padding(.horizontal, Self.inset)
        .padding(.bottom, Self.inset)
    }
    .frame(width: QuickReplyPanel.width)
    .modifier(ThickSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(Self.rim, lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.34), radius: 22, y: 10)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
      cardMeasured = height
      actions.measured(height)
    }
    .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: showsAnswer)
    .onAppear { composerFocused = true }
    .onChange(of: model.focusRequest) { composerFocused = true }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Reply to \(model.notice.title)")
  }

  /// The thread and the answer share what's left of 560 pt after the fixed parts: both whole when they fit, else the
  /// answer gets up to half and the thread the rest (each scrolls). The fixed parts are the card's measured height less
  /// what the two scrolling parts were actually given on the last pass.
  private var allotted: (thread: CGFloat, answer: CGFloat) {
    let thread = max(threadNatural, 1)
    let answer = showsAnswer ? max(answerNatural, 1) : 0
    let fixed = max(cardMeasured - threadShown - (showsAnswer ? answerShown : 0), 160)
    let budget = max(QuickReplyPanel.maxHeight - fixed, 140)
    if thread + answer <= budget { return (thread, answer) }
    guard showsAnswer else { return (budget, 0) }
    let answerCap = min(answer, max(budget * 0.5, budget - thread))
    return (max(budget - answerCap, 72), answerCap)
  }

  /// MASTER §2's rim: a light top edge fading down the sides.
  static let rim = LinearGradient(stops: [.init(color: .white.opacity(0.28), location: 0),
                                                  .init(color: .white.opacity(0.08), location: 0.3),
                                                  .init(color: .white.opacity(0.04), location: 1)],
                                          startPoint: .top, endPoint: .bottom)
}

/// Thick glass (MASTER §2): the glass, a warm wash so the header and chips read over any desktop, and the e3 shadow
/// (on the card). Reduce Transparency: the solid surface.
struct ThickSurface<S: Shape>: ViewModifier {
  let shape: S
  let solid: Bool

  func body(content: Content) -> some View {
    if solid {
      content.background(shape.fill(GlanceColor.solid))
    } else {
      content
        .background(shape.fill(GlanceColor.solid.opacity(0.42)))
        .modifier(GlassSurface(shape: shape))
    }
  }
}

/// The clear layer under reading text: the solid surface, mostly opaque, with a hairline.
private struct InnerPanel: View {
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: QuickReplyCard.innerRadius, style: .continuous)
    shape.fill(GlanceColor.solid.opacity(0.78))
      .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
  }
}

// MARK: Header

private struct QuickReplyHeader: View {
  @ObservedObject var model: QuickReplyModel
  let open: () -> Void
  let close: () -> Void

  private var notice: Notice { model.notice }
  private var subject: String? {
    guard let subject = notice.meta["subject"], !subject.isEmpty, subject != notice.title else { return nil }
    return subject
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Badge(notice: notice)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(notice.title)
            .font(GlanceFont.sans(13, .semibold))
            .foregroundStyle(GlanceColor.ink)
            .lineLimit(1)
            .layoutPriority(1)
          if let place = notice.place, !place.isEmpty {
            Text(place)
              .font(GlanceFont.sans(12))
              .foregroundStyle(GlanceColor.muted)
              .lineLimit(1)
              .truncationMode(.middle)
          }
        }
        if let subject {
          Text(subject)
            .font(GlanceFont.sans(12))
            .foregroundStyle(GlanceColor.body)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        if let location = model.location {
          Text(location)
            .font(GlanceFont.mono(11))
            .foregroundStyle(GlanceColor.muted)
            .lineLimit(1)
            .truncationMode(.head)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 6) {
        KeyCap("⌘O")
        GlanceButton("Open", style: .secondary, label: "Open \(notice.title)", height: 26, cornerRadius: 6,
                     action: open)
          .help("Open (⌘O)")
        CloseButton(action: close)
      }
      .padding(.top, -1)
    }
  }
}

/// The sender's picture with the source's glyph on its corner, or the glyph alone on a quiet tile.
private struct Badge: View {
  let notice: Notice
  private static let size: CGFloat = 30

  var body: some View {
    if notice.avatarURL != nil || !notice.people.isEmpty {
      NoticeAvatar(notice: notice, size: Self.size)
        .overlay(alignment: .bottomTrailing) {
          NoticeGlyph(source: notice.source, size: 9)
            .foregroundStyle(GlanceColor.ink)
            .padding(2.5)
            .background(Circle().fill(GlanceColor.solid))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .offset(x: 4, y: 4)
        }
    } else {
      NoticeGlyph(source: notice.source, size: 15)
        .foregroundStyle(GlanceColor.ink)
        .frame(width: Self.size, height: Self.size)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
  }
}

// MARK: Thread

/// The conversation as a calm transcript, newest last, scrolled to the end; a shimmer while gh fetches it.
private struct ThreadView: View {
  @ObservedObject var model: QuickReplyModel
  @Binding var natural: CGFloat

  var body: some View {
    ScrollViewReader { reader in
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 14) {
          if model.loading && model.thread.isEmpty {
            Shimmer(widths: [0.32, 0.92, 0.64])
              .accessibilityLabel("Loading the conversation")
          } else {
            ForEach(Array(model.thread.enumerated()), id: \.offset) { _, message in
              MessageRow(message: message)
            }
          }
          if let note = model.threadNote {
            Text(note)
              .font(GlanceFont.sans(12))
              .foregroundStyle(GlanceColor.muted)
              .fixedSize(horizontal: false, vertical: true)
          }
          Color.clear.frame(height: 0).id("end")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { natural = $0 }
      }
      .scrollIndicators(.automatic)
      .onChange(of: model.thread.count) { reader.scrollTo("end", anchor: .bottom) }
      .onAppear { reader.scrollTo("end", anchor: .bottom) }
    }
    .clipShape(RoundedRectangle(cornerRadius: QuickReplyCard.innerRadius, style: .continuous))
    .environment(\.openURL, LinkPolicy.action)
  }
}

private struct MessageRow: View {
  let message: QuickReply.Message

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(message.author.isEmpty ? "Someone" : message.author)
          .font(GlanceFont.sans(12, .semibold))
          .foregroundStyle(GlanceColor.ink)
          .lineLimit(1)
        Spacer(minLength: 0)
        if let age = MessageRow.age(message.ts) {
          Text(age)
            .font(GlanceFont.mono(11))
            .foregroundStyle(GlanceColor.muted)
        }
      }
      Text(ReplyMarkdown.inline(message.text))
        .font(GlanceFont.sans(13))
        .foregroundStyle(GlanceColor.body)
        .lineSpacing(3)
        .tint(GlanceColor.coralInk)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  static func age(_ ts: String?) -> String? {
    guard let ts else { return nil }
    let date = ISO8601DateFormatter().date(from: ts)
      ?? Double(ts).map { Date(timeIntervalSince1970: $0) }
    return date.map { NoticeCard.age($0, now: Date()) }
  }
}

// MARK: AI chips

private struct ChipsRow: View {
  @ObservedObject var model: QuickReplyModel

  var body: some View {
    HStack(spacing: 6) {
      chip(.summarise, "Summarise", "⌘1")
      chip(.analyse, "Analyse", "⌘2")
      chip(.draft, "Draft reply", "⌘3")
      Spacer(minLength: 0)
      if model.aiRunning != nil {
        HStack(spacing: 6) {
          KeyCap("esc")
          GlanceButton("Stop", style: .quiet, label: "Stop Claude", height: 26, cornerRadius: 6) { model.stop() }
            .help("Stop (Esc)")
        }
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.16), value: model.aiRunning)
  }

  private func chip(_ action: QuickReply.Action, _ title: String, _ key: String) -> some View {
    AIChip(title: title, key: key, running: model.aiRunning == action, selected: model.aiAction == action) {
      model.run(action)
    }
    .help("\(title) (\(key))")
  }
}

/// One AI chip: its name and key; while it runs, Claude's thinking arc (teal) in place of the key.
private struct AIChip: View {
  let title: String
  let key: String
  let running: Bool
  let selected: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
          .font(GlanceFont.sans(12, .medium))
          .foregroundStyle(GlanceColor.ink)
        ZStack {
          if running {
            ThinkingArc().frame(width: 11, height: 11).transition(.opacity)
          } else {
            Text(key)
              .font(GlanceFont.mono(10.5, .semibold))
              .foregroundStyle(GlanceColor.muted)
              .transition(.opacity)
          }
        }
        .frame(minWidth: 18)
      }
      .padding(.leading, 10)
      .padding(.trailing, 8)
      .frame(height: 26)
      .background(shape.fill(fill))
      .overlay(shape.strokeBorder(Color.primary.opacity(selected ? 0 : 0.14), lineWidth: 1))
      .contentShape(shape)
    }
    .buttonStyle(Press())
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .animation(.easeOut(duration: 0.16), value: running)
    .accessibilityLabel(running ? "\(title), running" : title)
  }

  /// The chip whose answer shows wears the selection tint (MASTER §2: a semantic tint ≤ 16%).
  private var fill: Color {
    if selected { return GlanceColor.coral.opacity(0.16) }
    return hovering ? Color.primary.opacity(0.07) : .clear
  }
}

/// Claude thinking: a teal arc turning once a second. Still under Reduce Motion.
private struct ThinkingArc: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
      ZStack {
        Circle().stroke(GlanceColor.teal.opacity(0.22), lineWidth: 1.6)
        Circle().trim(from: 0, to: 0.3)
          .stroke(GlanceColor.teal, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
          .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
      }
    }
    .accessibilityHidden(true)
  }
}

private struct Press: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
      .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
  }
}

// MARK: AI answer

/// The chip's answer as it streams: Claude's small orb, what it is, Copy; the text (inline Markdown); or the error.
private struct AnswerView: View {
  @ObservedObject var model: QuickReplyModel
  @Binding var natural: CGFloat
  @State private var copied = false

  private var title: String {
    switch model.aiAction ?? model.aiRunning {
    case .summarise: "Summary"
    case .analyse: "Analysis"
    case .draft: "Draft"
    case .refine, nil: "Claude"
    }
  }

  var body: some View {
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          ClaudeDot()
          Text(title)
            .font(GlanceFont.sans(12, .semibold))
            .foregroundStyle(GlanceColor.ink)
          if let tool = model.aiTool {
            Text(tool)
              .font(GlanceFont.sans(11))
              .foregroundStyle(GlanceColor.tealInk)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          if model.aiRunning == nil, !model.aiText.isEmpty {
            GlanceButton(copied ? "Copied" : "Copy", style: .quiet, label: "Copy the \(title.lowercased())",
                         height: 24, cornerRadius: 6) { copy() }
          }
        }
        if let error = model.aiError {
          ErrorLine(text: error)
        } else if model.aiText.isEmpty {
          Shimmer(widths: [0.86, 0.58])
            .accessibilityLabel("Claude is writing")
        } else {
          Text(ReplyMarkdown.inline(model.aiText))
            .font(GlanceFont.sans(13))
            .foregroundStyle(GlanceColor.ink)
            .lineSpacing(4)
            .tint(GlanceColor.coralInk)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { natural = $0 }
    }
    .defaultScrollAnchor(.bottom)
    .clipShape(RoundedRectangle(cornerRadius: QuickReplyCard.innerRadius, style: .continuous))
    .environment(\.openURL, LinkPolicy.action)
    .onChange(of: model.aiText) { copied = false }
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(model.aiText, forType: .string)
    copied = true
  }
}

/// Claude in compact UI (MASTER §7.2, `.g-dot`): the small coral orb.
private struct ClaudeDot: View {
  var body: some View {
    Circle()
      .fill(RadialGradient(colors: [GlanceColor.coralHi, GlanceColor.coral, GlanceColor.coralLo],
                           center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 6))
      .frame(width: 9, height: 9)
      .accessibilityHidden(true)
  }
}

// MARK: Composer

/// The text box (3 to 8 lines, then it scrolls) and Send; after Send, "Sent", or the error with Copy and Open.
private struct Composer: View {
  @ObservedObject var model: QuickReplyModel
  var focused: FocusState<Bool>.Binding
  let open: () -> Void
  @State private var textHeight: CGFloat = 0
  @State private var copied = false
  @State private var instruction = ""
  @FocusState private var askFocused: Bool

  private static let lineHeight: CGFloat = 19
  private static let minHeight = lineHeight * 3 + 10
  private static let maxHeight = lineHeight * 8 + 10

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      field
      askRow
        .padding(.top, 8)
      if case .failed(let message) = model.sendResult {
        HStack(spacing: 8) {
          ErrorLine(text: message)
          Spacer(minLength: 4)
          GlanceButton(copied ? "Copied" : "Copy", style: .quiet, label: "Copy your reply", height: 24,
                       cornerRadius: 6) { copy() }
          // A Slack reply that didn't go can be sent from the workspace's tab instead.
          GlanceButton(model.notice.source == .slack ? "Open in Chats" : "Open", style: .secondary,
                       label: "Open \(model.notice.title)", height: 24, cornerRadius: 6, action: open)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .transition(.opacity)
      }
      HStack(spacing: 8) {
        ZStack(alignment: .leading) {
          if model.sendResult == .sent {
            Label {
              Text("Sent")
            } icon: {
              Image(systemName: "checkmark.circle.fill")
            }
            .font(GlanceFont.sans(12, .semibold))
            .foregroundStyle(GlanceColor.okInk)
            .transition(.opacity.combined(with: .blurSwap))
          } else {
            voiceLine
              .transition(.opacity)
          }
        }
        Spacer(minLength: 0)
        KeyCap("⌘↩")
        GlanceButton(model.sending ? "Sending…" : "Send", style: .primary, label: "Send the reply", height: 28,
                     cornerRadius: 6) { model.send() }
          .disabled(!model.canSend)
          .help("Send (⌘↩)")
      }
      .padding(.leading, 8)
      .padding(.top, 8)
      .animation(.easeOut(duration: 0.16), value: model.sendResult)
    }
  }

  /// "Ask Claude" under the text box: a one-line instruction rewrites what's in the box (or writes it, when empty).
  /// Claude only does this when asked; Undo puts the previous text back.
  private var askRow: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return HStack(spacing: 8) {
      ZStack {
        if model.refining {
          ThinkingArc().frame(width: 12, height: 12).transition(.opacity)
        } else {
          ClaudeDot().transition(.opacity)
        }
      }
      .frame(width: 14, height: 14)
      TextField("Ask Claude to change it: shorter, friendlier, add thanks…", text: $instruction)
        .textFieldStyle(.plain)
        .font(GlanceFont.sans(12))
        .foregroundStyle(GlanceColor.ink)
        .focused($askFocused)
        .disabled(model.refining || model.sending || model.sendResult == .sent)
        .onSubmit { ask() }
        .accessibilityLabel("Ask Claude to change your reply")
      if model.undoDraft != nil, !model.refining {
        GlanceButton("Undo", style: .quiet, label: "Undo the last change", height: 22, cornerRadius: 6) { model.undo() }
          .transition(.opacity)
      }
      if !instruction.trimmingCharacters(in: .whitespaces).isEmpty, !model.refining {
        KeyCap("↩").transition(.opacity)
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
    .background(shape.fill(Color.primary.opacity(0.05)))
    .overlay(shape.strokeBorder(askFocused ? GlanceColor.teal.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))
    .animation(.easeOut(duration: 0.16), value: askFocused)
    .animation(.easeOut(duration: 0.16), value: model.refining)
    .animation(.easeOut(duration: 0.16), value: model.undoDraft)
  }

  private func ask() {
    let text = instruction
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    instruction = ""
    model.refine(text)
  }

  /// Hold fn to dictate: the hint, "Listening…" with the words so far, "Transcribing…", or why it failed.
  private var voiceLine: some View {
    HStack(spacing: 6) {
      Image(systemName: model.listening ? "waveform" : "mic")
        .font(.system(size: 10, weight: .semibold))
        .symbolEffect(.variableColor.iterative, isActive: model.listening)
      Text(voiceText)
        .lineLimit(1)
        .truncationMode(.head)
    }
    .font(GlanceFont.sans(11))
    .foregroundStyle(model.voiceError == nil ? GlanceColor.muted : GlanceColor.criticalInk)
    .frame(maxWidth: 250, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var voiceText: String {
    if let error = model.voiceError { return error }
    if model.transcribing { return "Transcribing…" }
    if model.listening { return "Listening… " + (model.partial ?? "") }
    return "Hold fn to dictate"
  }

  private var field: some View {
    let shape = RoundedRectangle(cornerRadius: QuickReplyCard.innerRadius, style: .continuous)
    let height = min(max(textHeight + 10, Self.minHeight), Self.maxHeight)
    return ZStack(alignment: .topLeading) {
      // The text's height, measured the way the box lays it out, sizes the box between 3 and 8 lines.
      Text(model.draft.isEmpty ? " " : model.draft + " ")
        .font(GlanceFont.sans(13))
        .lineSpacing(3)
        .padding(.horizontal, 5)
        .fixedSize(horizontal: false, vertical: true)
        .hidden()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { textHeight = $0 }
      if model.draft.isEmpty {
        Text("Reply…")
          .font(GlanceFont.sans(13))
          .foregroundStyle(GlanceColor.muted)
          .padding(.horizontal, 5)
          .allowsHitTesting(false)
      }
      TextEditor(text: $model.draft)
        .font(GlanceFont.sans(13))
        .foregroundStyle(GlanceColor.ink)
        .lineSpacing(3)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .focused(focused)
        .disabled(model.sending || model.sendResult == .sent)
        .accessibilityLabel("Reply")
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .frame(height: height + 16, alignment: .topLeading)
    .background(shape.fill(GlanceColor.solid.opacity(0.86)))
    .overlay(shape.strokeBorder(focused.wrappedValue ? GlanceColor.coral.opacity(0.85) : Color.primary.opacity(0.12),
                                lineWidth: 1))
    .contentShape(shape)
    .onTapGesture { focused.wrappedValue = true }
    .animation(.easeOut(duration: 0.16), value: focused.wrappedValue)
  }

  private func copy() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(model.draft, forType: .string)
    copied = true
  }
}

// MARK: Small parts

/// A failure, in words, with its glyph (colour is never the only signal).
private struct ErrorLine: View {
  let text: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 11, weight: .semibold))
      Text(text)
        .font(GlanceFont.sans(12))
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .foregroundStyle(GlanceColor.criticalInk)
  }
}

/// A key chip beside its action (MASTER §8, `.g-kbd`).
struct KeyCap: View {
  let keys: String

  init(_ keys: String) { self.keys = keys }

  var body: some View {
    Text(keys)
      .font(GlanceFont.mono(10.5, .semibold))
      .foregroundStyle(GlanceColor.muted)
      .padding(.horizontal, 5)
      .frame(height: 18)
      .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
      .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
      .accessibilityHidden(true)
  }
}

private struct CloseButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .help("Close (Esc)")
    .accessibilityLabel("Close")
  }
}

/// Placeholder lines while something loads: a soft light passing over them. Still under Reduce Motion; it only runs
/// while it shows.
private struct Shimmer: View {
  let widths: [CGFloat]
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(widths.enumerated()), id: \.offset) { _, fraction in
          GeometryReader { proxy in
            Capsule()
              .fill(Color.primary.opacity(0.07))
              .overlay {
                if !reduceMotion {
                  LinearGradient(colors: [.clear, Color.primary.opacity(0.08), .clear], startPoint: .leading,
                                 endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.5)
                    .offset(x: (CGFloat(phase) * 2 - 0.75) * proxy.size.width)
                }
              }
              .clipShape(Capsule())
              .frame(width: proxy.size.width * fraction)
          }
          .frame(height: 9)
        }
      }
    }
  }
}

/// Links in the thread and the answer: never github.com in a browser (GitHub opens in the PR manager, via Open);
/// other web links open as usual.
private enum LinkPolicy {
  static let action = OpenURLAction { url in
    let host = url.host?.lowercased() ?? ""
    if host == "github.com" || host.hasSuffix(".github.com") { return .discarded }
    return .systemAction
  }
}

/// GitHub and Claude text as inline Markdown (bold, code, links), line breaks kept, HTML comments dropped, list
/// markers drawn as bullets.
private enum ReplyMarkdown {
  static func inline(_ text: String) -> AttributedString {
    var source = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
      .replacingOccurrences(of: "\r\n", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    source = source.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
      let trimmed = line.drop(while: { $0 == " " })
      let indent = String(repeating: " ", count: line.count - trimmed.count)
      if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return indent + "•  " + trimmed.dropFirst(2) }
      return String(line)
    }.joined(separator: "\n")
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                          failurePolicy: .returnPartiallyParsedIfPossible)
    return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
  }
}

private extension AnyTransition {
  /// MASTER's `.g-swap`: content changing in place rises 5 pt out of a 3 pt blur.
  static var blurSwap: AnyTransition {
    .modifier(active: ReplySwap(on: true), identity: ReplySwap(on: false))
  }
}

private struct ReplySwap: ViewModifier {
  let on: Bool

  func body(content: Content) -> some View {
    content.offset(y: on ? 5 : 0).blur(radius: on ? 3 : 0)
  }
}

// MARK: - AppKit

/// Takes the keyboard without activating Studio; its keys go to `onKey` before the text box sees them.
final class QuickReplyWindow: NSPanel {
  var onKey: (@MainActor (NSEvent) -> Bool)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// ⌘-keys come here first, ahead of the main menu (⌘W, ⌘↩ and ⌘1–3 are Studio menu items too).
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.type == .keyDown, let onKey, onKey(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  /// Plain keys (Esc) reach the window here, before the text box sees them.
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, let onKey, onKey(event) { return }
    super.sendEvent(event)
  }

  /// Esc reaching the window (no text box in the way): the panel's own Esc already ran in `sendEvent`.
  override func cancelOperation(_ sender: Any?) {}
}

/// The first click on the card presses what's under it, even while another app is active.
private final class QuickReplyHostingView: NSHostingView<QuickReplyRoot> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
