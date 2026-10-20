import Foundation

/// GitHub's notifications (`gh api notifications`) and the comments they point at, as notices (spec
/// 2026-10-09-notifications-design.md, "Sources → GitHub"), plus the `gh` arguments the poller, the read-sync and the
/// quick-reply panel run. Pure: no network here.
public enum GitHubNotices {
  /// One notification thread: something on a PR, an issue, a check suite, a release…
  public struct Thread: Equatable, Sendable {
    public let id: String, reason: String, updatedAt: Date, title: String, type: String
    public let repository: String, number: Int?, isPullRequest: Bool, latestCommentURL: String?

    public init(id: String, reason: String, updatedAt: Date, title: String, type: String, repository: String,
                number: Int?, isPullRequest: Bool, latestCommentURL: String?) {
      self.id = id
      self.reason = reason
      self.updatedAt = updatedAt
      self.title = title
      self.type = type
      self.repository = repository
      self.number = number
      self.isPullRequest = isPullRequest
      self.latestCommentURL = latestCommentURL
    }
  }

  /// An issue comment or a PR review comment (`isReview`, with its file and line).
  public struct Comment: Equatable, Sendable {
    public let id: Int, author: String, body: String, avatarURL: URL?, path: String?, line: Int?
    public let inReplyTo: Int?, isReview: Bool, createdAt: Date?

    public init(id: Int, author: String, body: String, avatarURL: URL?, path: String?, line: Int?, inReplyTo: Int?,
                isReview: Bool, createdAt: Date?) {
      self.id = id
      self.author = author
      self.body = body
      self.avatarURL = avatarURL
      self.path = path
      self.line = line
      self.inReplyTo = inReplyTo
      self.isReview = isReview
      self.createdAt = createdAt
    }
  }

  // MARK: Parsing

  /// The threads in a `gh api notifications` body; entries without an id or a date are skipped.
  public static func threads(_ data: Data) -> [Thread] {
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    return array.compactMap(thread)
  }

