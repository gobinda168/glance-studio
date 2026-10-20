import AppKit
import Combine
import GlanceCore
import SwiftUI

/// The orb channel's cards (spec 2026-10-09-orb-channel-design.md, "Cards and the queue"): the active card in full —
/// a question with choices and a reply field, a nudge with its actions, or a permission prompt — and "+N waiting"
/// under it. Top centre of the mouse's screen, under the notification cards and the meeting pill. The panel takes
/// the keyboard only when the reply field is clicked; Studio never comes forward.
@MainActor
final class ChannelCards {
  static let shared = ChannelCards()
  static let width: CGFloat = 380
  static let margin: CGFloat = 24
  static let gap: CGFloat = 12

  let model = ChannelCardsModel()
  private var panel: ChannelCardsWindow?
  private var contentSize = CGSize(width: ChannelCards.width, height: 120)
  private var screen: NSScreen?
  /// The card the reply field's draft was typed for: a draft never goes to another card.
  private var draftCardID: String?
  /// The notification cards' and the meeting pill's frames the panel was last placed under.
  private var placedUnder: [NSRect?] = []
  /// While the panel shows: follows the notification cards and the meeting pill as they come and go.
  private var ticker: Timer?

  /// Studio's pending prompts (oldest first), the ones whose cards are revealed (key: surface + call id), and the book
  /// last shown, so either side can redraw.
  private var prompts: [PendingPrompt] = []
  private var revealed: Set<String> = []
  private var book = ChannelBook()

  static func key(_ prompt: PendingPrompt) -> String { prompt.surface + "|" + prompt.call.id }

  func update(prompts: [PendingPrompt]) {
    self.prompts = prompts
    revealed.formIntersection(prompts.map(Self.key))
    refresh()
  }

  func reveal(_ prompt: PendingPrompt?, takeKeyboard: Bool) {
    if let prompt { revealed.insert(Self.key(prompt)) } else { revealed.formUnion(prompts.map(Self.key)) }
    refresh()
    if takeKeyboard, model.prompt != nil { panel?.makeKey(); model.focusField += 1 }
  }

  func hide(_ prompt: PendingPrompt) {
    revealed.remove(Self.key(prompt))
    refresh()
  }

