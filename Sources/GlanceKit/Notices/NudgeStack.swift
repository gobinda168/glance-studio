import AppKit
import Combine
import GlanceCore
import SwiftUI

/// Notification cards over any app (spec 2026-10-09-notifications-design.md, "Nudges"): up to three at the top centre
/// of the mouse's screen, newest on top, under the meeting nudge when it shows. Each leaves 8 s after it last changed
/// (paused while the pointer is over the stack); a newer notice in a thread already on a card replaces it in place; a
/// fourth makes "+N more", which opens the Notifications page; with two or more, Clear all takes them all away. Reply
/// (⌥R) and Open (⌥O) act on the top card and mark its thread read; ✕, Clear all and leaving mark nothing. The window
/// is the meeting nudge's: borderless, never key, every Space.
@MainActor
public final class NudgeStack {
  public static let shared = NudgeStack()
  /// "+N more": Studio opens the Notifications page.
  public static let showNotifications = Notification.Name("dev.glance.showNotifications")

  static let width: CGFloat = 380
  static let limit = 3
  static let lifetime: TimeInterval = 8
  /// Room around the cards for their shadow.
  static let margin: CGFloat = 24
  /// Under the meeting nudge's card.
  static let pillGap: CGFloat = 12

  private let model = NudgeStackModel()
  private var panel: NudgeStackWindow?
  /// Seconds each card (by thread) has left on screen.
  private var remaining: [String: TimeInterval] = [:]
  private var ticker: Timer?
  private var lastTick = Date()
  /// The screen the stack opened on; it stays there until it empties.
  private var screen: NSScreen?
  private var contentSize = CGSize(width: NudgeStack.width, height: 96)
  private var shrinkScheduled = false
  private var placedUnder: NSRect?
  /// ⌥R / ⌥O while Studio is in front. No global monitor: it can't swallow the key, so the app in front would also
  /// get "®" or "ø".
  private var localKeys: Any?

  private init() {}

  /// The stack's window frame while cards show, else nil.
  public var frame: NSRect? {
    guard let panel, panel.isVisible, !model.cards.isEmpty else { return nil }
    return panel.frame
  }

  /// Shows `notice` on top, or redraws the card of its thread in place.
  public func show(_ notice: Notice) {
    guard !Prefs.holdsPopups else { return }
    let first = model.cards.isEmpty
    if first {
      screen = Self.mouseScreen
      model.more = 0
    }
    if let index = model.cards.firstIndex(where: { $0.threadKey == notice.threadKey }) {
      withAnimation(.smooth(duration: 0.24)) { model.cards[index] = notice }
    } else {
      withAnimation(Self.arrival) {
        model.cards.insert(notice, at: 0)
        if model.cards.count > Self.limit {
          let dropped = model.cards.removeLast()
          remaining[dropped.threadKey] = nil
          model.more += 1
        }
      }
    }
    remaining[notice.threadKey] = Self.lifetime
    if first { present() }
  }

  /// Takes a thread's card away (read elsewhere, or acted on).
  public func dismiss(threadKey: String) {
    guard model.cards.contains(where: { $0.threadKey == threadKey }) else { return }
    remaining[threadKey] = nil
    withAnimation(Self.exit) { model.cards.removeAll { $0.threadKey == threadKey } }
    if model.cards.isEmpty { finish() }
  }

  /// A made-up Slack direct message: the Develop menu's "Show a test notification". It lands in the inbox too (so the
  /// Notifications page shows it), whatever Do not disturb says; its Open marks it read and goes nowhere.
  public func showTest() {
    let id = "glance-test-\(UUID().uuidString)"
    let notice = Notice(id: id, source: .slack, kind: .slackDM, title: "Riya Sen",
                place: "Direct message",
                preview: "Could you look at the retry change before standup? I left two notes on the backoff.",
                date: Date(), threadKey: id,
                target: .slack(team: "glance-test", notificationID: nil, channel: nil), people: ["Riya Sen"],
                meta: ["test": "1"])
    NotificationHub.shared.add(notice)
    show(notice)
  }

