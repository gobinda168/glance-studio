import AppKit
import GlanceCore
import SwiftUI

/// Tickets' card from the orb (spec 2026-10-09-tickets-design.md, "Morning card and check-in"): at the top centre of
/// the mouse's screen, under the notification cards and the meeting nudge when they show, over any app. The morning
/// card lists the top 3 with Claude's reasons; it stays until ✕, See all, Start or Open. While it shows the orbs glow.
/// The check-in lists the tickets touched today, each with the status Glance suggests. The window is the nudge stack's
/// kind: borderless, never key, every Space.
@MainActor
public final class TicketsCard {
  public static let shared = TicketsCard()

  public var onSeeAll: (() -> Void)?
  public var onOpen: ((Ticket) -> Void)?
  /// Start on a to-do ticket (moves it into progress); the card offers Start only once this is set.
  public var onStart: ((Ticket) -> Void)? {
    didSet { model.canStart = onStart != nil }
  }
  /// A check-in row's Move (and Apply all, once per row).
  public var onMove: ((Ticket, Ticket.Transition) -> Void)?
  /// Work on this: a terminal tab with Claude on the ticket; the card offers it only once this is set.
  public var onWorkOn: ((Ticket) -> Void)? {
    didSet { model.canWorkOn = onWorkOn != nil }
  }

  static let width: CGFloat = 400
  static let margin: CGFloat = 24
  static let gap: CGFloat = 12

  private let model = TicketsCardModel()
  private var panel: TicketsCardWindow?
  private var screen: NSScreen?
  private var contentSize = CGSize(width: TicketsCard.width, height: 180)

  private init() {}

  public var isShowing: Bool { model.content != nil }

  /// The top 3 and the summary; `updating` while a fresh rank is on its way (the card then redraws in place).
  public func showMorning(top: [TicketRanking.Ranked], summary: String, updating: Bool) {
    show(.morning(top: top, summary: summary, updating: updating))
  }

  /// The end-of-day check-in.
  public func showCheckIn(_ rows: [TicketCheckIn.Row]) {
    guard !rows.isEmpty else { return }
    show(.checkIn(rows: rows))
  }

  public func hide() {
    guard model.content != nil else { return }
    withAnimation(NudgeStack.exit) { model.content = nil }
    OrbAttention.setCard(false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
      guard let self, self.model.content == nil else { return }
      self.panel?.orderOut(nil)
      self.screen = nil
    }
  }

  func show(_ content: TicketsCardModel.Content) {
    guard !Prefs.holdsPopups else { return }
    let first = model.content == nil
    if first { screen = Self.mouseScreen }
    withAnimation(first ? NudgeStack.arrival : .smooth(duration: 0.24)) { model.content = content }
    guard first else { return }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    place(panel)
    panel.orderFrontRegardless()
    OrbAttention.setCard(true)
  }

  func act(_ action: TicketsCardModel.Action) {
    switch action {
    case .close:
      hide()
    case .seeAll:
      hide()
      onSeeAll?()
    case .open(let ticket):
      hide()
      onOpen?(ticket)
    case .start(let ticket):
      onStart?(ticket)
    case .move(let ticket, let transition):
      onMove?(ticket, transition)
    case .applyAll(let rows):
      for row in rows {
        guard let transition = row.transition else { continue }
        onMove?(row.ticket, transition)
      }
    case .workOn(let ticket):
      hide()
      onWorkOn?(ticket)
    }
  }

  // MARK: The window

  private func makePanel() -> TicketsCardWindow {
    let panel = TicketsCardWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width + 2 * Self.margin, height: 220),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .none
    let host = TicketsCardHostingView(rootView: TicketsCardView(model: model, act: { _ in }, measured: { _ in }))
    host.rootView = TicketsCardView(model: model, act: { [weak self] in self?.act($0) },
                                    measured: { [weak self] in self?.measured($0) })
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  private func measured(_ size: CGSize) {
    contentSize = size
    if let panel, model.content != nil { place(panel) }
  }

  /// Top centre of the screen it opened on, under the menu bar; or under the notification cards or the meeting nudge.
  private func place(_ panel: NSWindow) {
    let size = CGSize(width: Self.width, height: max(contentSize.height, 1))
    let screen = self.screen ?? Self.mouseScreen
    let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var card = NudgePlacement.frame(card: size, screen: frame, visible: screen?.visibleFrame ?? frame)
    if let above = NudgeStack.shared.frame ?? MeetingNudger.shared.pillFrame {
      // Both windows keep a margin round their cards.
      card.origin.x = (above.midX - size.width / 2).rounded()
      card.origin.y = (above.minY + NudgeStack.margin - Self.gap - size.height).rounded()
    }
    panel.setFrame(card.insetBy(dx: -Self.margin, dy: -Self.margin), display: true)
  }

