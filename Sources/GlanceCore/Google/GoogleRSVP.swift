import Foundation

/// Declining a meeting in Google Calendar (spec 2026-10-09-meeting-decline-rsvp-design.md, "GoogleRSVP +
/// CalendarRSVP"):
/// 1. Find the event by its iCal UID in the primary calendar; for a series, find this occurrence.
/// 2. Set only your own attendee's response to declined, and send the whole attendee list back (PATCH replaces
///    arrays). Google tells the organizer.
/// The transport and the token come in as closures, so the sequence runs in tests without a network.
public enum GoogleRSVP {
  public enum Failure: Error, Equatable, Sendable {
    case offline
    /// Not in the signed-in account's primary calendar (another account's, iCloud, Exchange).
    case notOnGoogle(String)
    /// No attendee is you: your own event without guests.
    case notInvited
    case organizer
    case signInExpired
    case refused(Int)
  }

  public typealias Send = @Sendable (URLRequest) async throws -> (Data, Int)
  /// An access token; `true` asks for a fresh one after a 401. Throws `Failure.signInExpired` when Google refuses.
  public typealias Token = @Sendable (_ refresh: Bool) async throws -> String

  static let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"

  public static func message(for failure: Failure) -> String {
    switch failure {
    case .offline: "Couldn't reach Google. Check the connection."
    case .notOnGoogle(let email): "This meeting isn't on \(email)'s calendar."
    case .notInvited: "You're not a guest on this one, so there's nothing to decline."
    case .organizer: "You're the organizer. Cancel it in Google Calendar."
    case .signInExpired: "Google sign-in expired."
    case .refused(let status): "Google Calendar said no (\(status))."
    }
  }

  public static func decline(iCalUID: String?, start: Date, email: String, token: @escaping Token,
                             send: @escaping Send) async throws {
    guard let iCalUID, !iCalUID.isEmpty else { throw Failure.notOnGoogle(email) }
    let client = Client(token: token, send: send)
    let found = try await client.items("\(base)?iCalUID=\(query(iCalUID))&showDeleted=false")
    var event: [String: Any]
    switch pick(found, start: start) {
    case .event(let item):
      event = item
    case .series(let id):
      let window = "timeMin=\(rfc3339(start.addingTimeInterval(-60)))&timeMax=\(rfc3339(start.addingTimeInterval(60)))"
      guard case .event(let item) = pick(try await client.items("\(base)/\(path(id))/instances?\(window)"),
                                         start: start) else { throw Failure.notOnGoogle(email) }
      event = item
    case .none:
      throw Failure.notOnGoogle(email)
    }
    let body = try declinePatch(event: event)
    guard let id = event["id"] as? String else { throw Failure.notOnGoogle(email) }
    _ = try await client.call("PATCH", "\(base)/\(path(id))?sendUpdates=all", body: body)
  }

  enum Pick {
    case event([String: Any])
    case series(String)
    case none
  }

  /// The one-off event or exception starting at `start`, else a recurring series to look inside.
  static func pick(_ items: [[String: Any]], start: Date) -> Pick {
    let atStart = { (item: [String: Any]) in startDate(item).map { abs($0.timeIntervalSince(start)) < 1 } == true }
    if let item = items.first(where: { $0["recurrence"] == nil && atStart($0) }) { return .event(item) }
    if let series = items.first(where: { $0["recurrence"] != nil }), let id = series["id"] as? String {
      return .series(id)
    }
    return .none
  }

  /// `{"attendees": [...]}`: every attendee as Google sent it, with your own response set to declined.
  static func declinePatch(event: [String: Any]) throws -> Data {
    var attendees = event["attendees"] as? [[String: Any]] ?? []
    guard let mine = attendees.firstIndex(where: { $0["self"] as? Bool == true }) else { throw Failure.notInvited }
    let organizing = (event["organizer"] as? [String: Any])?["self"] as? Bool == true
    if organizing || attendees[mine]["organizer"] as? Bool == true { throw Failure.organizer }
    attendees[mine]["responseStatus"] = "declined"
    return try JSONSerialization.data(withJSONObject: ["attendees": attendees])
  }

  static func startDate(_ item: [String: Any]) -> Date? {
    guard let text = (item["start"] as? [String: Any])?["dateTime"] as? String else { return nil }
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }

  static func rfc3339(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  private static func query(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
  }

  private static func path(_ id: String) -> String { query(id) }

  /// One Google Calendar call with the bearer token; a 401 gets one fresh token and one retry.
  private struct Client {
    let token: Token
    let send: Send

    func items(_ url: String) async throws -> [[String: Any]] {
      let data = try await call("GET", url, body: nil)
      return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["items"] as? [[String: Any]] ?? []
    }

    func call(_ method: String, _ url: String, body: Data?) async throws -> Data {
      var refreshed = false
      while true {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("Bearer \(try await token(refreshed))", forHTTPHeaderField: "Authorization")
        if let body {
          request.httpBody = body
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, status): (Data, Int)
        do {
          (data, status) = try await send(request)
        } catch is URLError {
          throw Failure.offline
        }
        switch status {
        case 200..<300: return data
        case 401 where !refreshed: refreshed = true
        case 401: throw Failure.signInExpired
        default: throw Failure.refused(status)
        }
      }
    }
  }
}
