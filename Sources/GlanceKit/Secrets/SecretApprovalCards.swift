import AppKit
import GlanceCore
import LocalAuthentication
import SwiftUI

/// The approval card for a secret's use (spec "Approval card"): who, which secret, what request. Allow once / Allow for
/// this session need Touch ID; Deny doesn't; no answer in 120 s is Deny. Its own panel, not a ChannelBook card, so card
/// hot keys and fn-voice answers can never reach it, and it never takes the keyboard. One card at a time, oldest first,
/// top centre of the screen with the pointer.
@MainActor
final class SecretApprovalCards: ObservableObject {
  static let shared = SecretApprovalCards()
  static let timeout: TimeInterval = 120
  static let width: CGFloat = 420
  /// Room around the card for its shadow.
  static let margin: CGFloat = 24
  /// A card's Allows work only this long after it comes to the front, so a card that slides in under the pointer (the
  /// one before was denied or timed out) can't catch a click meant for the one before.
  static let armDelay: Duration = .seconds(1)
  /// Cards one session, and all sessions together, may have waiting; more are refused before they show.
  static let perSession = 5
  static let allSessions = 15

  enum Answer: Sendable { case once, session, deny }

  struct Pending: Identifiable {
    let id = UUID()
    let ask: SecretApprovalAsk
    /// No answer by then is Deny.
    let deadline: Date
    let finish: (Answer) -> Void
  }

  /// An Allow waiting on Touch ID: which card, and which Allow was pressed.
  struct Check: Equatable {
    let id: UUID
    let scope: Answer
  }

  @Published private(set) var queue: [Pending] = []
  /// Both Allows stay off until the sheet is answered.
  @Published private(set) var checking: Check?
  /// The front card, once its Allows work (`armDelay` after it came to the front).
  @Published private(set) var armed: UUID?
  private var front: UUID?
  private var arming: Task<Void, Never>?
  /// The open Touch ID sheet's context: invalidated when its card settles another way, which closes the sheet.
  private var checkContext: LAContext?
  /// When (system uptime) the front card was armed: a mouse-down before it can't count toward an Allow.
  private var armedAt: TimeInterval = .infinity
  /// The panel's mouse-downs and -ups and each Allow's frame: what `SecretClickRule` judges an Allow by.
  private var clicks = SecretClicks<Answer>()
  /// The SwiftUI space the Allows report their frames in: the panel's whole content, top-down.
  static let space = "SecretApprovalPanel"
  private var panel: SecretApprovalPanel?
  private var screen: NSScreen?
  private var contentSize = CGSize(width: width, height: 200)

  private init() {}