  private static var mouseScreen: NSScreen? {
    NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
  }
}

/// What the card shows.
@MainActor
final class TicketsCardModel: ObservableObject {
  enum Content: Equatable {
    case morning(top: [TicketRanking.Ranked], summary: String, updating: Bool)
    case checkIn(rows: [TicketCheckIn.Row])
  }

  enum Action {
    case close, seeAll
    case open(Ticket)
    case start(Ticket)
    case move(Ticket, Ticket.Transition)
    case applyAll([TicketCheckIn.Row])
    case workOn(Ticket)
  }

  @Published var content: Content?
  @Published var canStart = false
  @Published var canWorkOn = false
}

/// The card on its glass, hanging from the top of the window.
struct TicketsCardView: View {
  @ObservedObject var model: TicketsCardModel
  /// Rows show the ticket as it is now (a Start that went through turns into Open) and a spinner while it moves.
  @ObservedObject private var service = TicketService.shared
  let act: (TicketsCardModel.Action) -> Void
  let measured: (CGSize) -> Void
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  private static let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

  var body: some View {
    VStack(spacing: 0) {
      if let content = model.content {
        card(content)
          .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -8)), removal: .opacity))
      }
    }
    .frame(width: TicketsCard.width)
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGSize.self, of: { $0.size }, action: measured)
    .padding(TicketsCard.margin)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder
  private func card(_ content: TicketsCardModel.Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      switch content {
      case .morning(let top, let summary, let updating):
        header("Your top \(top.count) today", updating: updating)
        if !summary.isEmpty {
          Text(summary)
            .font(GlanceFont.sans(12))
            .foregroundStyle(GlanceColor.body)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(top.enumerated()), id: \.element.id) { index, item in
            TicketsCardRow(item: live(item), number: index + 1, primary: index == 0, canStart: model.canStart,
                           canWorkOn: model.canWorkOn, starting: service.moving.contains(item.id), act: act)
          }
        }
        HStack {
          Spacer(minLength: 0)
          GlanceButton("See all", style: .quiet, label: "See all your tickets", height: 26, cornerRadius: 6) {
            act(.seeAll)
          }
        }
      case .checkIn(let rows):
        header("You touched \(rows.count) ticket\(rows.count == 1 ? "" : "s") today", updating: false)
        Text("Check their statuses before you stop.")
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.body)
        VStack(alignment: .leading, spacing: 10) {
          ForEach(rows) { row in
            CheckInRow(row: row, ticket: service.book.ticket(row.id) ?? row.ticket,
                       moving: service.moving.contains(row.id), act: act)
          }
        }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          GlanceButton("Not now", style: .quiet, label: "Close the check-in", height: 26, cornerRadius: 6) {
            act(.close)
          }
          let pending = rows.filter { row in
            guard let transition = row.transition else { return false }
            return (service.book.ticket(row.id)?.statusCategory ?? row.ticket.statusCategory) != transition.category
          }
          if !pending.isEmpty {
            GlanceButton("Apply all", style: .primary, label: "Move every ticket to its suggested status", height: 26,
                         cornerRadius: 6) { act(.applyAll(pending)) }
          }
        }
      }
    }
    .padding(16)
    .frame(width: TicketsCard.width, alignment: .leading)
    .background {
      if reduceTransparency {
        Self.shape.fill(GlanceColor.solid)
      } else {
        Color.clear.modifier(GlassSurface(shape: Self.shape))
      }
    }
    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
    .shadow(color: GlanceColor.rgb(0x1A0F0A).opacity(0.30), radius: 16, y: 7)
    .accessibilityElement(children: .contain)
  }

  private func live(_ item: TicketRanking.Ranked) -> TicketRanking.Ranked {
    TicketRanking.Ranked(ticket: service.book.ticket(item.id) ?? item.ticket, reason: item.reason)
  }

  private func header(_ title: String, updating: Bool) -> some View {
    HStack(spacing: 8) {
      Circle().fill(GlanceColor.coral).frame(width: 8, height: 8).accessibilityHidden(true)
      Text(title)
        .font(GlanceFont.sans(13, .semibold))
        .foregroundStyle(GlanceColor.ink)
        .accessibilityAddTraits(.isHeader)
      if updating {
        ProgressView().controlSize(.mini)
        Text("updating…")
          .font(GlanceFont.mono(11))
          .foregroundStyle(GlanceColor.muted)
      }
      Spacer(minLength: 4)
      Button { act(.close) } label: {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(GlanceColor.muted)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusEffectDisabled()
      .help("Close")
      .accessibilityLabel("Close")
    }
  }
}

