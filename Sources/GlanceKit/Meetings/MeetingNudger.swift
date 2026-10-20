import AppKit
import GlanceCore
import SwiftUI

/// Meeting nudges (spec 2026-10-08-meeting-nudges-design.md, "MeetingNudger"): watches the calendar, shows the
/// meeting's nudge at the top centre of the screen when it starts, puts the orbs in their `meeting` mode while one is
/// under way, and says it (or chimes) once per meeting. Studio starts it at launch; it runs while nudges are on and
/// calendar access is allowed.
@MainActor
public final class MeetingNudger {
  public static let shared = MeetingNudger()

  public let calendar = CalendarSource()
  /// A nudge is about to speak: the host stops any reply being read aloud.
  public var willSpeak: (() -> Void)?
  private var state = MeetingAgenda.State()
  private var events: [MeetingEvent] = []
  /// `glance debug nudge-meeting`'s made-up meeting; never saved.
  private var testEvents: [MeetingEvent] = []
  private var panel: NudgePanel?
  private var shown: String?
  private var sounded: Set<String> = []
  /// Each meeting's Decline progress (and a link that wouldn't open), kept across refreshes.
  private var phases: [String: Nudge.Phase] = [:]
  private var timer: Timer?
  private var started = false

  private init() {}

  /// The meeting nudge's window frame while it shows, else nil: the notification cards (`NudgeStack`) go under it.
  public var pillFrame: NSRect? { panel?.frame }

  /// Studio turns this on with its Notifications feature: each meeting's nudge then also posts a notice to
  /// `NotificationHub` (once per meeting). Off, nothing reaches the inbox.
  public var postsNotices = false

  /// Studio turns this on with its Meeting Notes feature: the nudge offers Join & Record (Record without a link;
  /// Settings → Meetings can turn it off), which calls `onRecord` with the meeting's title and occurrence id.
  public var offersRecording = false
  public var onRecord: ((_ title: String, _ eventID: String) -> Void)?
  /// Whether a meeting is already being recorded (started from the Meetings tab): its nudge then doesn't show.
  public var isRecording: ((_ eventID: String) -> Bool)?

  /// Studio opens the call in a Browser tab and returns true. Nil elsewhere, so Join opens the call's app or the browser.
  public var openInBrowser: ((MeetingLink, _ title: String) -> Bool)?

  /// A meeting from the last refresh is under way (not all-day, not declined): notification cards hold back.
  public var isInMeeting: Bool {
    let now = Date()
    return events.contains { $0.start <= now && now < $0.end && !$0.isAllDay && !$0.declined }
  }

  /// The calendar meeting under way now (not all-day, not declined), soonest-started first: the title for a call's
  /// Record pill.
  public var meetingNow: MeetingEvent? {
    let now = Date()
    return events.filter { $0.start <= now && now < $0.end && !$0.isAllDay && !$0.declined }
      .max { $0.start < $1.start }
  }

