import Foundation
import Testing
@testable import GlanceCore

private let list = Data("""
[{"id":"101","unread":true,"reason":"review_requested","updated_at":"2026-10-09T10:00:00Z",
  "subject":{"title":"Add notifications","url":"https://api.github.com/repos/acme/api/pulls/412",
             "latest_comment_url":null,"type":"PullRequest"},"repository":{"full_name":"acme/api"}},
 {"id":"102","unread":true,"reason":"comment","updated_at":"2026-10-09T10:05:00Z",
  "subject":{"title":"Fix login","url":"https://api.github.com/repos/acme/api/pulls/77",
             "latest_comment_url":"https://api.github.com/repos/acme/api/pulls/comments/555","type":"PullRequest"},
  "repository":{"full_name":"acme/api"}},
 {"id":"103","unread":true,"reason":"ci_activity","updated_at":"2026-10-09T10:06:00Z",
  "subject":{"title":"CI workflow run failed for main branch","url":null,"latest_comment_url":null,"type":"CheckSuite"},
  "repository":{"full_name":"acme/api"}},
 {"id":"104","unread":true,"reason":"mention","updated_at":"2026-10-09T10:07:00Z",
  "subject":{"title":"Crash on start","url":"https://api.github.com/repos/acme/web/issues/9",
             "latest_comment_url":"https://api.github.com/repos/acme/web/issues/comments/9001","type":"Issue"},
  "repository":{"full_name":"acme/web"}}]
""".utf8)

private let reviewComment = Data("""
{"id":555,"user":{"login":"riya","avatar_url":"https://avatars.example/riya"},"body":"Can this be nil?\\nThanks",
 "path":"Sources/A.swift","line":42,"in_reply_to_id":550,
 "pull_request_url":"https://api.github.com/repos/acme/api/pulls/77","created_at":"2026-10-09T10:05:00Z"}
""".utf8)

@Test func threadsParse() {
  let threads = GitHubNotices.threads(list)
  #expect(threads.count == 4)
  #expect(threads[0] == GitHubNotices.Thread(id: "101", reason: "review_requested",
    updatedAt: ISO8601DateFormatter().date(from: "2026-10-09T10:00:00Z")!, title: "Add notifications",
    type: "PullRequest", repository: "acme/api", number: 412, isPullRequest: true, latestCommentURL: nil))
  #expect(threads[3].number == 9 && !threads[3].isPullRequest)
  #expect(threads[2].number == nil)
}

@Test func reasonsMapToKinds() {
  #expect(GitHubNotices.kind(reason: "review_requested", type: "PullRequest", title: "") == .githubReviewRequested)
  #expect(GitHubNotices.kind(reason: "team_mention", type: "Issue", title: "") == .githubMention)
  #expect(GitHubNotices.kind(reason: "assign", type: "Issue", title: "") == .githubAssigned)
  #expect(GitHubNotices.kind(reason: "ci_activity", type: "CheckSuite", title: "CI workflow run failed for main") == .githubCIFailed)
  #expect(GitHubNotices.kind(reason: "ci_activity", type: "CheckSuite", title: "CI workflow run succeeded") == .githubOther)
  #expect(GitHubNotices.kind(reason: "state_change", type: "PullRequest", title: "") == .githubStateChanged)
  #expect(GitHubNotices.kind(reason: "author", type: "PullRequest", title: "") == .githubComment)
  #expect(GitHubNotices.kind(reason: "subscribed", type: "Release", title: "") == .githubOther)
}

@Test func aReviewCommentNoticeOpensAtItsLine() throws {
  let thread = GitHubNotices.threads(list)[1]
  let comment = try #require(GitHubNotices.comment(reviewComment))
  #expect(comment.isReview && comment.inReplyTo == 550 && comment.line == 42)
  let n = try #require(GitHubNotices.notice(thread, comment: comment, me: "gobinda168"))
  #expect(n.kind == .githubComment)
  #expect(n.title == "riya")
  #expect(n.place == "acme/api #77")
  #expect(n.preview == "Can this be nil? Thanks")
  #expect(n.threadKey == "github:acme/api#77")
  #expect(n.target == .pullRequest(repository: "acme/api", number: 77, path: "Sources/A.swift", line: 42))
  #expect(n.meta["thread"] == "102" && n.meta["comment"] == "555")
  #expect(n.people == ["riya"])
}

@Test func aNoticeWithoutACommentUsesTheSubject() throws {
  let n = try #require(GitHubNotices.notice(GitHubNotices.threads(list)[0], comment: nil, me: nil))
  #expect(n.title == "Add notifications")
  #expect(n.place == "acme/api #412")
  #expect(n.preview == "Review requested")
  #expect(n.id == "github:101:\(GitHubNotices.threads(list)[0].updatedAt.timeIntervalSince1970)")
}

@Test func myOwnCommentIsNoNotice() throws {
  let comment = try #require(GitHubNotices.comment(reviewComment))
  #expect(GitHubNotices.notice(GitHubNotices.threads(list)[1], comment: comment, me: "Riya") == nil)
}

@Test func ciWithoutANumberThreadsByGitHubThread() throws {
  let n = try #require(GitHubNotices.notice(GitHubNotices.threads(list)[2], comment: nil, me: nil))
  #expect(n.threadKey == "github:thread:103")
  #expect(n.target == .none)
}

@Test func headersAndBodySplit() {
  let raw = Data("HTTP/2.0 200 OK\r\nX-Poll-Interval: 120\r\nContent-Type: application/json\r\n\r\n[]".utf8)
  let (headers, body) = GitHubNotices.splitResponse(raw)
  #expect(GitHubNotices.pollInterval(headers: headers) == 120)
  #expect(String(decoding: body, as: UTF8.self) == "[]")
}

@Test func repliesGoToTheRightEndpoint() throws {
  let comment = try #require(GitHubNotices.comment(reviewComment))
  #expect(GitHubNotices.replyArguments(repository: "acme/api", number: 77, comment: comment, body: "Yes")
          == ["api", "repos/acme/api/pulls/77/comments/550/replies", "-f", "body=Yes"])
  #expect(GitHubNotices.replyArguments(repository: "acme/web", number: 9,
            comment: .init(id: 9001, author: "a", body: "", avatarURL: nil, path: nil, line: nil, inReplyTo: nil, isReview: false, createdAt: nil),
            body: "Ok") == ["api", "repos/acme/web/issues/9/comments", "-f", "body=Ok"])
  #expect(GitHubNotices.apiPath("https://api.github.com/repos/acme/api/pulls/comments/555") == "repos/acme/api/pulls/comments/555")
}

@Test func aReviewThreadIsItsRootAndReplies() {
  let all = Data("""
  [{"id":550,"user":{"login":"me"},"body":"root","path":"A","line":1},
   {"id":551,"user":{"login":"x"},"body":"other","path":"B","line":2},
   {"id":555,"user":{"login":"riya"},"body":"reply","in_reply_to_id":550,"path":"A","line":1}]
  """.utf8)
  let root = GitHubNotices.Comment(id: 555, author: "riya", body: "reply", avatarURL: nil, path: "A", line: 1, inReplyTo: 550, isReview: true, createdAt: nil)
  #expect(GitHubNotices.threadComments(all, around: root, isReview: true).map(\.id) == [550, 555])
}