/// One of the top tickets: its rank, key and title, Claude's reason, and Start (to-do tickets) or Open.
private struct TicketsCardRow: View {
  let item: TicketRanking.Ranked
  let number: Int
  let primary: Bool
  let canStart: Bool
  let canWorkOn: Bool
  let starting: Bool
  let act: (TicketsCardModel.Action) -> Void

  private var ticket: Ticket { item.ticket }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text("\(number)")
        .font(GlanceFont.mono(12, .semibold))
        .foregroundStyle(GlanceColor.coral)
        .frame(width: 12, alignment: .trailing)
        .padding(.top, 1)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(ticket.key)
            .font(GlanceFont.mono(11.5))
            .foregroundStyle(GlanceColor.muted)
            .fixedSize()
          Text(ticket.title)
            .font(GlanceFont.sans(13, .semibold))
            .foregroundStyle(GlanceColor.ink)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Text(item.reason ?? ticket.status)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if starting {
        ProgressView().controlSize(.small).frame(height: 26)
      } else if canStart && ticket.statusCategory == .todo {
        GlanceButton("Start", style: primary ? .primary : .secondary, label: "Start \(ticket.key)", height: 26,
                     cornerRadius: 6) { act(.start(ticket)) }
      } else if canWorkOn && ticket.statusCategory == .inProgress {
        GlanceButton("Work on this", style: .secondary, label: "Work on \(ticket.key) with Claude", height: 26,
                     cornerRadius: 6) { act(.workOn(ticket)) }
      } else {
        GlanceButton("Open", style: .secondary, label: "Open \(ticket.key)", height: 26, cornerRadius: 6) {
          act(.open(ticket))
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(number). \(ticket.key), \(ticket.title). \(item.reason ?? ticket.status)")
  }
}

/// A ticket touched today: its key and title, its status now, and Move to the suggested status (or a menu of its
/// statuses when Glance has no suggestion). Once it has moved it says so.
private struct CheckInRow: View {
  let row: TicketCheckIn.Row
  let ticket: Ticket
  let moving: Bool
  let act: (TicketsCardModel.Action) -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(ticket.key)
            .font(GlanceFont.mono(11.5))
            .foregroundStyle(GlanceColor.muted)
            .fixedSize()
          Text(ticket.title)
            .font(GlanceFont.sans(13, .semibold))
            .foregroundStyle(GlanceColor.ink)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        Text(row.suggestion.map { "\(ticket.status) · \($0.evidence)" } ?? ticket.status)
          .font(GlanceFont.sans(12))
          .foregroundStyle(GlanceColor.muted)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      trailing
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private var trailing: some View {
    if moving {
      ProgressView().controlSize(.small).frame(height: 26)
    } else if let transition = row.transition, ticket.statusCategory == transition.category {
      Text("Moved to \(transition.name) ✓")
        .font(GlanceFont.sans(12, .medium))
        .foregroundStyle(GlanceColor.ok)
        .fixedSize()
    } else if let transition = row.transition {
      GlanceButton("Move to \(transition.name)", style: .secondary, label: "Move \(ticket.key) to \(transition.name)",
                   height: 26, cornerRadius: 6) { act(.move(ticket, transition)) }
    } else if !ticket.transitions.isEmpty {
      Menu {
        ForEach(ticket.transitions, id: \.id) { transition in
          Button("Move to \(transition.name)") { act(.move(ticket, transition)) }
        }
      } label: {
        Text("Status…")
          .font(GlanceFont.sans(12, .medium))
          .foregroundStyle(GlanceColor.body)
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel("Change \(ticket.key)'s status")
    }
  }
}

/// Never key or main: the app in front keeps the keyboard.
private final class TicketsCardWindow: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The first click presses a button.
private final class TicketsCardHostingView: NSHostingView<TicketsCardView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
