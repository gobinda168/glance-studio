import Foundation
import Testing
@testable import GlanceCore

@Test func theURLFieldWinsOverLocationAndNotes() {
  let link = MeetingLink.find(url: "https://meet.google.com/abc-defg-hij", location: "https://zoom.us/j/1",
                              notes: "https://teams.microsoft.com/l/meetup-join/x")
  #expect(link?.provider == .meet)
  #expect(link?.url.absoluteString == "https://meet.google.com/abc-defg-hij")
}

@Test func eachProviderIsFoundInNotes() {
  #expect(MeetingLink.find(url: nil, location: nil, notes: "Join: https://acme.zoom.us/j/8123?pwd=xy")?.provider == .zoom)
  #expect(MeetingLink.find(url: nil, location: nil,
                           notes: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0")?.provider == .teams)
  #expect(MeetingLink.find(url: nil, location: nil, notes: "https://teams.live.com/meet/9876")?.provider == .teams)
  #expect(MeetingLink.find(url: nil, location: nil, notes: "https://acme.webex.com/meet/ana")?.provider == .webex)
  #expect(MeetingLink.find(url: nil, location: "meet.google.com/abc-defg-hij", notes: nil)?.provider == .meet)
}

@Test func otherLinksAreSkipped() {
  let link = MeetingLink.find(url: "https://docs.google.com/doc", location: "Room 4",
                              notes: "Agenda https://example.com then https://meet.google.com/aaa-bbbb-ccc")
  #expect(link?.url.absoluteString == "https://meet.google.com/aaa-bbbb-ccc")
  #expect(MeetingLink.find(url: nil, location: "Room 4", notes: "No call") == nil)
  #expect(MeetingLink.find(url: nil, location: nil, notes: "https://zoom.us/pricing") == nil)
}

@Test func punctuationAndBracketsAreTrimmed() {
  #expect(MeetingLink.find(url: nil, location: nil, notes: "Call <https://acme.zoom.us/j/555>.")?.url.absoluteString
    == "https://acme.zoom.us/j/555")
  #expect(MeetingLink.find(url: nil, location: nil, notes: "(https://meet.google.com/abc-defg-hij).")?.url.absoluteString
    == "https://meet.google.com/abc-defg-hij")
}

@Test func googleRedirectsAreUnwrapped() {
  let notes = "https://www.google.com/url?q=https%3A%2F%2Facme.zoom.us%2Fj%2F42%3Fpwd%3Dz&sa=D"
  #expect(MeetingLink.find(url: nil, location: nil, notes: notes)?.url.absoluteString == "https://acme.zoom.us/j/42?pwd=z")
}

@Test func zoomAndTeamsHaveAppLinks() {
  let zoom = MeetingLink.find(url: "https://acme.zoom.us/j/8123?pwd=xy", location: nil, notes: nil)
  #expect(zoom?.appURL?.absoluteString == "zoommtg://acme.zoom.us/join?action=join&confno=8123&pwd=xy")
  let teams = MeetingLink.find(url: "https://teams.microsoft.com/l/meetup-join/19%3ameeting%40thread.v2/0", location: nil,
                               notes: nil)
  #expect(teams?.appURL?.absoluteString == "msteams:/l/meetup-join/19%3ameeting%40thread.v2/0")
  #expect(MeetingLink.find(url: "https://meet.google.com/abc-defg-hij", location: nil, notes: nil)?.appURL == nil)
}

@Test func newerTeamsAndZoomWebLinksAreFound() {
  let teams = MeetingLink.find(url: nil, location: nil, notes: "https://teams.microsoft.com/meet/123456789?p=abc")
  #expect(teams?.provider == .teams)
  #expect(teams?.appURL == nil)
  #expect(MeetingLink.find(url: nil, location: nil, notes: "https://acme.zoom.us/wc/join/123")?.provider == .zoom)
}

@Test func zoomInvitesOpenInTheBrowserClient() {
  let zoom = MeetingLink(provider: .zoom, url: URL(string: "https://acme.zoom.us/j/8123?pwd=xy&uname=Ana")!)
  #expect(zoom.webURL.absoluteString == "https://acme.zoom.us/wc/8123/join?pwd=xy")
  let meet = MeetingLink(provider: .meet, url: URL(string: "https://meet.google.com/abc-defg-hij")!)
  #expect(meet.webURL == meet.url)
}
