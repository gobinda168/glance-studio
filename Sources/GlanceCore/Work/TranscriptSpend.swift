import Foundation

/// What a Claude Code transcript cost, read as a stream: a megabyte at a time, only the lines that carry usage decoded, the
/// rest dropped as bytes. It counts what `SessionTimeline.usage.cost` counts (a message repeated across lines once, at its
/// last figures; sidechains included) without building the timeline, so a transcript of any size is read in bounded memory.
/// Each read and each line's parse runs in its own autorelease pool: `FileHandle.read` and `JSONSerialization` return
/// autoreleased objects, and without a pool they all stay alive until the whole scan returns (a 398 MB file held 406 MB).
/// Blocking: never on the main thread.
public enum TranscriptSpend {
  private static let marker = Data(#""usage""#.utf8)

  /// One line's message id and cost; nil when it isn't an assistant message with usage and a model.
  public static func cost(line: Data) -> (id: String, cost: Double)? {
    guard line.range(of: marker) != nil else { return nil }
    return autoreleasepool {
      guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], entry["type"] as? String == "assistant",
            let message = entry["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
            let id = message["id"] as? String, let model = message["model"] as? String else { return nil }
      let record = UsageRecord(messageID: id, time: Date(), model: model, sessionID: "", project: "",
                               subagent: entry["isSidechain"] as? Bool == true, fast: false,
                               input: usage["input_tokens"] as? Int ?? 0, output: usage["output_tokens"] as? Int ?? 0,
                               cacheWrite5m: usage["cache_creation_input_tokens"] as? Int ?? 0, cacheWrite1h: 0,
                               cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
      return (id, UsagePricing.cost(record) ?? 0)
    }
  }

  /// The transcript's total, or nil when it can't be opened or `isCancelled` says stop. A line longer than `lineLimit`
  /// (a pasted image, say) is skipped without being held. `onRead` hears the size of each read.
  public static func total(of url: URL, chunk: Int = 1 << 20, lineLimit: Int = 32 << 20, isCancelled: () -> Bool = { false },
                           onRead: (Int) -> Void = { _ in }) -> Double? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    var costs: [String: Double] = [:]
    var line = Data()
    var skipping = false
    func finish() {
      if !skipping, let found = cost(line: line) { costs[found.id] = found.cost }
      line.removeAll(keepingCapacity: true)
      skipping = false
    }
    while true {
      if isCancelled() { return nil }
      var more = true
      // One pool per chunk: the chunk's data and what is parsed from it are freed before the next is read.
      autoreleasepool {
        guard let data = try? handle.read(upToCount: max(1, chunk)), !data.isEmpty else { more = false; return }
        onRead(data.count)
        var start = data.startIndex
        while start < data.endIndex {
          if let newline = data[start...].firstIndex(of: 0x0A) {
            if !skipping { line.append(data[start..<newline]) }
            finish()
            start = newline + 1
          } else {
            if !skipping { line.append(data[start...]) }
            start = data.endIndex
          }
          if line.count > lineLimit { line.removeAll(); skipping = true }
        }
      }
      if !more { break }
    }
    // The last line may have no newline yet (still being written): it counts only if it is whole JSON.
    finish()
    return costs.values.reduce(0, +)
  }
}