  func ask(_ ask: SecretApprovalAsk) async -> Answer {
    await withCheckedContinuation { continuation in
      let pending = Pending(ask: ask, deadline: Date().addingTimeInterval(Self.timeout)) {
        continuation.resume(returning: $0)
      }
      queue.append(pending)
      present()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(Self.timeout))
        self?.settle(pending.id, .deny)
      }
    }
  }

  /// Cards waiting for this session.
  func waiting(session: Int32) -> Int { queue.filter { $0.ask.caller.session == session }.count }

  /// An Allow button's frame in `space` (the panel's content, top-down).
  func laidOut(_ scope: Answer, _ frame: CGRect) { clicks.frames[scope] = frame }

  /// The panel received a left mouse-down or -up (before handling it), at a top-down point.
  fileprivate func mouse(down: Bool, _ mouse: SecretClickRule.Mouse) {
    if down { clicks.mouseDown(mouse) } else { clicks.mouseUp(mouse) }
  }

  /// Whether this Allow comes from a real click on that very button (`SecretClickRule`): an AXPress (e.g. Claude's
  /// osascript under Studio's grant) brings no mouse event to the panel, so it fails, even while the user is clicking
  /// elsewhere on the card. The click records are used up only when it passes, so a rejected
  /// script press can't spend the user's own click.
  private func realClick(_ scope: Answer) -> Bool {
    clicks.take(scope, armedAt: armedAt, now: ProcessInfo.processInfo.systemUptime)
  }

  /// A click: Deny settles at once, however it came; an Allow first needs the owner (a failed or cancelled check
  /// leaves the card up).
  func answer(_ id: UUID, _ answer: Answer) {
    guard let pending = queue.first(where: { $0.id == id }) else { return }
    guard answer != .deny else { return settle(id, .deny) }
    // An Allow counts only from a real click on its own button, so a script can't put up the Touch ID sheet for a card
    // or a scope the user didn't choose.
    guard armed == id, queue.first?.id == id, checking == nil, realClick(answer) else { return }
    let context = LAContext()
    checkContext = context
    checking = Check(id: id, scope: answer)
    // A click made while the sheet is up can't carry an Allow afterwards.
    clicks.reset()
    let reason = answer == .once ? "allow Claude to use \(pending.ask.secret) once"
      : "allow Claude to use \(pending.ask.secret) for this Claude session"
    Task { @MainActor in
      let ok = await OwnerCheck.confirm(reason, context: context)
      // Settled meanwhile (Deny, timeout, lock, session end): `settle` closed the sheet; the answer is moot.
      guard checking?.id == id else { return }
      checking = nil
      checkContext = nil
      clicks.reset()
      if ok { settle(id, answer) }
    }
  }

  /// Every card of a session that ended is Deny.
  func sessionEnded(_ session: Int32) {
    for pending in queue where pending.ask.caller.session == session { settle(pending.id, .deny) }
  }

  /// The vault locked (the Mac slept or locked): nobody was there to answer, so every card is Deny.
  func denyAll() {
    for pending in queue { settle(pending.id, .deny) }
  }

  private func settle(_ id: UUID, _ answer: Answer) {
    guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
    let pending = queue.remove(at: index)
    if checking?.id == id {
      checkContext?.invalidate()
      checkContext = nil
      checking = nil
      clicks.reset()
    }
    pending.finish(answer)
    frontChanged()
    if queue.isEmpty {
      panel?.orderOut(nil)
      screen = nil
    }
  }

  /// A new front card (or the first): its Allows are off for `armDelay`.
  private func frontChanged() {
    let id = queue.first?.id
    guard id != front else { return }
    front = id
    armed = nil
    armedAt = .infinity
    clicks.reset()
    arming?.cancel()
    guard let id else { return }
    arming = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.armDelay)
      guard !Task.isCancelled, let self, front == id else { return }
      armed = id
      armedAt = ProcessInfo.processInfo.systemUptime
    }
  }

  private func present() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if screen == nil { screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }
    place(panel)
    panel.orderFrontRegardless()
    frontChanged()
  }

  /// Top centre, just under the menu bar.
  private func place(_ panel: NSWindow) {
    let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: Self.width, height: max(contentSize.height, 1))
    let card = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.maxY - 8 - size.height).rounded(),
                      width: size.width, height: size.height)
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  private func measured(_ size: CGSize) {
    contentSize = size
    if let panel, !queue.isEmpty { place(panel) }
  }

  private func makePanel() -> SecretApprovalPanel {
    let panel = SecretApprovalPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 200),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    panel.cards = self
    let host = SecretApprovalHostingView(rootView: SecretApprovalView(cards: self,
                                                                      measured: { [weak self] in self?.measured($0) }))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }
}

/// Never key: the card has no keyboard answers.
private final class SecretApprovalPanel: NSPanel {
  /// Hears of every left mouse-down and -up the window server delivers here (an AXPress delivers none), before the
  /// card's buttons handle it.
  weak var cards: SecretApprovalCards?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown || event.type == .leftMouseUp, let cards, let content = contentView {
      // locationInWindow counts y up from the window's bottom; the buttons' frames are top-down from the content's
      // top left (it fills the panel), so the point goes through the content view's own space.
      let point = SecretClickRule.topDown(content.convert(event.locationInWindow, from: nil), bounds: content.bounds,
                                          flipped: content.isFlipped)
      cards.mouse(down: event.type == .leftMouseDown, SecretClickRule.Mouse(time: event.timestamp, point: point))
    }
    super.sendEvent(event)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class SecretApprovalHostingView: NSHostingView<SecretApprovalView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

struct SecretApprovalView: View {
  @ObservedObject var cards: SecretApprovalCards
  let measured: (CGSize) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      if let pending = cards.queue.first {
        SecretApprovalCard(pending: pending, waiting: cards.queue.count - 1, armed: cards.armed == pending.id,
                           checking: cards.checking, answer: { cards.answer(pending.id, $0) },
                           laidOut: { cards.laidOut($0, $1) })
        .id(pending.id)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                          removal: .opacity))
      }
    }
    .frame(width: SecretApprovalCards.width)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: measured)
    .padding(SecretApprovalCards.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // Fills the hosting view (the panel's content), so the Allows' frames line up with the panel's mouse points.
    .coordinateSpace(.named(SecretApprovalCards.space))
    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: cards.queue.first?.id)
  }
}