  // MARK: - Acting

  private func act(_ action: NoticeCard.Action, _ notice: Notice) {
    dismiss(threadKey: notice.threadKey)
    switch action {
    case .reply: NotificationHub.shared.reply(notice)
    case .open: NotificationHub.shared.open(notice)
    case .close: break
    case .custom(let id): NotificationHub.shared.act(notice, actionID: id)
    }
  }

  private func showAll() {
    NotificationCenter.default.post(name: Self.showNotifications, object: nil)
    clearAll()
  }

  /// Every card off the screen at once, read or not: they stay in the inbox.
  private func clearAll() {
    remaining.removeAll()
    withAnimation(Self.exit) { model.cards.removeAll() }
    finish()
  }

  /// ⌥R / ⌥O on the top card while Studio is the active app (the stack window itself is never key).
  private func key(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
    // ⌥R / ⌥O typed in the quick-reply panel's text box are letters ("®", "ø"), not the cards' keys.
    guard flags == .option, !(event.window is QuickReplyWindow), let top = model.cards.first else { return false }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "r":
      guard NotificationHub.shared.canReply(top) else { return false }
      act(.reply, top)
    case "o":
      if let first = top.actions?.first { act(.custom(first.id), top) } else { act(.open, top) }
    default:
      return false
    }
    return true
  }

  // MARK: - On and off screen

  private func present() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    model.hovering = false
    shrinkScheduled = false
    place(panel)
    panel.orderFrontRegardless()
    lastTick = Date()
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    if localKeys == nil {
      localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        let taken = MainActor.assumeIsolated { self?.key(event) == true }
        return taken ? nil : event
      }
    }
    OrbAttention.setNotice(true)
    if NotificationHub.shared.prefs.sound { MeetingNudger.chime() }
  }

  /// The last card left: nothing keeps running (no timer, no key monitor) and the window goes once the card is gone.
  private func finish() {
    ticker?.invalidate()
    ticker = nil
    if let localKeys { NSEvent.removeMonitor(localKeys) }
    localKeys = nil
    remaining.removeAll()
    model.more = 0
    OrbAttention.setNotice(false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, self.model.cards.isEmpty else { return }
      self.panel?.orderOut(nil)
      self.screen = nil
      self.placedUnder = nil
    }
  }

  /// Counts the cards' time down unless the pointer is over the stack, and follows the meeting nudge if it came or went.
  private func tick() {
    let now = Date()
    let elapsed = now.timeIntervalSince(lastTick)
    lastTick = now
    if !model.hovering {
      for key in Array(remaining.keys) {
        remaining[key, default: 0] -= elapsed
        if remaining[key, default: 0] <= 0 { dismiss(threadKey: key) }
      }
    }
    if let panel, !model.cards.isEmpty, MeetingNudger.shared.pillFrame != placedUnder { place(panel) }
  }

  // MARK: - The window

  private func makePanel() -> NudgeStackWindow {
    let panel = NudgeStackWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 160),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The cards draw their own shadows inside the window's margin.
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let host = NudgeStackHostingView(rootView: NudgeStackView(model: model, act: { _, _ in }, showAll: {},
                                                              clearAll: {}, measured: { _ in }))
    host.rootView = NudgeStackView(
      model: model,
      act: { [weak self] action, notice in self?.act(action, notice) },
      showAll: { [weak self] in self?.showAll() },
      clearAll: { [weak self] in self?.clearAll() },
      measured: { [weak self] size in self?.measured(size) })
    // The window's size is set here, from what the cards measure, not by the hosting view.
    host.sizingOptions = []
    host.onHover = { [weak self] inside in self?.model.hovering = inside }
    panel.contentView = host
    return panel
  }

  /// The cards measured themselves: a taller stack grows the window at once; a shorter one waits for the leaving card
  /// to finish (the cards hang from the top, so the spare room below is just clear).
  private func measured(_ size: CGSize) {
    contentSize = size
    guard let panel else { return }
    if size.height + 2 * Self.margin >= panel.frame.height {
      place(panel)
    } else if !shrinkScheduled {
      shrinkScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
        guard let self, let panel = self.panel else { return }
        self.shrinkScheduled = false
        if !self.model.cards.isEmpty { self.place(panel) }
      }
    }
  }

  /// Top centre of the screen the stack opened on, just under the menu bar; or 12 pt under the meeting nudge's card.
  private func place(_ panel: NSWindow) {
    let size = CGSize(width: Self.width, height: max(contentSize.height, 1))
    let screen = self.screen ?? Self.mouseScreen
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var card = NudgePlacement.frame(card: size, screen: frame, visible: screen?.visibleFrame ?? frame)
    let pill = MeetingNudger.shared.pillFrame
    if let pill {
      // The meeting window has its own margin round its card.
      let pillCardBottom = pill.minY + NudgeStageView.margin
      card.origin.x = (pill.midX - size.width / 2).rounded()
      card.origin.y = (pillCardBottom - Self.pillGap - size.height).rounded()
    }
    placedUnder = pill
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  private static var mouseScreen: NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
  }

  private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  static var arrival: Animation {
    reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.38, dampingFraction: 0.82)
  }
  static var exit: Animation { .easeIn(duration: 0.16) }
}

