import Foundation
import Testing
@testable import GlanceCore

private let start = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z

/// Google's answers in order, and the requests Glance made.
private actor FakeGoogle {
  var answers: [(Int, String)]
  var requests: [URLRequest] = []
  var refreshes = 0

  init(_ answers: [(Int, String)]) { self.answers = answers }

  func send(_ request: URLRequest) throws -> (Data, Int) {
    requests.append(request)
    guard !answers.isEmpty else { throw URLError(.badServerResponse) }
    let (status, body) = answers.removeFirst()
    return (Data(body.utf8), status)
  }

  func token(_ refresh: Bool) -> String {
    if refresh { refreshes += 1 }
    return refresh ? "fresh" : "stale"
  }
}

private func decline(_ fake: FakeGoogle, uid: String? = "abc@google.com") async throws {
  try await GoogleRSVP.decline(iCalUID: uid, start: start, email: "me@example.com",
                               token: { try await fake.token($0) }, send: { try await fake.send($0) })
}

private let attendees = #"""
[{"email":"boss@example.com","organizer":true,"responseStatus":"accepted"},
 {"email":"me@example.com","self":true,"responseStatus":"needsAction","comment":"maybe","additionalGuests":1}]
"""#

@Test func aOneOffMeetingIsDeclinedInPlace() async throws {
  let list = #"{"items":[{"id":"e1","start":{"dateTime":"2027-01-15T09:00:00+01:00"},"organizer":{"email":"boss@example.com"},"attendees":\#(attendees)}]}"#
  let fake = FakeGoogle([(200, list), (200, "{}")])
  try await decline(fake)
  let requests = await fake.requests
  #expect(requests.count == 2)
  #expect(requests[0].httpMethod == "GET")
  #expect(requests[0].url?.absoluteString
    == "https://www.googleapis.com/calendar/v3/calendars/primary/events?iCalUID=abc%40google.com&showDeleted=false")
  #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer stale")
  #expect(requests[1].httpMethod == "PATCH")
  #expect(requests[1].url?.absoluteString
    == "https://www.googleapis.com/calendar/v3/calendars/primary/events/e1?sendUpdates=all")
  let body = try JSONSerialization.jsonObject(with: try #require(requests[1].httpBody)) as? [String: Any]
  let sent = try #require(body?["attendees"] as? [[String: Any]])
  #expect(sent.count == 2)
  #expect(sent[0]["responseStatus"] as? String == "accepted")
  #expect(sent[1]["responseStatus"] as? String == "declined")
  #expect(sent[1]["comment"] as? String == "maybe")
  #expect(sent[1]["additionalGuests"] as? Int == 1)
}

@Test func aRepeatingMeetingDeclinesOnlyThisOccurrence() async throws {
  let list = #"{"items":[{"id":"series","recurrence":["RRULE:FREQ=DAILY"],"start":{"dateTime":"2027-01-01T08:00:00Z"},"attendees":\#(attendees)}]}"#
  let instances = #"{"items":[{"id":"series_20270114T080000Z","start":{"dateTime":"2027-01-14T08:00:00Z"},"attendees":\#(attendees)},{"id":"series_20270115T080000Z","start":{"dateTime":"2027-01-15T08:00:00Z"},"attendees":\#(attendees)}]}"#
  let fake = FakeGoogle([(200, list), (200, instances), (200, "{}")])
  try await decline(fake)
  let requests = await fake.requests
  #expect(requests[1].url?.absoluteString
    == "https://www.googleapis.com/calendar/v3/calendars/primary/events/series/instances?timeMin=2027-01-15T07:59:00Z&timeMax=2027-01-15T08:01:00Z")
  #expect(requests[2].url?.path == "/calendar/v3/calendars/primary/events/series_20270115T080000Z")
}

@Test func aMovedOccurrenceIsFoundAsAnException() async throws {
  let list = #"{"items":[{"id":"series","recurrence":["RRULE:FREQ=DAILY"],"start":{"dateTime":"2027-01-01T07:00:00Z"}},{"id":"series_20270115T070000Z","recurringEventId":"series","start":{"dateTime":"2027-01-15T08:00:00Z"},"attendees":\#(attendees)}]}"#
  let fake = FakeGoogle([(200, list), (200, "{}")])
  try await decline(fake)
  #expect(await fake.requests.last?.url?.path == "/calendar/v3/calendars/primary/events/series_20270115T070000Z")
}

@Test func notOnThisGoogleAccount() async {
  await #expect(throws: GoogleRSVP.Failure.notOnGoogle("me@example.com")) {
    try await decline(FakeGoogle([(200, #"{"items":[]}"#)]))
  }
  await #expect(throws: GoogleRSVP.Failure.notOnGoogle("me@example.com")) {
    try await decline(FakeGoogle([]), uid: nil)
  }
}

@Test func notAGuestOrTheOrganizer() async {
  let mine = #"{"items":[{"id":"e1","start":{"dateTime":"2027-01-15T08:00:00Z"},"organizer":{"self":true}}]}"#
  await #expect(throws: GoogleRSVP.Failure.notInvited) { try await decline(FakeGoogle([(200, mine)])) }
  let hosting = #"{"items":[{"id":"e1","start":{"dateTime":"2027-01-15T08:00:00Z"},"organizer":{"self":true},"attendees":[{"email":"me@example.com","self":true,"organizer":true}]}]}"#
  await #expect(throws: GoogleRSVP.Failure.organizer) { try await decline(FakeGoogle([(200, hosting)])) }
}

@Test func anExpiredTokenIsRefreshedOnce() async throws {
  let list = #"{"items":[{"id":"e1","start":{"dateTime":"2027-01-15T08:00:00Z"},"attendees":\#(attendees)}]}"#
  let fake = FakeGoogle([(401, "{}"), (200, list), (200, "{}")])
  try await decline(fake)
  #expect(await fake.refreshes == 1)
  #expect(await fake.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
  await #expect(throws: GoogleRSVP.Failure.signInExpired) {
    try await decline(FakeGoogle([(401, "{}"), (401, "{}")]))
  }
}

@Test func offlineAndRefusals() async {
  await #expect(throws: GoogleRSVP.Failure.offline) {
    try await GoogleRSVP.decline(iCalUID: "a", start: start, email: "me@example.com", token: { _ in "t" },
                                 send: { _ in throw URLError(.notConnectedToInternet) })
  }
  let list = #"{"items":[{"id":"e1","start":{"dateTime":"2027-01-15T08:00:00Z"},"attendees":\#(attendees)}]}"#
  await #expect(throws: GoogleRSVP.Failure.refused(403)) {
    try await decline(FakeGoogle([(200, list), (403, "{}")]))
  }
}

@Test func messagesSayWhatHappened() {
  #expect(GoogleRSVP.message(for: .offline) == "Couldn't reach Google. Check the connection.")
  #expect(GoogleRSVP.message(for: .notOnGoogle("me@example.com")) == "This meeting isn't on me@example.com's calendar.")
  #expect(GoogleRSVP.message(for: .notInvited) == "You're not a guest on this one, so there's nothing to decline.")
  #expect(GoogleRSVP.message(for: .organizer) == "You're the organizer. Cancel it in Google Calendar.")
  #expect(GoogleRSVP.message(for: .signInExpired) == "Google sign-in expired.")
  #expect(GoogleRSVP.message(for: .refused(403)) == "Google Calendar said no (403).")
}