/// One request (the replica's `Secrets.approval()`): who · folder and the time left, the secret, the request, its
/// body, and the answers.
struct SecretApprovalCard: View {
  let pending: SecretApprovalCards.Pending
  let waiting: Int
  /// Its Allows work (a moment after it came to the front).
  let armed: Bool
  let checking: SecretApprovalCards.Check?
  let answer: (SecretApprovalCards.Answer) -> Void
  /// An Allow button's frame in `SecretApprovalCards.space`.
  let laidOut: (SecretApprovalCards.Answer, CGRect) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var scheme

  private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
  private static let field = Color.primary.opacity(0.06)

  private var ask: SecretApprovalAsk { pending.ask }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      title
      request
      if let bytes = ask.bodyBytes { bodyBox(bytes) }
      buttons
    }
    .padding(14)
    .frame(width: SecretApprovalCards.width, alignment: .leading)
    .overlay(alignment: .bottomLeading) { drain }
    .clipShape(Self.shape)
    .modifier(CardSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(scheme == .dark ? Color.white.opacity(0.16) : GlanceColor.rgb(0x1C1A17).opacity(0.12),
                                     lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Claude wants to use \(ask.secret)")
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.fill")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(GlanceColor.ink)
        .accessibilityHidden(true)
      // The folder Studio verified is what counts; the label is the session's own word, so it stays quiet.
      (Text(Self.shown(ask.caller.label, oneLine: true) + " · ").font(GlanceFont.sans(12, .medium))
        .foregroundStyle(GlanceColor.muted)
        + folder)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 4)
      if waiting > 0 {
        Text("+\(waiting) waiting").font(GlanceFont.sans(11)).foregroundStyle(GlanceColor.muted).fixedSize()
        Circle().fill(GlanceColor.muted.opacity(0.7)).frame(width: 2.5, height: 2.5).accessibilityHidden(true)
      }
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(Self.left(until: pending.deadline, now: context.date))
          .font(GlanceFont.sans(11))
          .monospacedDigit()
          .foregroundStyle(GlanceColor.muted)
          .fixedSize()
      }
    }
  }

  /// The folder Studio verified from the `claude` process, home as ~; a warning when it couldn't.
  private var folder: Text {
    guard let folder = ask.caller.folder else {
      return Text("folder unknown").font(GlanceFont.sans(12, .semibold)).foregroundStyle(GlanceColor.warnInk)
    }
    return Text(Self.shown((folder as NSString).abbreviatingWithTildeInPath, oneLine: true))
      .font(GlanceFont.sans(12, .semibold)).foregroundStyle(GlanceColor.body)
  }

  private var title: some View {
    HStack(spacing: 6) {
      Text("Claude wants to use")
        .font(GlanceFont.sans(13.5, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .fixedSize()
      Text(ask.secret)
        .font(GlanceFont.mono(12.5, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Self.field))
    }
  }

  /// `METHOD url`: the method and host in ink, the scheme and path muted, at most 3 lines.
  private var request: some View {
    let parts = Self.split(ask.url)
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(ask.method)
        .font(GlanceFont.mono(11, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .fixedSize()
      (Text(parts.scheme).foregroundStyle(GlanceColor.muted)
        + Text(parts.host).font(GlanceFont.mono(11, .semibold)).foregroundStyle(GlanceColor.ink)
        + Text(parts.rest).foregroundStyle(GlanceColor.muted))
        .font(GlanceFont.mono(11))
        .lineSpacing(2)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
  }

  /// The body's first 2 KB, five lines then it scrolls, and its size.
  private func bodyBox(_ bytes: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      if let preview = ask.bodyPreview, !preview.isEmpty {
        ScrollView {
          Text(Self.shown(preview, oneLine: false))
            .font(GlanceFont.mono(11))
            .lineSpacing(3)
            .foregroundStyle(GlanceColor.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(height: 80)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.field))
      }
      Text(Self.caption(bytes: bytes, preview: ask.bodyPreview))
        .font(GlanceFont.mono(10.5))
        .foregroundStyle(GlanceColor.muted)
    }
  }

  private var buttons: some View {
    HStack(spacing: 8) {
      GlanceButton("Deny", style: .secondary, label: "Deny \(ask.secret)", height: 26, cornerRadius: 6) {
        answer(.deny)
      }
      Spacer(minLength: 0)
      // While Touch ID is up, the pressed button names the scope the finger grants.
      GlanceButton(checking?.scope == .session ? "Touch ID · this session" : "Allow for this session",
                   systemImage: "touchid", style: .secondary, label: "Allow \(ask.secret) for this session",
                   height: 26, cornerRadius: 6) { answer(.session) }
        .disabled(!armed || checking != nil)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SecretApprovalCards.space)) }) {
          laidOut(.session, $0)
        }
      GlanceButton(checking?.scope == .once ? "Touch ID · once" : "Allow once", systemImage: "touchid",
                   style: .primary, label: "Allow \(ask.secret) once", height: 26, cornerRadius: 6) { answer(.once) }
        .disabled(!armed || checking != nil)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SecretApprovalCards.space)) }) {
          laidOut(.once, $0)
        }
    }
    .padding(.top, 2)
  }

  /// The two minutes running down along the bottom edge: quiet, no colour.
  private var drain: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = max(0, pending.deadline.timeIntervalSince(context.date)) / SecretApprovalCards.timeout
      GeometryReader { geometry in
        Rectangle()
          .fill(Color.primary.opacity(0.16))
          .frame(width: geometry.size.width * left)
          .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
      }
    }
    .frame(height: 2)
    .accessibilityHidden(true)
  }

  // MARK: - Text

  /// "Denies in 1:57".
  static func left(until deadline: Date, now: Date) -> String {
    let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    return "Denies in \(seconds / 60):" + String(format: "%02d", seconds % 60)
  }

  /// "Body · 186 bytes", "Body · 12.4 KB · first 2 KB shown", or "… · not text, not shown" for a binary body.
  static func caption(bytes: Int, preview: String?) -> String {
    let size = bytes < 1024 ? "\(bytes) bytes" : String(format: "%.1f KB", Double(bytes) / 1024)
    guard let preview else { return "Body · \(size) · not text, not shown" }
    return "Body · \(size)" + (preview.utf8.count < bytes ? " · first 2 KB shown" : "")
  }

  /// The scheme ("https://"), the host (with any port) and the rest.
  static func split(_ url: String) -> (scheme: String, host: String, rest: String) {
    guard let marker = url.range(of: "://") else { return ("", "", url) }
    let afterScheme = url[marker.upperBound...]
    let hostEnd = afterScheme.firstIndex { "/?#".contains($0) } ?? afterScheme.endIndex
    return (String(url[..<marker.upperBound]), String(afterScheme[..<hostEnd]), String(afterScheme[hostEnd...]))
  }

  /// Text Claude chose, made safe to show: control and invisible format characters (bidi overrides, zero-width
  /// marks) become �, so what the card shows is what is sent. One line folds newlines and tabs into spaces.
  static func shown(_ text: String, oneLine: Bool) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control where scalar == "\n" || scalar == "\t":
        scalars.append(oneLine ? " " : scalar)
      case .control, .format, .lineSeparator, .paragraphSeparator:
        scalars.append("\u{FFFD}")
      default:
        scalars.append(scalar)
      }
    }
    return String(scalars)
  }
}