  func answeredElsewhere(_ surface: String) {
    guard model.prompt?.surface == surface else { return }
    model.promptNotice = "Answered elsewhere"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      guard let self, self.model.prompt?.surface == surface else { return }
      self.model.promptNotice = nil
      if let prompt = self.model.prompt { self.hide(prompt) }
    }
  }

  var frame: NSRect? { panel?.isVisible == true && (model.card != nil || model.prompt != nil) ? panel?.frame : nil }
  /// Task 13: the "Undo" beside "Heard: …" takes the voice answer back before it's sent.
  var onUndo: (() -> Void)?

  /// The hub's book changed: show the active card (or hide), and set its keys. It runs on every hub change (the hub's
  /// clock ticks twice a second while a card waits), so nothing happens unless what the panel shows changed.
  func update(book: ChannelBook) {
    self.book = book
    refresh()
  }

  private func refresh() {
    let shown = prompts.filter { revealed.contains(Self.key($0)) }
    let activePrompt = shown.first
    let active = activePrompt == nil ? book.active : nil
    let waiting = max(0, shown.count + book.cards.count - 1)
    let label = active.flatMap { book.sessions[$0.session]?.label } ?? "Claude"
    let channel = active.flatMap { book.sessions[$0.session]?.channel } ?? false
    guard active != model.card || activePrompt != model.prompt || label != model.label || waiting != model.waiting
      || channel != model.channel else { return }
    let cardChanged = active?.id != model.card?.id || activePrompt.map(Self.key) != model.prompt.map(Self.key)
    withAnimation(active == nil && activePrompt == nil ? NudgeStack.exit : NudgeStack.arrival) {
      model.card = active
      if activePrompt.map(Self.key) != model.prompt.map(Self.key) { model.promptNotice = nil }
      model.prompt = activePrompt
      model.label = label
      model.waiting = waiting
      model.channel = channel
      if cardChanged {
        // A draft, or what was heard, belongs to the card it was for. A voice answer still in its Undo window isn't
        // sent: its Undo would be gone.
        let unsent = model.heard != nil
        if unsent { CardVoiceAnswer.cancelPending() }
        model.draft = ""
        model.partial = nil
        model.heard = nil
        model.listening = false
        model.transcribing = false
        model.voiceError = unsent ? CardVoiceAnswer.cardChanged : nil
      }
    }
    if cardChanged {
      draftCardID = activePrompt.map(Self.key) ?? active?.id
      giveBackKeyboard()
    }
    if let activePrompt {
      CardHotKeys.shared.set(active: true,
                             choices: activePrompt.kind == .permission ? 0 : min(activePrompt.shownAnswers.count, 4),
                             permission: activePrompt.kind == .permission) { [weak self] key in self?.key(key) }
      present()
    } else if let active {
      let choices: Int
      switch active.kind {
      case .question(let options, _): choices = options.count
      case .nudge(let actions): choices = actions.count
      case .permission: choices = 0
      }
      CardHotKeys.shared.set(active: true, choices: choices, permission: active.isPermission) { [weak self] key in
        self?.key(key)
      }
      present()
    } else {
      CardHotKeys.shared.set(active: false, choices: 0, permission: false) { _ in }
      ticker?.invalidate()
      ticker = nil
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        guard let self, self.model.card == nil, self.model.prompt == nil else { return }
        self.panel?.orderOut(nil)
        self.screen = nil
        self.placedUnder = []
      }
    }
  }

  private func key(_ key: CardHotKeys.Key) {
    if let prompt = model.prompt {
      let answer: PromptAnswer? = switch key {
      case .allow: .option(1)
      case .deny: PromptKeys.denyNumber(prompt.screen).map(PromptAnswer.option)
      case .choice(let index): index < prompt.shownAnswers.count ? prompt.shownAnswers[index].answer : nil
      }
      if let answer, PromptKeys.keys(answer, kind: prompt.kind, screen: prompt.screen) != nil { NeedsYouCards.onAnswer?(prompt, answer) }
      return
    }
    guard let card = model.card else { return }
    switch (key, card.kind) {
    case (.choice(let index), .question(let choices, _)) where index < choices.count:
      OrbChannelHub.shared.answer(card.id, .choice(choices[index]), via: .click)
    case (.choice(let index), .nudge(let actions)) where index < actions.count:
      OrbChannelHub.shared.answer(card.id, .action(actions[index]), via: .click)
    case (.allow, .permission): OrbChannelHub.shared.answer(card.id, .allow, via: .click)
    case (.deny, .permission): OrbChannelHub.shared.answer(card.id, .deny, via: .click)
    default: break
    }
  }

  /// The reply field's Return.
  func send(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let prompt = model.prompt {
      guard draftCardID == Self.key(prompt), !trimmed.isEmpty else { return }
      model.draft = ""
      giveBackKeyboard()
      NeedsYouCards.onAnswer?(prompt, .note(trimmed))
      return
    }
    guard let card = model.card, draftCardID == card.id, !trimmed.isEmpty else { return }
    model.draft = ""
    giveBackKeyboard()
    if case .nudge = card.kind {
      // A message to the session, through its channel; the message is the nudge's answer.
      model.voiceError = nil
      guard OrbChannelHub.shared.push(to: card.session, text: trimmed, via: .text) else {
        model.draft = trimmed   // the session has gone: keep what was typed
        model.voiceError = "Couldn't reach \(model.label)."
        return
      }
      OrbChannelHub.shared.answer(card.id, .dismissed, via: .text)
      return
    }
    OrbChannelHub.shared.answer(card.id, .text(trimmed), via: .text)
  }

  private func present() {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    if screen == nil { screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main }
    place(panel)
    panel.orderFrontRegardless()
    if ticker == nil {
      ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.follow() }
      }
    }
  }

  /// The notification cards or the meeting pill came, went or moved: place the card under them again.
  private func follow() {
    guard let panel, model.card != nil || model.prompt != nil, anchors() != placedUnder else { return }
    place(panel)
  }

  /// The notification cards' and the meeting pill's frames, when they show on the panel's screen.
  private func anchors() -> [NSRect?] {
    let screenFrame = (screen ?? NSScreen.main)?.frame
    func onScreen(_ frame: NSRect?) -> NSRect? {
      guard let frame, let screenFrame else { return frame }
      return screenFrame.intersects(frame) ? frame : nil
    }
    return [onScreen(NudgeStack.shared.frame), onScreen(MeetingNudger.shared.pillFrame)]
  }

  /// After a typed answer, or when the card changes under the reply field: the app in front gets its keyboard back
  /// (a non-activating panel only gives up key by leaving the screen).
  private func giveBackKeyboard() {
    guard let panel else { return }
    panel.makeFirstResponder(nil)
    guard panel.isKeyWindow else { return }
    panel.orderOut(nil)
    if model.card != nil || model.prompt != nil { panel.orderFrontRegardless() }
  }

  /// Top centre, under the notification cards (or the meeting pill, or the menu bar).
  private func place(_ panel: NSWindow) {
    let screen = self.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = CGSize(width: Self.width, height: max(contentSize.height, 1))
    var top = visible.maxY - 8
    let under = anchors()
    placedUnder = under
    if let stack = under[0] { top = min(top, stack.minY + NudgeStack.margin - Self.gap) }
    else if let pill = under[1] { top = min(top, pill.minY + NudgeStageView.margin - Self.gap) }
    let card = NSRect(x: (visible.midX - size.width / 2).rounded(), y: (top - size.height).rounded(),
                      width: size.width, height: size.height)
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  private func makePanel() -> ChannelCardsWindow {
    let panel = ChannelCardsWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 200),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let host = ChannelCardsHostingView(rootView: ChannelCardsView(model: model, send: { [weak self] in self?.send($0) },
                                                                  measured: { [weak self] in self?.measured($0) }))
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  private func measured(_ size: CGSize) {
    contentSize = size
    if let panel { place(panel) }
  }
}

