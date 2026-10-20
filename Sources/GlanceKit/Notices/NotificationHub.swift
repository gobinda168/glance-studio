import AppKit
import Combine
import GlanceCore

/// The one Notifications inbox (spec 2026-10-09-notifications-design.md): sources post notices here; the page, the
/// strip badge and the nudge stack read it. Saves on every change (coalesced).
@MainActor
public final class NotificationHub: ObservableObject {
  public static let shared = NotificationHub()

  private static let defaults = UserDefaults(suiteName: "dev.glance.Glance") ?? .standard
  private static let prefsKey = "notificationPrefs"

  @Published public private(set) var book = NoticeBook()
  @Published public var prefs: NotificationPrefs = NotificationHub.loadPrefs() {
    didSet { Self.defaults.set(try? JSONEncoder().encode(prefs), forKey: Self.prefsKey) }
  }
  @Published public private(set) var status: [Notice.Source: SourceStatus] = [:]

  /// Studio routes Open (PR manager, Slack tab, terminal, meeting link).
  public var onOpen: ((Notice) -> Void)?
  /// Shows the quick-reply panel.
  public var onReply: ((Notice) -> Void)?
  /// Whether Reply is offered for a notice (default: never). When its answer can change (the Slack connector check
  /// ends), Studio calls `repliesChanged()` so rows and cards drawn before then redraw.
  public var canReply: (Notice) -> Bool = { _ in false }
  /// Bumped by `repliesChanged()`: a change the page, side bar and nudge stack redraw on.
  @Published public private(set) var replyRevision = 0
  /// A meeting is in progress (Studio sets it from MeetingNudger).
  public var isInMeeting: () -> Bool = { false }
  /// A thread was read or done in Glance (GitHub read-sync).
  public var onThreadSettled: ((Notice) -> Void)?
  /// Shows nudges (Studio sets it to `NudgeStack.shared.show`).
  public var onNudge: ((Notice) -> Void)?
  /// A source's own button on a card or a row (Tickets: "Move to Done"), with the button's id.
  public var onAction: ((Notice, String) -> Void)?

  private var started = false
  private var saveScheduled = false

  /// What `canReply` answers may have changed: everything showing a Reply redraws.
  public func repliesChanged() { replyRevision += 1 }

  /// Loads the store once.
  public func start() {
    guard !started else { return }
    started = true
    var loaded = NoticeStore.load()
    loaded.prune(now: Date())
    book = loaded
  }

  /// Adds a notice, saves, and nudges when the rules say so.
  public func post(_ notice: Notice) {
    guard add(notice) else { return }
    if NudgeRules.shouldNudge(notice, prefs: prefs, now: Date(), inMeeting: isInMeeting()) { onNudge?(notice) }
  }

  /// Adds a notice and saves, without nudging (the Develop menu's test card shows itself). False when it was here.
  @discardableResult
  public func add(_ notice: Notice) -> Bool {
    start()
    guard book.add(notice, now: Date()) else { return false }
    scheduleSave()
    // Automations' event triggers (their own cards don't count).
    if let event = AutomationEventSignals.noticeNew(notice) { GlanceEventBus.shared.publish(event) }
    return true
  }

  public func open(_ notice: Notice) {
    book.markRead(threadKey: notice.threadKey)
    scheduleSave()
    onThreadSettled?(notice)
    onOpen?(notice)
  }

  /// A source's own button: the thread is read, then the source acts.
  public func act(_ notice: Notice, actionID: String) {
    book.markRead(threadKey: notice.threadKey)
    scheduleSave()
    onThreadSettled?(notice)
    onAction?(notice, actionID)
  }

  public func reply(_ notice: Notice) {
    book.markRead(threadKey: notice.threadKey)
    scheduleSave()
    onThreadSettled?(notice)
    onReply?(notice)
  }

  public func markRead(_ row: NoticeBook.Row) {
    book.markRead(threadKey: row.newest.threadKey)
    scheduleSave()
    onThreadSettled?(row.newest)
  }

  public func markDone(_ row: NoticeBook.Row) {
    book.markDone(threadKey: row.newest.threadKey)
    scheduleSave()
    onThreadSettled?(row.newest)
  }

  /// A source settled a thread itself (an automation's parked run was answered in its tab): its cards go.
  public func markDone(threadKey: String) {
    guard let newest = book.notices.first(where: { $0.threadKey == threadKey && $0.state != .done }) else { return }
    book.markDone(threadKey: threadKey)
    scheduleSave()
    onThreadSettled?(newest)
  }

  public func markAllRead(filter: Notice.Source?) {
    let settled = book.rows(filter: filter, showDone: false).filter(\.unread).map(\.newest)
    book.markAllRead(filter: filter)
    scheduleSave()
    settled.forEach { onThreadSettled?($0) }
  }

  public func setStatus(_ status: SourceStatus, for source: Notice.Source) {
    if self.status[source] != status { self.status[source] = status }
  }

  private func scheduleSave() {
    guard !saveScheduled else { return }
    saveScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.saveScheduled = false
        NoticeStore.save(self.book)
      }
    }
  }

  private static func loadPrefs() -> NotificationPrefs {
    guard let data = defaults.data(forKey: prefsKey),
          let prefs = try? JSONDecoder().decode(NotificationPrefs.self, from: data) else { return .defaults }
    return prefs
  }
}