  public func start() {
    guard !started else { return }
    started = true
    let now = Date()
    let done = Prefs.meetingsDone.filter { $0.value > now }
    Prefs.meetingsDone = done
    state.done = Set(done.keys)
    calendar.onChange = { [weak self] in
      self?.refresh()
      MeetingSettingsModel.shared.reload()
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                      queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("dev.glance.debug.nudgeMeeting"), object: nil,
                                                        queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.showTest(after: 5) }
    }
    OrbAttention.onOrbClick = { [weak self] in self?.orbClicked() ?? false }
    askOnce()
    refresh()
  }

  /// Fetches the next two hours again and re-decides: settings changed, the calendar changed, the Mac woke, the timer.
  public func refresh() {
    let now = Date()
    if Prefs.meetingNudges && calendar.access == .allowed {
      events = calendar.events(from: now.addingTimeInterval(-MeetingAgenda.cutoff - 60), to: now.addingTimeInterval(2 * 3600))
    } else {
      events = []
    }
    evaluate(now: now)
  }

  /// On the first launch with nudges, macOS asks for calendar access once; after that only Settings asks.
  private func askOnce() {
    // First Light asks for the calendar on its Permissions step.
    guard Prefs.meetingNudges, !Prefs.onboardingPending, !Prefs.meetingAccessAsked, calendar.access == .notAsked
    else { return }
    Prefs.meetingAccessAsked = true
    calendar.requestAccess { [weak self] _ in
      self?.refresh()
      MeetingSettingsModel.shared.reload()
    }
  }

  private var settings: MeetingAgenda.Settings {
    MeetingAgenda.Settings(calendarsOff: Set(Prefs.meetingCalendarsOff))
  }

  private var all: [MeetingEvent] { events + testEvents }

  private func evaluate(now: Date) {
    let settings = self.settings
    let pending = MeetingAgenda.pending(all, now: now, settings: settings, state: state)
    OrbAttention.setMeeting(!pending.isEmpty)
    let due = MeetingAgenda.due(all, now: now, settings: settings, state: state)
    if let due { show(due) } else { hideCard() }
    var wake = min(MeetingAgenda.nextWake(all, now: now, settings: settings, state: state) ?? .distantFuture,
                   now.addingTimeInterval(15 * 60))
    // A card's meeting may have moved or been declined.
    if due != nil { wake = min(wake, now.addingTimeInterval(15)) }
    schedule(at: wake)
  }

  private func schedule(at date: Date) {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: max(1, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
  }

  private func show(_ event: MeetingEvent) {
    guard !Prefs.holdsPopups else { return }
    if isRecording?(event.id) == true {
      markDone(event)
      hideCard()
      return
    }
    let panel = self.panel ?? NudgePanel()
    self.panel = panel
    panel.onAction = { [weak self] action, id in self?.act(action, id: id) }
    let arriving = shown != event.id || !panel.isVisible
    shown = event.id
    panel.show(nudge(for: event), arriving: arriving)
    if arriving, !sounded.contains(event.id) {
      sounded.insert(event.id)
      announce(event)
      postNotice(event)
    }
  }

  /// The meeting in the Notifications inbox (it never nudges: the meeting nudge owns it). The test meeting stays out.
  private func postNotice(_ event: MeetingEvent) {
    guard postsNotices, !isTest(event) else { return }
    let time = event.start.formatted(.dateTime.hour().minute())
    let preview = event.link.map { "\(time) · \($0.provider.name)" } ?? time
    NotificationHub.shared.post(Notice(
      id: "meeting:\(event.id):\(event.start.timeIntervalSince1970)", source: .meeting, kind: .meetingStarting,
      title: event.title, place: "Meeting", preview: preview, date: Date(), threadKey: "meeting:\(event.id)",
      target: .meeting(eventID: event.id, joinURL: event.link?.url)))
  }

  /// Once per meeting: said out loud (stopping a reply being read), else the chime.
  private func announce(_ event: MeetingEvent) {
    if Prefs.meetingSpeak {
      willSpeak?()
      NudgeVoice.shared.say(NudgeSpeech.meeting(name: NudgeVoice.name, title: event.title, start: event.start, now: Date()))
    } else if Prefs.meetingSound {
      Self.chime()
    }
  }

  /// The nudge's soft arrival sound, shared with the notification cards.
  static func chime() {
    guard let sound = NSSound(named: "Glass") else { return }
    sound.volume = 0.4
    sound.play()
  }

  private func hideCard() {
    shown = nil
    panel?.hide()
  }

  private func nudge(for event: MeetingEvent) -> Nudge {
    let dot = calendar.color(of: event.calendarID).flatMap { NSColor(cgColor: $0) }.map { Color(nsColor: $0) }
    return Nudge(id: event.id, dot: dot ?? GlanceColor.coral, start: event.start,
                 timeRange: (event.start..<max(event.end, event.start)).formatted(.interval.hour().minute()),
                 title: event.title, meta: "\(event.link?.provider.name ?? "No video link") · \(event.calendarTitle)",
                 actions: actions(for: event), phase: phases[event.id] ?? .ready)
  }

  private func actions(for event: MeetingEvent) -> [Nudge.Action] {
    let records = offersRecording && Prefs.meetingOfferRecording
    if event.link == nil { return [.decline] + (records ? [.record] : []) }
    return [.decline, .join] + (records ? [.joinAndRecord] : [])
  }

  private func act(_ action: Nudge.Action, id: String) {
    guard let event = all.first(where: { $0.id == id }) else {
      hideCard()
      return
    }
    switch action {
    case .join:
      guard let link = event.link else { return }
      // The test meeting's link goes nowhere.
      if isTest(event) || open(link, title: event.title) {
        markDone(event)
      } else {
        phases[id] = .failed("Couldn't open the link", retry: "Decline")
      }
    case .decline:
      if case .working? = phases[id] { return }
      if isTest(event) || !GoogleClient.isSetUp {
        markDone(event)
      } else {
        decline(event)
        return
      }
    case .close:
      state.closed.insert(id)
    case .review:
      // Journal's nudge only; a meeting never shows Review.
      break
    case .joinAndRecord:
      guard let link = event.link else { return }
      // The test meeting's link goes nowhere, but it records: it's how the button is tried.
      if isTest(event) || open(link, title: event.title) {
        onRecord?(event.title, event.id)
        markDone(event)
      } else {
        phases[id] = .failed("Couldn't open the link", retry: "Decline")
      }
    case .record:
      onRecord?(event.title, event.id)
      markDone(event)
    }
    evaluate(now: Date())
  }

  /// Decline as an RSVP (spec 2026-10-09-meeting-decline-rsvp-design.md, "The nudge"): signs in first when needed,
  /// then declines in Google Calendar. Success marks it done; a failure stays on the nudge with a retry.
  private func decline(_ event: MeetingEvent) {
    let account = GoogleAccount.shared
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if account.email == nil {
          self.setPhase(.working("Sign in to Google in your browser to decline…"), for: event.id)
          do {
            _ = try await account.signIn()
          } catch {
            self.setPhase(.failed("Didn't sign in.", retry: "Try Again"), for: event.id)
            return
          }
        }
        self.setPhase(.working("Declining…"), for: event.id)
        try await GoogleRSVP.decline(iCalUID: event.iCalUID, start: event.start,
                                     email: account.email ?? "your Google account", token: account.token,
                                     send: { request in
          let (data, response) = try await URLSession.shared.data(for: request)
          return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        })
        self.markDone(event)
        self.evaluate(now: Date())
      } catch let failure as GoogleRSVP.Failure {
        self.setPhase(.failed(GoogleRSVP.message(for: failure),
                              retry: failure == .signInExpired ? "Sign In Again" : "Try Again"), for: event.id)
      } catch {
        self.setPhase(.failed(GoogleRSVP.message(for: .offline), retry: "Try Again"), for: event.id)
      }
    }
  }

  /// Records a meeting's Decline progress and redraws its nudge if it's the one showing.
  private func setPhase(_ phase: Nudge.Phase, for id: String) {
    phases[id] = phase
    if shown == id, let event = all.first(where: { $0.id == id }) {
      panel?.show(nudge(for: event), arriving: false)
    }
  }

  /// Join: a Studio Browser tab when it's on and Studio offers it, else the call's app or the browser.
  private func open(_ link: MeetingLink, title: String) -> Bool {
    if Prefs.meetingJoinInBrowser, let openInBrowser, openInBrowser(link, title) { return true }
    return Self.open(link)
  }

  /// The call's app when it's installed (Zoom, Teams), else the browser. Also the Meetings tab's Join & Record.
  public static func open(_ link: MeetingLink) -> Bool {
    if let app = link.appURL, NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
      return NSWorkspace.shared.open(app)
    }
    return NSWorkspace.shared.open(link.url)
  }

  private func markDone(_ event: MeetingEvent) {
    phases[event.id] = nil
    state.done.insert(event.id)
    guard !isTest(event) else { return }
    var done = Prefs.meetingsDone
    done[event.id] = MeetingAgenda.doneUntil(event)
    Prefs.meetingsDone = done
  }

  private func isTest(_ event: MeetingEvent) -> Bool { testEvents.contains { $0.id == event.id } }

  /// A click on an orb while a meeting is under way and its card was closed: the card comes back.
  private func orbClicked() -> Bool {
    let now = Date()
    guard let first = MeetingAgenda.pending(all, now: now, settings: settings, state: state).first,
          !(shown == first.id && panel?.isVisible == true) else { return false }
    state.closed.remove(first.id)
    evaluate(now: now)
    return true
  }

  /// A made-up meeting starting after `delay`, with a Meet link, never saved: Settings → Meetings' "Show a test nudge"
  /// (at once) and `glance debug nudge-meeting` (in 5 s, time to switch apps). Shows with nudges off or no calendar
  /// access too.
  public func showTest(after delay: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      let start = Date()
      self.testEvents = [MeetingEvent(
        id: MeetingEvent.occurrenceID(eventID: "glance-test", start: start), calendarID: "glance-test",
        calendarTitle: "Glance", title: "Glance test meeting", start: start, end: start.addingTimeInterval(30 * 60),
        isAllDay: false, declined: false,
        link: MeetingLink(provider: .meet, url: URL(string: "https://meet.google.com/abc-defg-hij")!))]
      self.evaluate(now: Date())
    }
  }
}
