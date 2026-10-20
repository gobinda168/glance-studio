import AppKit
import GlanceCore
import Observation
import SwiftUI

/// What a nudge shows (spec 2026-10-08-meeting-nudges-design.md, "NudgePanel + NudgeCard"). Meetings only for now;
/// Slack's nudge adds a reply field.
struct Nudge: Equatable {
  /// `joinAndRecord` opens the meeting and starts meeting notes; `record` only records (a meeting without a link, a
  /// call Glance noticed).
  enum Action: Equatable { case join, decline, close, review, record, joinAndRecord }

  var id: String
  var dot: Color
  var start: Date
  var timeRange: String
  var title: String
  var meta: String
  var actions: [Action]
  /// Decline's progress: ready, working ("Declining…", "Sign in to Google…"), or failed with a message and the
  /// title Decline takes for a retry ("Try Again", "Sign In Again").
  enum Phase: Equatable {
    case ready
    case working(String)
    case failed(String, retry: String)
  }

  var phase: Phase = .ready
  /// The coral line in place of the meeting's countdown (Journal's "Recap" nudge); nil for a meeting.
  var label: String? = nil
}

/// The nudge on stage: what it shows, whether it's in place, whether it's leaving, and the glow's arrival flare.
@MainActor @Observable
final class NudgeStage {
  var nudge: Nudge?
  var shown = false
  var leaving = false
  var flare = false
}

/// The panel's content: the nudge, with room around it for its glow and shadow. It drops in from the top with a 6 px
/// blur on the spring and goes back up faster (MASTER §6); Reduce Motion only fades.
struct NudgeStageView: View {
  static let margin: CGFloat = 40

  let stage: NudgeStage
  let act: (Nudge.Action, String) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if let nudge = stage.nudge {
        NudgeCard(nudge: nudge, live: stage.shown, flare: stage.flare) { act($0, nudge.id) }
      }
    }
    .offset(y: reduceMotion || stage.shown ? 0 : (stage.leaving ? -8 : -16))
    .scaleEffect(reduceMotion || stage.shown ? 1 : 0.96, anchor: .top)
    .blur(radius: reduceMotion || stage.shown || stage.leaving ? 0 : 6)
    .opacity(stage.shown ? 1 : 0)
    .padding(Self.margin)
  }
}

/// The nudge: a glass pill at the top of the screen with what and when on the left and Decline / Join / × on the
/// right, wearing Apple's Intelligence glow on its border (MASTER §7.1's one exception: it's the system's own "look
/// here", not a Claude action, so Join doesn't glow as well).
struct NudgeCard: View {
  let nudge: Nudge
  /// On screen: the glow turns and the clock ticks.
  let live: Bool
  /// Just arrived: the glow blooms, then settles.
  let flare: Bool
  let act: (Nudge.Action) -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

  private var declineTitle: String {
    if case .failed(_, let retry) = nudge.phase { return retry }
    return "Decline"
  }

