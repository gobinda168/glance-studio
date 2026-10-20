import Foundation

/// Reads a tab's log back: the JSON lines, one state per request, and the filters `glance browser` offers.
public enum WebLogReader {
  /// The older half of a rotated log (`tab-3.jsonl.old`).
  public static func older(file: URL) -> URL { file.appendingPathExtension("old") }

  public static func parse(_ text: String) -> [WebLogEntry] {
    let decoder = JSONDecoder()
    return text.split(separator: "\n").compactMap { line in
      line.data(using: .utf8).flatMap { try? decoder.decode(WebLogEntry.self, from: $0) }
    }
  }

  /// One entry per `id` (the last line written for it), in the order they started.
  public static func reduce(_ entries: [WebLogEntry]) -> [WebLogEntry] {
    var latest: [Int: WebLogEntry] = [:]
    for entry in entries { latest[entry.id] = entry }
    return latest.values.sorted { $0.id < $1.id }
  }

  /// Everything the log holds: the rotated half, then the current file.
  public static func load(file: URL) -> [WebLogEntry] {
    let read: (URL) -> String = { url in
      (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    return reduce(parse(read(older(file: file)) + read(file)))
  }

  /// The tab a command means. `match` is a key (`tab:3`, `3`) or part of its address or title; without it, the tab
  /// that came to the front last.
  public static func tab(_ match: String?, in tabs: [WebLogTab]) -> WebLogTab? {
    guard let match, !match.isEmpty else { return tabs.max { $0.focused < $1.focused } }
    let needle = match.lowercased()
    if let exact = tabs.first(where: { $0.key == match || $0.key == "tab:" + match }) { return exact }
    return tabs.filter { $0.url.lowercased().contains(needle) || $0.title.lowercased().contains(needle) }
      .max { $0.focused < $1.focused }
  }
}

/// What to show: the `glance browser` flags.
public struct WebLogFilter: Equatable, Sendable {
  public var console = true
  public var network = true
  /// Page changes, shown as dividers; hidden by any narrowing filter.
  public var navigation = true
  /// Console messages at this level or above: debug, log (and info), warn, error.
  public var minLevel: String?
  /// Console errors and failed requests only.
  public var errorsOnly = false
  public var method: String?
  /// Case-insensitive text in a message, an address, a method or a body.
  public var text: String?

  public init() {}

  public static func rank(_ level: String?) -> Int {
    switch level {
    case "debug": 0
    case "warn": 2
    case "error": 3
    default: 1
    }
  }

  public func matches(_ entry: WebLogEntry) -> Bool {
    switch entry.kind {
    case .navigation:
      return navigation && minLevel == nil && !errorsOnly && method == nil && text == nil
    case .console:
      guard console else { return false }
      if method != nil { return false }
      if errorsOnly && entry.level != "error" { return false }
      if let minLevel, Self.rank(entry.level) < Self.rank(minLevel) { return false }
    case .network:
      guard network else { return false }
      if minLevel != nil && !entry.isFailedRequest { return false }
      if errorsOnly && !entry.isFailedRequest { return false }
      if let method, entry.method?.uppercased() != method.uppercased() { return false }
    }
    guard let text, !text.isEmpty else { return true }
    let haystack = [entry.text, entry.url, entry.method, entry.requestBody, entry.responseBody, entry.error,
                    entry.status.map(String.init)].compactMap { $0 }.joined(separator: "\n")
    return haystack.localizedCaseInsensitiveContains(text)
  }
}

/// Entries as terminal text.
public struct WebLogFormat: Sendable {
  public var color: Bool
  /// The terminal's width; nil leaves lines whole.
  public var width: Int?

  public init(color: Bool, width: Int? = nil) {
    self.color = color
    self.width = width
  }

  // MARK: Rows

  public func line(_ entry: WebLogEntry) -> String {
    switch entry.kind {
    case .console: consoleLine(entry)
    case .network: networkLine(entry)
    case .navigation: navigationLine(entry)
    }
  }

  private func consoleLine(_ entry: WebLogEntry) -> String {
    let level = entry.level ?? "log"
    let label = Self.pad(level == "log" ? "LOG" : level.uppercased(), 5)
    let lines = (entry.text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let head = paint(Self.clock(entry.time), "2") + "  " + paint(label, Self.levelColor(level)) + "  "
    let indent = String(repeating: " ", count: 12 + 2 + 5 + 2)
    let body = lines.enumerated().map { index, text in
      (index == 0 ? "" : indent) + (level == "error" ? paint(text, "31") : text)
    }
    return head + body.joined(separator: "\n")
  }

  private func networkLine(_ entry: WebLogEntry) -> String {
    let status: String
    let statusColor: String
    if entry.failed == true || entry.status == 0 {
      status = "ERR"
      statusColor = "31"
    } else if let code = entry.status {
      status = String(code)
      statusColor = code >= 500 ? "31" : code >= 400 ? "33" : code >= 300 ? "36" : "32"
    } else {
      status = "…"
      statusColor = "2"
    }
    let duration = entry.durationMs.map { Self.duration($0) } ?? ""
    let method = Self.pad(entry.method ?? "GET", 6)
    let id = Self.pad("#\(entry.id)", 5)
    let plainHead = "\(Self.clock(entry.time))  \(id) \(method) \(Self.pad(status, 4)) "
      + "\(Self.pad(duration, 7)) "
    var address = entry.url ?? ""
    var tail = ""
    if let error = entry.error, entry.failed == true { tail = "  " + error }
    if let width {
      let room = max(20, width - plainHead.count - tail.count)
      if address.count > room { address = String(address.prefix(room - 1)) + "…" }
    }
    return paint(Self.clock(entry.time), "2") + "  " + paint(id, "2") + " " + paint(method, "1") + " "
      + paint(Self.pad(status, 4), statusColor) + " "
      + paint(Self.pad(duration, 7), "2") + " " + address
      + (tail.isEmpty ? "" : paint(tail, "31"))
  }

  private func navigationLine(_ entry: WebLogEntry) -> String {
    paint("──── " + (entry.text ?? "") + " ────", "2;36")
  }

  // MARK: Detail

  /// A request in full: status, headers, payload and response (the secrets already masked).
  public func detail(_ entry: WebLogEntry) -> String {
    var out: [String] = [line(entry), ""]
    if let url = entry.url { out.append(paint("URL", "1") + "       " + url) }
    var summary: [String] = []
    if let status = entry.status {
      summary.append(entry.failed == true ? "no response" : "\(status) \(entry.statusText ?? "")"
        .trimmingCharacters(in: .whitespaces))
    } else {
      summary.append("still running")
    }
    if let duration = entry.durationMs { summary.append(Self.duration(duration)) }
    if let via = entry.via { summary.append("via \(via)") }
    out.append(paint("Status", "1") + "    " + summary.joined(separator: "  ·  "))
    if let error = entry.error { out.append(paint("Error", "1") + "     " + paint(error, "31")) }
    out += section("Request headers", headers: entry.requestHeaders)
    out += section("Request body", body: entry.requestBody)
    out += section("Response headers", headers: entry.responseHeaders)
    out += section("Response body" + (entry.contentType.map { $0.isEmpty ? "" : " (\($0))" } ?? ""),
                   body: entry.responseBody)
    return out.joined(separator: "\n")
  }

  private func section(_ title: String, headers: [String: String]?) -> [String] {
    guard let headers, !headers.isEmpty else { return [] }
    return ["", paint(title, "1")] + headers.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }
  }

  private func section(_ title: String, body: String?) -> [String] {
    guard let body, !body.isEmpty else { return [] }
    let shown = Self.pretty(body)
    return ["", paint(title, "1")] + shown.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }
  }

  // MARK: Pieces

  /// HH:mm:ss.SSS in the local time zone.
  public static func clock(_ time: Double) -> String {
    let parts = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond],
                                                from: Date(timeIntervalSince1970: time))
    return String(format: "%02ld:%02ld:%02ld.%03ld", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
                  (parts.nanosecond ?? 0) / 1_000_000)
  }

  static func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
  }

  public static func duration(_ milliseconds: Int) -> String {
    milliseconds >= 1000 ? String(format: "%.1fs", Double(milliseconds) / 1000) : "\(milliseconds)ms"
  }

  /// `body` indented as JSON when it is whole JSON; else unchanged.
  public static func pretty(_ body: String) -> String {
    guard !body.contains("… ["), let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          object is [Any] || object is [String: Any],
          let formatted = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { return body }
    return String(decoding: formatted, as: UTF8.self)
  }

  private static func levelColor(_ level: String) -> String {
    switch level {
    case "error": "1;31"
    case "warn": "1;33"
    case "info": "36"
    case "debug": "2"
    default: "0"
    }
  }

  private func paint(_ text: String, _ code: String) -> String {
    color && !text.isEmpty ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
}