// MARK: - Views

/// What the stack shows.
@MainActor
final class NudgeStackModel: ObservableObject {
  /// Newest first, at most `NudgeStack.limit`.
  @Published var cards: [Notice] = []
  /// Notices that came while three cards showed.
  @Published var more = 0
  /// The pointer is over the stack: the cards' time stands still.
  var hovering = false
}

/// The cards, newest on top, then "+N more" and Clear all; they hang from the top of the window.
struct NudgeStackView: View {
  @ObservedObject var model: NudgeStackModel
  /// Reply shows once the hub says it can (`replyRevision`: the Slack connector check ended after a card showed).
  @ObservedObject private var hub = NotificationHub.shared
  let act: (NoticeCard.Action, Notice) -> Void
  let showAll: () -> Void
  let clearAll: () -> Void
  let measured: (CGSize) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 8) {
      ForEach(Array(model.cards.enumerated()), id: \.element.threadKey) { index, notice in
        NoticeCard(notice: notice, top: index == 0, canReply: hub.canReply(notice)) {
          act($0, notice)
        }
        .transition(cardTransition)
      }
      if model.more > 0 || model.cards.count > 1 {
        HStack(spacing: 8) {
          if model.more > 0 {
            StackChip("+\(model.more) more", label: "\(model.more) more notifications. Open Notifications",
                      action: showAll)
          }
          StackChip("Clear all", icon: "xmark", label: "Clear all notifications", action: clearAll)
            .help("Close every card. They stay in Notifications.")
        }
        .transition(.opacity.animation(.easeOut(duration: 0.16)))
      }
    }
    .frame(width: NudgeStack.width)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: measured)
    .padding(NudgeStack.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  /// MASTER §7.3's rise on the spring; out faster, a little up. Reduce Motion only fades.
  private var cardTransition: AnyTransition {
    if reduceMotion { return .opacity.animation(.easeOut(duration: 0.16)) }
    return .asymmetric(
      insertion: .modifier(active: Rise(on: true, offset: -14, scale: 0.97, blur: 5),
                           identity: Rise(on: false, offset: -14, scale: 0.97, blur: 5))
        .animation(.spring(response: 0.38, dampingFraction: 0.82)),
      removal: .modifier(active: Rise(on: true, offset: -6, scale: 0.98, blur: 2),
                         identity: Rise(on: false, offset: -6, scale: 0.98, blur: 2))
        .animation(.easeIn(duration: 0.16)))
  }
}

