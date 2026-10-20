import Foundation
import Testing
@testable import GlanceCore

private let utc = TimeZone(identifier: "UTC")!
// 16 Oct 2026, 14:32 UTC.
private let at = Date(timeIntervalSince1970: 1_792_161_120)

@Test func quickNoteAddsUnderAStampLine() {
  let body = NoteDoc.appending("Retry-After is in seconds", to: "# Standup\n\n- billing chart\n", source: "Safari",
                               at: at, timeZone: utc)
  #expect(body == "# Standup\n\n- billing chart\n\n— 16 Oct, 14:32 · from Safari\n\nRetry-After is in seconds")
}

@Test func quickNoteOnAnEmptyNoteStartsWithTheStamp() {
  #expect(NoteDoc.appending("one", to: "  \n", source: nil, at: at, timeZone: utc) == "— 16 Oct, 14:32\n\none")
}

@Test func quickNoteTrimsWhatItAdds() {
  #expect(NoteDoc.appending("\n  two lines\nhere \n\n", to: "a", source: "", at: at, timeZone: utc)
    == "a\n\n— 16 Oct, 14:32\n\ntwo lines\nhere")
}
