import Foundation
import GlanceCore

/// Token usage's engine (spec 2026-10-09-token-usage-design.md). It owns `usage.sqlite`. It scans Claude Code's
/// transcripts when started, every 2 minutes, and when the Usage tab asks, one scan at a time. It answers the page's
/// reports on a queue of their own, so a long first import doesn't hold them up. Studio starts it while the Usage
/// feature is on.
@MainActor
public final class UsageService: ObservableObject {
  public static let shared = UsageService()
  static let interval: TimeInterval = 120
  /// During the first import, the page reloads after this many files.
  nonisolated static let importStep = 25

  /// Bumped after a scan read something, so an open page reloads.
  @Published public private(set) var revision = 0
  /// The first import's progress, while the store was empty when the scan began.
  @Published public private(set) var importing: UsageScanner.Progress?
  /// Why the store couldn't be opened (a newer Glance's file, a disk error).
  @Published public private(set) var storeError: String?
  /// Where a damaged store was moved this launch.
  @Published public private(set) var movedAside: URL?

  public var calendar: Calendar { Calendar.current }

  public nonisolated static var file: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Glance/usage.sqlite")
  }

  private var store: UsageStore?
  private let scanning = DispatchQueue(label: "dev.glance.usage.scan", qos: .utility)
  private let reading = DispatchQueue(label: "dev.glance.usage.read", qos: .userInitiated)
  private var timer: Timer?
  private var busy = false
  private var again = false
  /// The helper process scans (`glance helper`), and this service only reads. False in a build without the CLI, which
  /// scans here.
  private var viaHelper = false
  private var running = false
  private var subscribed = false

  private init() {}

  /// The Usage feature is on (launch, or the Develop menu).
  public func start() {
    openStore()
    guard store != nil, !running else { return }
    running = true
    if HelperHost.shared.isAvailable {
      viaHelper = true
      if !subscribed {
        subscribed = true
        HelperHost.shared.onEvent { event in UsageService.shared.helperSaid(event) }
      }
      HelperHost.shared.start()
      HelperHost.shared.send(.usageStart) // dropped if the helper isn't up yet: its `ready` sends it
      return
    }
    timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
      MainActor.assumeIsolated { UsageService.shared.scan() }
    }
    scan()
  }

  /// The feature went off: no more scans. A scan under way finishes.
  public func stop() {
    running = false
    timer?.invalidate()
    timer = nil
    if viaHelper { HelperHost.shared.send(.usageStop) }
  }

  /// Reads what's new. A request during a scan runs one more after it.
  public func scan() {
    guard let store, running else { return }
    if viaHelper {
      HelperHost.shared.send(.usageScan)
      return
    }
    if busy {
      again = true
      return
    }
    busy = true
    let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    scanning.async {
      let first = ((try? store.earliest()) ?? nil) == nil
      var roots: [String: String] = [:]
      let read = (try? UsageScanner.scan(projects: projects, store: store, root: { folder in
        if let known = roots[folder] { return known }
        let found = ProjectRoot.find(from: folder)
        roots[folder] = found
        return found
      }, progress: { progress in
        guard first else { return }
        let reload = progress.done % Self.importStep == 0 || progress.done == progress.total
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            let usage = UsageService.shared
            usage.importing = progress
            if reload { usage.revision &+= 1 }
          }
        }
      })) ?? 0
      DispatchQueue.main.async {
        MainActor.assumeIsolated { UsageService.shared.scanned(read: read) }
      }
    }
  }

  /// What the helper reports: it is up (send it the job), a first import's progress, a scan's end.
  private func helperSaid(_ event: HelperWire.Event) {
    switch event {
    case .ready:
      if running { HelperHost.shared.send(.usageStart) }
    case .usageProgress(let done, let total):
      guard running else { return }
      importing = UsageScanner.Progress(done: done, total: total)
      if done % Self.importStep == 0 || done == total { revision &+= 1 }
    case .usageScanned(let read):
      importing = nil
      if read > 0 { revision &+= 1 }
    case .journalCollected:
      break
    }
  }

  private func scanned(read: Int) {
    busy = false
    importing = nil
    if read > 0 { revision &+= 1 }
    if again {
      again = false
      scan()
    }
  }

  /// `period`'s report (with the period before it, for the change), or nil without a store or when it can't be read.
  public func report(_ period: UsagePeriod, completion: @escaping @MainActor (UsageReport?) -> Void) {
    guard let store else {
      completion(nil)
      return
    }
    let calendar = self.calendar
    reading.async {
      let records = try? store.records(from: period.previous(calendar).start, to: period.end(calendar))
      let since = (try? store.earliest()) ?? nil
      let report = records.map { UsageReport.make(period: period, records: $0, calendar: calendar, trackedSince: since) }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(report) }
      }
    }
  }

  private func openStore() {
    guard store == nil else { return }
    do {
      let opened = try UsageStore.open(url: Self.file)
      store = opened.store
      movedAside = opened.movedAside
      storeError = nil
    } catch {
      storeError = "\(error)"
    }
  }
}