  /// A comment from `gh api <latest_comment_url>`; nil when it isn't one.
  public static func comment(_ data: Data) -> Comment? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return comment(object)
  }

  // MARK: Mapping

  public static func kind(reason: String, type: String, title: String) -> Notice.Kind {
    switch reason {
    case "review_requested": .githubReviewRequested
    case "mention", "team_mention": .githubMention
    case "assign": .githubAssigned
    case "ci_activity": title.range(of: "fail", options: .caseInsensitive) != nil ? .githubCIFailed : .githubOther
    case "state_change": .githubStateChanged
    case "comment", "author": .githubComment
    default: .githubOther
    }
  }

  /// nil when the comment is the user's own.
  public static func notice(_ thread: Thread, comment: Comment?, me: String?) -> Notice? {
    if let comment, let me, comment.author.caseInsensitiveCompare(me) == .orderedSame { return nil }
    let kind = kind(reason: thread.reason, type: thread.type, title: thread.title)
    let place = thread.number.map { "\(thread.repository) #\($0)" } ?? thread.repository
    let threadKey = thread.number.map { "github:\(thread.repository)#\($0)" } ?? "github:thread:\(thread.id)"
    let target: Notice.Target
    if let number = thread.number, thread.isPullRequest {
      target = .pullRequest(repository: thread.repository, number: number, path: comment?.path, line: comment?.line)
    } else if let number = thread.number, thread.type == "Issue" {
      target = .issue(repository: thread.repository, number: number)
    } else {
      target = .none
    }
    var meta = ["thread": thread.id, "reason": thread.reason, "subject": thread.title,
                "isReview": comment?.isReview == true ? "1" : "0"]
    if let comment { meta["comment"] = String(comment.id) }
    if let reply = comment?.inReplyTo { meta["inReplyTo"] = String(reply) }
    let body = comment?.body.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return Notice(id: "github:\(thread.id):\(thread.updatedAt.timeIntervalSince1970)", source: .github, kind: kind,
                  title: comment?.author ?? thread.title, place: place, preview: body.isEmpty ? kind.label : body,
                  date: thread.updatedAt, threadKey: threadKey, target: target,
                  people: comment.map { [$0.author] } ?? [], avatarURL: comment?.avatarURL, meta: meta)
  }

  /// "https://api.github.com/repos/…" → "repos/…" (what `gh api` takes); an Enterprise host's "/api/v3/" goes too.
  public static func apiPath(_ url: String) -> String {
    guard let components = URLComponents(string: url), components.host != nil else {
      return url.hasPrefix("/") ? String(url.dropFirst()) : url
    }
    var path = components.percentEncodedPath
    if path.hasPrefix("/api/v3/") { path.removeFirst("/api/v3".count) }
    if path.hasPrefix("/") { path.removeFirst() }
    if let query = components.percentEncodedQuery { path += "?" + query }
    return path
  }

  // MARK: gh

  /// Unread notifications, all of them (not only the ones the user takes part in), with headers for X-Poll-Interval.
  public static func listArguments() -> [String] {
    ["api", "-i", "notifications?participating=false&per_page=50"]
  }

  /// GitHub's `X-Poll-Interval` in seconds, from `gh api -i` headers.
  public static func pollInterval(headers: String) -> TimeInterval? {
    for line in headers.split(whereSeparator: \.isNewline) {
      guard let colon = line.firstIndex(of: ":"),
            line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "x-poll-interval" else { continue }
      return Double(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }
    return nil
  }

  /// `gh api -i` output: the status line and headers, then the body after the first blank line.
  public static func splitResponse(_ data: Data) -> (headers: String, body: Data) {
    for separator in [Data("\r\n\r\n".utf8), Data("\n\n".utf8)] {
      if let range = data.range(of: separator) {
        return (String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self),
                Data(data[range.upperBound...]))
      }
    }
    return ("", data)
  }

  /// Marks a thread read on GitHub.
  public static func markReadArguments(threadID: String) -> [String] {
    ["api", "-X", "PATCH", "notifications/threads/\(threadID)"]
  }

  /// A reply: in the review thread for a review comment, else a PR/issue comment.
  public static func replyArguments(repository: String, number: Int, comment: Comment, body: String) -> [String] {
    if comment.isReview {
      return ["api", "repos/\(repository)/pulls/\(number)/comments/\(comment.inReplyTo ?? comment.id)/replies",
              "-f", "body=\(body)"]
    }
    return ["api", "repos/\(repository)/issues/\(number)/comments", "-f", "body=\(body)"]
  }

  /// The comments the quick-reply panel shows: a PR's review comments, or a PR's or issue's conversation.
  public static func threadArguments(repository: String, number: Int, isReview: Bool) -> [String] {
    isReview ? ["api", "repos/\(repository)/pulls/\(number)/comments?per_page=100"]
      : ["api", "repos/\(repository)/issues/\(number)/comments?per_page=100"]
  }

  /// A review comment's thread (its root and the replies to it, in order), or the conversation's last 8 comments.
  public static func threadComments(_ data: Data, around comment: Comment?, isReview: Bool) -> [Comment] {
    guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
    let all = array.compactMap(Self.comment)
    guard isReview, let comment else { return Array(all.suffix(8)) }
    let root = comment.inReplyTo ?? comment.id
    return all.filter { $0.id == root || $0.inReplyTo == root }
  }

  // MARK: Private

  private static func thread(_ object: [String: Any]) -> Thread? {
    guard let id = string(object["id"]), let updated = object["updated_at"] as? String,
          let updatedAt = date(updated) else { return nil }
    let subject = object["subject"] as? [String: Any] ?? [:]
    let repository = (object["repository"] as? [String: Any])?["full_name"] as? String ?? ""
    let type = subject["type"] as? String ?? ""
    var number: Int?
    if let url = subject["url"] as? String, url.contains("/pulls/") || url.contains("/issues/") {
      number = url.split(separator: "/").last.flatMap { Int($0) }
    }
    return Thread(id: id, reason: object["reason"] as? String ?? "", updatedAt: updatedAt,
                  title: subject["title"] as? String ?? "", type: type, repository: repository, number: number,
                  isPullRequest: type == "PullRequest", latestCommentURL: subject["latest_comment_url"] as? String)
  }

  private static func comment(_ object: [String: Any]) -> Comment? {
    guard let id = object["id"] as? Int else { return nil }
    let user = object["user"] as? [String: Any] ?? [:]
    let isReview = object["path"] != nil || object["pull_request_review_id"] != nil
      || object["pull_request_url"] != nil
    return Comment(id: id, author: user["login"] as? String ?? "", body: object["body"] as? String ?? "",
                   avatarURL: (user["avatar_url"] as? String).flatMap(URL.init(string:)),
                   path: object["path"] as? String, line: (object["line"] as? Int) ?? (object["original_line"] as? Int),
                   inReplyTo: object["in_reply_to_id"] as? Int, isReview: isReview,
                   createdAt: (object["created_at"] as? String).flatMap(date))
  }

  /// GitHub sends thread ids as strings; tolerate numbers.
  private static func string(_ value: Any?) -> String? {
    if let text = value as? String { return text }
    if let number = value as? Int { return String(number) }
    return nil
  }

  private static func date(_ text: String) -> Date? {
    ISO8601DateFormatter().date(from: text)
  }
}
