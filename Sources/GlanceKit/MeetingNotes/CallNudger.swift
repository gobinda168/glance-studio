import AppKit
import CoreAudio
import GlanceCore
import SwiftUI

/// Offers meeting notes for a call Glance didn't start (spec 2026-10-09-meeting-notes-design.md, "Calls that start
/// without the nudge"): every 2 s it asks Core Audio which apps are using the mic (never the audio itself), and when a
/// call app (`CallApps`) has for 5 s, a pill drops in at the top: "Zoom call · Record notes?" with Record and ×. Once
/// per call; not while Glance records or the meeting nudge shows. Studio runs it while Meeting Notes and Settings →
/// Meetings → Offer to record calls are on.
@MainActor
public final class CallNudger {
  public static let shared = CallNudger()

  /// Record pressed: the title (the calendar meeting under way, else "<App> call") and that meeting's id.
  public var onRecord: ((_ title: String, _ eventID: String?) -> Void)?
  /// Glance is recording a meeting now.
  public var isRecording: (() -> Bool)?

  private var watch = CallWatch()
  private var timer: Timer?
  private var panel: NudgePanel?
  private var reading = false
  private var offer: (title: String, eventID: String?)?
  private let queue = DispatchQueue(label: "dev.glance.call-watch", qos: .utility)

  private init() {}

  public var isRunning: Bool { timer != nil }

  public func start() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
  }

  public func stop() {
    timer?.invalidate()
    timer = nil
    hide()
    watch = CallWatch()
  }

  private func poll() {
    guard !reading else { return }
    reading = true
    let own = ProcessInfo.processInfo.processIdentifier
    queue.async {
      let using = MicUsage.bundleIDs(excluding: own)
      Task { @MainActor in
        self.reading = false
        guard self.timer != nil else { return }
        self.handle(using)
      }
    }
  }

  private func handle(_ using: Set<String>) {
    let decision = watch.update(using: using, now: Date(), recording: isRecording?() ?? false,
                                meetingNudgeShowing: MeetingNudger.shared.pillFrame != nil)
    switch decision {
    case .none: break
    case .withdraw: hide()
    case .offer(let app, let since): show(app: app, since: since)
    }
  }

  private func show(app: String, since: Date) {
    let meeting = MeetingNudger.shared.meetingNow
    let title = meeting?.title ?? (app == "a browser" ? "Call in a browser" : "\(app) call")
    offer = (title, meeting?.id)
    let panel = self.panel ?? NudgePanel()
    self.panel = panel
    panel.onAction = { [weak self] action, _ in self?.act(action) }
    panel.show(Nudge(id: "call:\(app):\(since.timeIntervalSince1970)", dot: GlanceColor.coral, start: since,
                     timeRange: since.formatted(date: .omitted, time: .shortened), title: title,
                     meta: "On a call in \(app) · notes transcribed on this Mac", actions: [.record], label: "Call"),
               arriving: true)
  }

  private func act(_ action: Nudge.Action) {
    if action == .record, let offer { onRecord?(offer.title, offer.eventID) }
    watch.dismiss()
    hide()
  }

  private func hide() {
    offer = nil
    panel?.hide()
  }
}

/// Which processes are using an input device now, by bundle identifier, from Core Audio's process objects (macOS
/// 14.2+). Reads properties only; no audio. Runs off the main thread.
enum MicUsage {
  static func bundleIDs(excluding pid: pid_t) -> Set<String> {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    let system = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
    var out: Set<String> = []
    for object in objects {
      guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { continue }
      if let processPID = int32(object, kAudioProcessPropertyPID), processPID == pid { continue }
      if let bundleID = string(object, kAudioProcessPropertyBundleID), !bundleID.isEmpty { out.insert(bundleID) }
    }
    return out
  }

  private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
  }

  private static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Int32 = 0
    var size = UInt32(MemoryLayout<Int32>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
  }

  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
  }
}
