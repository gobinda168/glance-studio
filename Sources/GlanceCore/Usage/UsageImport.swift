import Foundation

/// One Claude Code transcript line → its usage record (spec "Import"). Only assistant lines with `message.usage` and
/// some tokens count; `<synthetic>` replies (Claude Code's own placeholders) don't. A reply split over several lines
/// repeats its `message.id`, which the store keeps once.
public enum UsageImport {
  public static func record(line: String, file: String, offset: Int, root: (String) -> String,
                            temporary: String = NSTemporaryDirectory()) -> UsageRecord? {
    guard line.contains("\"usage\""),
          let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          entry["type"] as? String == "assistant",
          let message = entry["message"] as? [String: Any],
          let usage = message["usage"] as? [String: Any],
          let model = message["model"] as? String, model != "<synthetic>",
          let time = (entry["timestamp"] as? String).flatMap(JournalTime.parse) else { return nil }
    func count(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }
    let input = count(usage["input_tokens"])
    let output = count(usage["output_tokens"])
    let cacheRead = count(usage["cache_read_input_tokens"])
    let creation = count(usage["cache_creation_input_tokens"])
    var write5m = creation
    var write1h = 0
    if let split = usage["cache_creation"] as? [String: Any] {
      let fiveMinutes = count(split["ephemeral_5m_input_tokens"])
      let hour = count(split["ephemeral_1h_input_tokens"])
      if fiveMinutes + hour > 0 {
        write5m = fiveMinutes
        write1h = hour
      }
    }
    guard input + output + cacheRead + write5m + write1h > 0 else { return nil }
    let cwd = entry["cwd"] as? String ?? ""
    let project = cwd.isEmpty || JournalTranscripts.isScratch(cwd, temporary: temporary) ? "" : root(cwd)
    let id = (message["id"] as? String) ?? (entry["requestId"] as? String) ?? "\(file):\(offset)"
    return UsageRecord(
      messageID: id, time: time, model: model, sessionID: entry["sessionId"] as? String ?? "", project: project,
      subagent: entry["isSidechain"] as? Bool == true || file.contains("/subagents/"),
      fast: usage["speed"] as? String == "fast", input: input, output: output, cacheWrite5m: write5m,
      cacheWrite1h: write1h, cacheRead: cacheRead)
  }
}
