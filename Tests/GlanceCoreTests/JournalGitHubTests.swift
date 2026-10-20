import Foundation
import Testing
@testable import GlanceCore

private let utc = JournalDay.calendar(timeZone: TimeZone(identifier: "UTC")!)
private let october9 = JournalDay(key: "2026-10-09")!.interval(in: utc)

private let payload = """
  {
    "viewer": {"login": "me"},
    "opened": {"nodes": [
      {"id": "PR1", "number": 12, "title": "Add journal", "url": "https://github.com/o/r/pull/12",
       "createdAt": "2026-10-09T05:00:00Z", "mergedAt": null, "additions": 120, "deletions": 4,
       "repository": {"nameWithOwner": "o/r"}},
      {"id": "PR0", "number": 11, "title": "Older", "url": "u", "createdAt": "2026-10-08T05:00:00Z",
       "mergedAt": null, "additions": 1, "deletions": 1, "repository": {"nameWithOwner": "o/r"}}
    ]},
    "merged": {"nodes": [
      {"id": "PR2", "number": 7, "title": "Cache fix", "url": "u2", "createdAt": "2026-10-01T00:00:00Z",
       "mergedAt": "2026-10-09T09:00:00Z", "additions": 10, "deletions": 2,
       "repository": {"nameWithOwner": "o/other"}}
    ]},
    "reviewed": {"nodes": [
      {"id": "PR3", "number": 40, "title": "Speed up startup", "url": "u3", "createdAt": "2026-10-05T00:00:00Z",
       "mergedAt": null, "additions": 5, "deletions": 5, "repository": {"nameWithOwner": "o/r"},
       "reviews": {"nodes": [
         {"id": "R1", "state": "APPROVED", "submittedAt": "2026-10-09T11:00:00Z", "author": {"login": "me"},
          "comments": {"totalCount": 3}},
         {"id": "R2", "state": "COMMENTED", "submittedAt": "2026-10-09T11:30:00Z", "author": {"login": "someone"},
          "comments": {"totalCount": 1}},
         {"id": "R3", "state": "PENDING", "submittedAt": null, "author": {"login": "me"}, "comments": {"totalCount": 0}},
         {"id": "R4", "state": "COMMENTED", "submittedAt": "2026-10-07T11:30:00Z", "author": {"login": "me"},
          "comments": {"totalCount": 0}}
       ]}}
    ]}
  }
  """

private func parsed() -> [JournalEvent] {
  let data = try! JSONSerialization.jsonObject(with: Data(payload.utf8)) as! [String: Any]
  return JournalGitHub.parse(data, range: october9, calendar: utc,
                             folders: RepositoryFolders(["o/r": "/Users/me/Code/r"]))
}

@Test func openedMergedAndReviewedInTheRangeBecomeEvents() {
  let events = parsed()
  #expect(events.map(\.id) == ["pr:PR1:opened", "pr:PR2:merged", "review:R1"])
  #expect(events[0].source == .pr)
  #expect(events[0].detail.action == "opened")
  #expect(events[0].detail.number == 12)
  #expect(events[0].detail.insertions == 120)
  #expect(events[1].detail.action == "merged")
  #expect(events[2].source == .review)
  #expect(events[2].detail.reviewState == "approved")
  #expect(events[2].detail.comments == 3)
  #expect(events[2].title == "Speed up startup")
}

@Test func aRepositoryWithAFolderOnThisMacIsThatProject() {
  let events = parsed()
  #expect(events[0].project == "/Users/me/Code/r")
  #expect(events[1].project == "o/other")
  #expect(events[0].detail.repository == "o/r")
}

@Test func theSearchCoversADayEitherSideForTimeZones() {
  let arguments = JournalGitHub.searchArguments(days: [JournalDay(key: "2026-10-09")!], calendar: utc)
  #expect(arguments.prefix(2) == ["api", "graphql"])
  #expect(arguments.contains("opened=is:pr author:@me created:2026-10-08..2026-10-10"))
  #expect(arguments.contains("merged=is:pr author:@me merged:2026-10-08..2026-10-10"))
  #expect(arguments.contains("reviewed=is:pr reviewed-by:@me updated:>=2026-10-08"))
  #expect(JournalGitHub.searchArguments(days: [], calendar: utc).isEmpty)
}