  private var isWorking: Bool {
    if case .working = nudge.phase { return true }
    return false
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      content(countdown: nudge.label ?? MeetingAgenda.countdown(start: nudge.start, now: live ? context.date : Date()))
    }
  }

  private func content(countdown: String) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Circle().fill(nudge.dot).frame(width: 7, height: 7)
          Text(countdown)
            .font(GlanceFont.sans(11.5, .semibold))
            .monospacedDigit()
            .foregroundStyle(GlanceColor.coralInk)
            .id(countdown)
            .transition(reduceMotion ? .opacity : .swap)
          Text(nudge.timeRange)
            .font(GlanceFont.mono(11))
            .foregroundStyle(GlanceColor.muted)
            .lineLimit(1)
        }
        .animation(.smooth(duration: 0.24), value: countdown)
        Text(nudge.title)
          .font(GlanceFont.sans(14, .semibold))
          .foregroundStyle(GlanceColor.ink)
          .lineLimit(1)
          .truncationMode(.tail)
        switch nudge.phase {
        case .ready:
          Text(nudge.meta).font(GlanceFont.sans(11.5)).foregroundStyle(GlanceColor.muted).lineLimit(1)
        case .working(let text):
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text).font(GlanceFont.sans(11.5)).foregroundStyle(GlanceColor.muted).lineLimit(1)
          }
        case .failed(let text, _):
          Text(text).font(GlanceFont.sans(11.5)).foregroundStyle(GlanceColor.criticalInk).lineLimit(1)
            .help(text)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if nudge.actions.contains(.decline) {
        GlanceButton(declineTitle, style: .secondary, label: "\(declineTitle) \(nudge.title)", height: 28) {
          act(.decline)
        }
        .disabled(isWorking)
      }
      if nudge.actions.contains(.join) {
        GlanceButton("Join", style: nudge.actions.contains(.joinAndRecord) ? .secondary : .primary,
                     label: "Join \(nudge.title)", height: 28) { act(.join) }
      }
      if nudge.actions.contains(.joinAndRecord) {
        GlanceButton("Join & Record", style: .primary, label: "Join \(nudge.title) and record notes", height: 28) {
          act(.joinAndRecord)
        }
        .help("Joins and records meeting notes: transcribed on this Mac, notes by Claude")
      }
      if nudge.actions.contains(.record) {
        GlanceButton("Record", style: .primary, label: "Record notes of \(nudge.title)", height: 28) { act(.record) }
          .help("Records meeting notes: transcribed on this Mac, notes by Claude")
      }
      if nudge.actions.contains(.review) {
        GlanceButton("Review", style: .primary, label: "Review \(nudge.title)", height: 28) { act(.review) }
      }
      CloseButton(label: "Close the nudge for \(nudge.title)") { act(.close) }
    }
    .padding(.leading, 18)
    .padding(.trailing, 10)
    .padding(.vertical, 12)
    .frame(width: nudge.actions.contains(.joinAndRecord) ? 560 : 460)
    .modifier(GlassSurface(shape: Self.shape))
    .overlay(Self.shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
    .background { IntelligenceGlow(shape: Self.shape, live: live && !reduceMotion, flare: flare, part: .bloom) }
    .overlay { IntelligenceGlow(shape: Self.shape, live: live && !reduceMotion, flare: flare, part: .edge) }
  }
}

/// Apple Intelligence's edge light: its blue, violet, pink and orange turning around the shape. A crisp line with a
/// soft inner glow on the edge, and a blurred bloom behind; the bloom flares as the nudge arrives. Still under Reduce
/// Motion, and only ticks while on screen.
private struct IntelligenceGlow<S: InsettableShape>: View {
  enum Part { case edge, bloom }

  static var colors: [Color] {
    [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xFF6778, 0xFFBA71, 0xC686FF, 0xBC82F3].map { GlanceColor.rgb($0) }
  }

  let shape: S
  let live: Bool
  let flare: Bool
  let part: Part

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { context in
      let t = live ? context.date.timeIntervalSinceReferenceDate : 0
      let light = AngularGradient(colors: Self.colors, center: .center,
                                  angle: .degrees(t.truncatingRemainder(dividingBy: 4) / 4 * 360))
      // A slow breath under the turn, so it reads as light rather than a spinning stroke.
      let breath = live ? 0.5 + 0.5 * sin(t * 1.6) : 0.5
      switch part {
      case .edge:
        ZStack {
          shape.strokeBorder(light, lineWidth: 6).blur(radius: 5).opacity(0.55 + 0.15 * breath)
          shape.strokeBorder(light, lineWidth: 1.5)
        }
        .clipShape(shape)
      case .bloom:
        ZStack {
          shape.stroke(light, lineWidth: flare ? 16 : 8).blur(radius: flare ? 22 : 12)
            .opacity(flare ? 0.95 : 0.45 + 0.2 * breath)
          shape.stroke(light, lineWidth: 3).blur(radius: 4).opacity(0.8)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

/// A small round × that only closes the nudge: muted until the pointer is on it.
private struct CloseButton: View {
  let label: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(hovering ? GlanceColor.ink : GlanceColor.muted)
        .frame(width: 24, height: 24)
        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.05)))
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .focusEffectDisabled()
    .onHover { hovering = $0 }
    .animation(.easeOut(duration: 0.16), value: hovering)
    .accessibilityLabel(label)
  }
}

private extension AnyTransition {
  /// MASTER's `.g-swap`: the new words rise 5 px out of a 3 px blur.
  static var swap: AnyTransition {
    .asymmetric(insertion: .modifier(active: Swap(on: true, rise: 5), identity: Swap(on: false, rise: 5)),
                removal: .modifier(active: Swap(on: true, rise: -5), identity: Swap(on: false, rise: -5)))
  }
}

private struct Swap: ViewModifier {
  let on: Bool
  let rise: CGFloat

  func body(content: Content) -> some View {
    content.offset(y: on ? rise : 0).blur(radius: on ? 3 : 0).opacity(on ? 0 : 1)
  }
}
