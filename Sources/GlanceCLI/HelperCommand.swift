import Foundation
import GlanceCore
import GlanceKit

/// `glance helper`: the process Glance Studio starts to run its background jobs (spec: a crash here restarts the helper
/// and leaves the app up). It reads commands from stdin, one per line, writes events to stdout, and exits when Studio
/// closes stdin (the app quit or crashed).
enum HelperCommand {
  static func run() -> Int32 {
    let output = NSLock()
    let emit: @Sendable (HelperWire.Event) -> Void = { event in
      output.lock()
      print(HelperWire.line(event))
      fflush(stdout)
      output.unlock()
    }
    let usage = UsageJob(emit: emit)
    let journal = JournalJob(emit: emit)
    emit(.ready)
    while let line = readLine() {
      switch HelperWire.command(from: line) {
      case .usageStart: usage.start()
      case .usageStop: usage.stop()
      case .usageScan: usage.scan()
      case .journalCollect(let id, let json): journal.collect(id: id, json: json)
      case nil: break
      }
    }
    return 0
  }
}