/// One notification: who or what (source glyph or avatar), title · place · when, a one-line preview, and Reply / Open
/// / ✕. Warm graphite glass with the rim on top; coral only on the top card's main action, the one ⌥ reaches.
struct NoticeCard: View {
  enum Action { case reply, open, close, custom(String) }

  let notice: Notice
  /// The card ⌥R / ⌥O act on: its keys show and its main action is coral.
  let top: Bool
  let canReply: Bool
  let act: (Action) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
  private static let lead: CGFloat = 28

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        badge
        // A newer notice in the thread blur-swaps the words in place; the two overlap while they change.
        ZStack(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(notice.title)
                .font(GlanceFont.sans(13, .semibold))
                .foregroundStyle(GlanceColor.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
              if let place = notice.place, !place.isEmpty {
                Text(place)
                  .font(GlanceFont.sans(12))
                  .foregroundStyle(GlanceColor.muted)
                  .lineLimit(1)
                  .truncationMode(.tail)
              }
              Spacer(minLength: 4)
              TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Self.age(notice.date, now: context.date))
                  .font(GlanceFont.mono(11))
                  .foregroundStyle(GlanceColor.muted)
                  .fixedSize()
              }
            }
            Text(notice.preview)
              .font(GlanceFont.sans(12))
              .foregroundStyle(GlanceColor.body)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .id(notice.id)
          .transition(reduceMotion ? .opacity : .noticeSwap)
        }
        DismissButton(label: "Close the notification from \(notice.title)") { act(.close) }
          .padding(.top, -3)
          .padding(.trailing, -4)
      }
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        if let actions = notice.actions, !actions.isEmpty {
          sourceActions(actions)
        } else {
          readerActions
        }
      }
      .padding(.leading, Self.lead + 10)
    }
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .padding(.vertical, 12)
    .frame(width: NudgeStack.width, alignment: .leading)
    .modifier(CardSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(Self.rim, lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(notice.source.title): \(notice.title)")
  }

  /// A source's own buttons (Tickets: Move to Done · Not now), the first one ⌥O's, and the rest in ⋯.
  @ViewBuilder
  private func sourceActions(_ actions: [Notice.Action]) -> some View {
    if let more = notice.moreActions, !more.isEmpty {
      Menu {
        ForEach(more, id: \.id) { action in
          Button(action.title) { act(.custom(action.id)) }
        }
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(GlanceColor.muted)
          .frame(width: 26, height: 26)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
      .accessibilityLabel("More for \(notice.title)")
    }
    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
      if index == 0 && top { KeyHint("⌥O") }
      GlanceButton(action.title, style: index == 0 && top ? .primary : .secondary,
                   label: "\(action.title), \(notice.title)", height: 26, cornerRadius: 6) { act(.custom(action.id)) }
    }
  }

  /// Reply (when the source can) and Open.
  @ViewBuilder
  private var readerActions: some View {
    if canReply {
      if top { KeyHint("⌥R") }
      GlanceButton("Reply", style: top ? .primary : .secondary, label: "Reply to \(notice.title)", height: 26,
                   cornerRadius: 6) { act(.reply) }
        .help("Reply (⌥R)")
    }
    if top { KeyHint("⌥O") }
    GlanceButton("Open", style: top && !canReply ? .primary : .secondary, label: "Open \(notice.title)",
                 height: 26, cornerRadius: 6) { act(.open) }
      .help("Open (⌥O)")
  }

  /// The sender's picture when the notice has one (Slack, GitHub), with the source's glyph on its corner; else the
  /// glyph alone on a quiet tile.
  @ViewBuilder private var badge: some View {
    if notice.avatarURL != nil || !notice.people.isEmpty {
      NoticeAvatar(notice: notice, size: Self.lead)
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
        .frame(width: Self.lead, height: Self.lead)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
  }

  /// MASTER §2's rim: a light top edge fading down the sides, so the glass doesn't read as grey.
  private static let rim = LinearGradient(stops: [.init(color: .white.opacity(0.26), location: 0),
                                                  .init(color: .white.opacity(0.08), location: 0.35),
                                                  .init(color: .white.opacity(0.04), location: 1)],
                                          startPoint: .top, endPoint: .bottom)

  /// `now`, `4m`, `2h`, then the day.
  static func age(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// Glass (MASTER §2, Regular), or the solid surface under Reduce Transparency.
struct CardSurface<S: Shape>: ViewModifier {
  let shape: S
  let solid: Bool

  func body(content: Content) -> some View {
    if solid {
      content.background(shape.fill(GlanceColor.solid))
    } else {
      content.modifier(GlassSurface(shape: shape))
    }
  }
}

/// A glass pill under the cards: "+N more" (opens the Notifications page) or Clear all.
struct StackChip: View {
  let title: String
  var icon: String?
  let label: String
  let action: () -> Void
  @State private var hovering = false

  init(_ title: String, icon: String? = nil, label: String, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.label = label
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 5) {
        if let icon {
          Image(systemName: icon).font(.system(size: 8.5, weight: .bold)).accessibilityHidden(true)
        }
        Text(title).font(GlanceFont.sans(12, .medium)).monospacedDigit()
      }
      .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
      .padding(.horizontal, 12)
      .frame(height: 26)
      .modifier(GlassSurface(shape: Capsule()))
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .accessibilityLabel(label)
  }
}

/// A key chip beside its action (MASTER §8 "Key hint").
struct KeyHint: View {
  let keys: String

  init(_ keys: String) { self.keys = keys }

  var body: some View {
    Text(keys)
      .font(GlanceFont.mono(11))
      .foregroundStyle(GlanceColor.muted)
      .padding(.horizontal, 5)
      .frame(height: 18)
      .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
      .accessibilityHidden(true)
  }
}

/// A small round ✕ that only closes the card: muted until the pointer is on it.
struct DismissButton: View {
  let label: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .accessibilityLabel(label)
  }
}

/// A card arriving or leaving: up a little, a touch smaller, blurred, clear.
private struct Rise: ViewModifier {
  let on: Bool
  let offset: CGFloat
  let scale: CGFloat
  let blur: CGFloat

  func body(content: Content) -> some View {
    content
      .offset(y: on ? offset : 0)
      .scaleEffect(on ? scale : 1, anchor: .top)
      .blur(radius: on ? blur : 0)
      .opacity(on ? 0 : 1)
  }
}

private extension AnyTransition {
  /// MASTER's `.g-swap`: the new words rise 5 px out of a 3 px blur.
  static var noticeSwap: AnyTransition {
    .asymmetric(insertion: .modifier(active: NoticeSwap(on: true, rise: 5), identity: NoticeSwap(on: false, rise: 5)),
                removal: .modifier(active: NoticeSwap(on: true, rise: -5), identity: NoticeSwap(on: false, rise: -5)))
  }
}

private struct NoticeSwap: ViewModifier {
  let on: Bool
  let rise: CGFloat

  func body(content: Content) -> some View {
    content.offset(y: on ? rise : 0).blur(radius: on ? 3 : 0).opacity(on ? 0 : 1)
  }
}

/// Never key or main: the app in front keeps the keyboard.
private final class NudgeStackWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The first click presses a card's button; the pointer over the stack (even with another app active) holds the
/// cards' time.
private final class NudgeStackHostingView: NSHostingView<NudgeStackView> {
  var onHover: ((Bool) -> Void)?
  private var area: NSTrackingArea?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let area { removeTrackingArea(area) }
    let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                              owner: self, userInfo: nil)
    addTrackingArea(area)
    self.area = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    onHover?(true)
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    onHover?(false)
  }
}