@MainActor
final class ChannelCardsModel: ObservableObject {
  @Published var card: ChannelBook.Card?
  /// Studio's prompt shown instead of a channel card, a notice on it ("Answered elsewhere"), and a counter that
  /// asks the card's text field for focus.
  @Published var prompt: PendingPrompt?
  @Published var promptNotice: String?
  @Published var focusField = 0
  @Published var label = "Claude"
  @Published var waiting = 0
  /// The active card's session was started with the channel flag: a nudge gets a Message field.
  @Published var channel = false
  @Published var draft = ""
  /// Task 13: fn is held for this card (the mic line shows "Listening…" and the words so far).
  @Published var listening = false
  @Published var partial: String?
  /// Task 13: fn was released and the words are being made out.
  @Published var transcribing = false
  /// Task 13: "Heard: … · Undo", for 2 s before a voice answer is sent.
  @Published var heard: String?
  @Published var voiceError: String?
}

/// Can be key (for the reply field) but only when a view needs it.
private final class ChannelCardsWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private final class ChannelCardsHostingView: NSHostingView<ChannelCardsView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Views

struct ChannelCardsView: View {
  @ObservedObject var model: ChannelCardsModel
  let send: (String) -> Void
  let measured: (CGSize) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 8) {
      if let prompt = model.prompt {
        PromptCardView(prompt: prompt, model: model, send: send)
          .id(ChannelCards.key(prompt))
          .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                            removal: .opacity))
      } else if let card = model.card {
        ChannelCardView(card: card, model: model, send: send)
          .id(card.id)
          .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                            removal: .opacity))
      }
      if model.waiting > 0 {
        StackChip("+\(model.waiting) more", label: "\(model.waiting) more waiting. Show the next") {
          if let prompt = model.prompt { ChannelCards.shared.hide(prompt) } else { OrbChannelHub.shared.next() }
        }
      }
    }
    .frame(width: ChannelCards.width)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: measured)
    .padding(ChannelCards.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

/// One orb-channel card: who asks, the question or message, and its answers.
struct ChannelCardView: View {
  let card: ChannelBook.Card
  @ObservedObject var model: ChannelCardsModel
  let send: (String) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @FocusState private var fieldFocused: Bool

  private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Text(card.title)
        .font(GlanceFont.sans(13, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
      if let body = card.body {
        Text(body)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.body)
          .lineLimit(4)
          .fixedSize(horizontal: false, vertical: true)
      }
      if card.stoppedWaiting {
        Text("Claude stopped waiting — answer anyway")
          .font(GlanceFont.sans(11))
          .foregroundStyle(GlanceColor.muted)
      }
      answers
    }
    .padding(14)
    .frame(width: ChannelCards.width, alignment: .leading)
    .modifier(CardSurface(shape: Self.shape, solid: reduceTransparency))
    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 14, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityTitle)
  }

  private var header: some View {
    HStack(spacing: 8) {
      NoticeGlyph(source: .claude, size: 13)
        .foregroundStyle(GlanceColor.ink)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.07)))
      Text(model.label)
        .font(GlanceFont.sans(12, .medium))
        .foregroundStyle(GlanceColor.muted)
        .lineLimit(1)
      Spacer(minLength: 4)
      Button("Open") { open() }
        .buttonStyle(.plain)
        .font(GlanceFont.sans(12))
        .foregroundStyle(GlanceColor.coralInk)
        .accessibilityLabel("Open \(model.label)")
      DismissButton(label: "Dismiss \(card.title)") { dismiss() }
    }
  }

  @ViewBuilder private var answers: some View {
    switch card.kind {
    case .question(let choices, let allowText):
      if !choices.isEmpty { buttons(choices) }
      if allowText { replyField(placeholder: "Type an answer…", label: "Answer \(card.title)") }
      voiceLine
    case .nudge(let actions):
      buttons(actions)
      if model.channel { replyField(placeholder: "Message \(model.label)…", label: "Message \(model.label)") }
      if let error = model.voiceError {
        Text(error)
          .font(GlanceFont.sans(11))
          .foregroundStyle(GlanceColor.criticalInk)
      }
    case .permission(_, _, let input):
      ScrollView {
        Text(input)
          .font(GlanceFont.mono(11))
          .foregroundStyle(GlanceColor.body)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
      .frame(maxHeight: 96)
      .padding(8)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
      HStack(spacing: 8) {
        Text("or answer in the terminal")
          .font(GlanceFont.sans(11))
          .foregroundStyle(GlanceColor.muted)
        Spacer(minLength: 0)
        KeyHint("⌥N")
        GlanceButton("Deny", style: .secondary, label: "Deny \(card.title)", height: 26, cornerRadius: 6) {
          OrbChannelHub.shared.answer(card.id, .deny, via: .click)
        }
        KeyHint("⌥Y")
        GlanceButton("Allow", style: .primary, label: "Allow \(card.title)", height: 26, cornerRadius: 6) {
          OrbChannelHub.shared.answer(card.id, .allow, via: .click)
        }
      }
      voiceLine
    }
  }

  private func buttons(_ titles: [String]) -> some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
        if index < 4 { KeyHint("⌥\(index + 1)") }
        GlanceButton(title, style: index == 0 ? .primary : .secondary, label: "\(title), \(card.title)", height: 26,
                     cornerRadius: 6) { choose(index) }
      }
    }
  }

  private func replyField(placeholder: String, label: String) -> some View {
    TextField(placeholder, text: $model.draft)
      .textFieldStyle(.plain)
      .font(GlanceFont.sans(13))
      .foregroundStyle(GlanceColor.ink)
      .focused($fieldFocused)
      .padding(.horizontal, 10)
      .frame(height: 30)
      .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
      .onSubmit { send(model.draft) }
      .accessibilityLabel(label)
  }

  /// Hold fn, listening, what was heard (with Undo), or why voice failed.
  private var voiceLine: some View {
    HStack(spacing: 6) {
      Image(systemName: model.listening ? "waveform" : "mic")
        .font(.system(size: 10, weight: .semibold))
      Text(voiceText)
        .lineLimit(2)
      if model.heard != nil {
        Button("Undo") { ChannelCards.shared.onUndo?() }
          .buttonStyle(.plain)
          .foregroundStyle(GlanceColor.coralInk)
      }
    }
    .font(GlanceFont.sans(11))
    .foregroundStyle(model.voiceError == nil ? GlanceColor.muted : GlanceColor.criticalInk)
  }

  private var voiceText: String {
    if let error = model.voiceError { return error }
    if let heard = model.heard { return "Heard: \(heard)" }
    if model.transcribing { return "Transcribing…" }
    if model.listening { return "Listening… " + (model.partial ?? "") }
    return card.isPermission ? "Hold fn and say allow or deny" : "Hold fn to answer by voice"
  }

  private var accessibilityTitle: String {
    switch card.kind {
    case .question: "\(model.label) asks: \(card.title)"
    case .nudge: "\(model.label): \(card.title)"
    case .permission: card.title
    }
  }

  private func choose(_ index: Int) {
    switch card.kind {
    case .question(let choices, _): OrbChannelHub.shared.answer(card.id, .choice(choices[index]), via: .click)
    case .nudge(let actions): OrbChannelHub.shared.answer(card.id, .action(actions[index]), via: .click)
    case .permission: break
    }
  }

  private func dismiss() { OrbChannelHub.shared.answer(card.id, .dismissed, via: .click) }

  private func open() {
    if let session = OrbChannelHub.shared.book.sessions[card.session] { OrbChannelHub.shared.onOpenSession?(session) }
  }
}
