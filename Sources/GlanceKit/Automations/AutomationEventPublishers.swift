import Combine
import Foundation
import GlanceCore

/// meeting.ended (spec "Trigger sources": the first publishers). The recorder doesn't publish it itself: this follows
/// its meeting and, when one turns ready with notes, writes notes.md beside meeting.json (the event's `notesPath`)
/// and publishes. Notifications, Tickets, Journal and the PR pages publish their own events where they happen.
@MainActor
public final class AutomationEventPublishers {
  public static let shared = AutomationEventPublishers()

  private var meetingWatch: AnyCancellable?
  private var fired = Set<String>()

  public func start() {
    guard meetingWatch == nil else { return }
    meetingWatch = MeetingRecorder.shared.$record.sink { [weak self] record in
      // Out of the recorder's own update.
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.meeting(record) } }
    }
  }

  private func meeting(_ record: MeetingRecord?) {
    guard let record else { return }
    let notes = MeetingNotesStore.standard.directory(record.id).appendingPathComponent(MeetingNotesMarkdown.fileName)
    guard let event = AutomationEventSignals.meetingEnded(record, notesPath: notes.path, fired: &fired) else { return }
    try? Data(MeetingNotesMarkdown.render(record).utf8).write(to: notes, options: .atomic)
    GlanceEventBus.shared.publish(event)
  }
}
