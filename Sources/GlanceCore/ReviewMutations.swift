import Foundation

/// The review's writes (spec 2026-10-07-pr-manager-design.md, "GitHub → Writes"), as `gh api graphql` arguments:
/// - the pending review: start one, add a thread, edit and delete a comment, submit;
/// - replies, which post at once;
/// - resolving and unresolving;
/// - viewed files.
///
/// Each asks GitHub for `clientMutationId` alone, except starting a review: the next writes need its id.
public enum ReviewMutations {
  public typealias Side = ReviewThreads.Thread.Side

  /// Finish review's verdicts.
  public enum Event: String, Sendable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
  }

  /// Starts the viewer's pending review: no verdict, so it stays pending until it's submitted.
  public static func startReview(pullRequestID: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($pullRequestId: ID!) { addPullRequestReview(input: {pullRequestId: $pullRequestId}) { \
      pullRequestReview { id } } }
      """, variables: ["pullRequestId": .string(pullRequestID)])
  }

  /// The id of the review `startReview` started.
  public static func reviewID(from data: Data) -> String? {
    guard case .success(let payload) = GitHubCLI.graphQLData(data) else { return nil }
    let review = (payload["addPullRequestReview"] as? [String: Any])?["pullRequestReview"] as? [String: Any]
    return review?["id"] as? String
  }

  /// A new thread in the pending review on `line` of `side`, from `startLine` of `startSide` for a range.
  public static func addThread(reviewID: String, path: String, body: String, line: Int, side: Side, startLine: Int?,
                               startSide: Side?) -> [String] {
    var variables: [String: GitHubCLI.Variable] = [
      "reviewId": .string(reviewID), "path": .string(path), "body": .string(body), "line": .int(line),
      "side": .string(side.rawValue),
    ]
    if let startLine { variables["startLine"] = .int(startLine) }
    if let startSide { variables["startSide"] = .string(startSide.rawValue) }
    return GitHubCLI.graphQLArguments("""
      mutation($reviewId: ID!, $path: String!, $body: String!, $line: Int!, $side: DiffSide!, $startLine: Int, \
      $startSide: DiffSide) { addPullRequestReviewThread(input: {pullRequestReviewId: $reviewId, path: $path, \
      body: $body, line: $line, side: $side, startLine: $startLine, startSide: $startSide}) { clientMutationId } }
      """, variables: variables)
  }

  /// A reply to a thread, posted at once.
  public static func reply(threadID: String, body: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($threadId: ID!, $body: String!) { addPullRequestReviewThreadReply(input: \
      {pullRequestReviewThreadId: $threadId, body: $body}) { clientMutationId } }
      """, variables: ["threadId": .string(threadID), "body": .string(body)])
  }

  public static func editComment(id: String, body: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($id: ID!, $body: String!) { updatePullRequestReviewComment(input: \
      {pullRequestReviewCommentId: $id, body: $body}) { clientMutationId } }
      """, variables: ["id": .string(id), "body": .string(body)])
  }

  public static func deleteComment(id: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($id: ID!) { deletePullRequestReviewComment(input: {id: $id}) { clientMutationId } }
      """, variables: ["id": .string(id)])
  }

  public static func resolve(threadID: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { clientMutationId } }
      """, variables: ["threadId": .string(threadID)])
  }

  public static func unresolve(threadID: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($threadId: ID!) { unresolveReviewThread(input: {threadId: $threadId}) { clientMutationId } }
      """, variables: ["threadId": .string(threadID)])
  }

  /// Marks a file viewed, or not, for the viewer (GitHub's Viewed box).
  public static func setViewed(pullRequestID: String, path: String, viewed: Bool) -> [String] {
    let mutation = viewed ? "markFileAsViewed" : "unmarkFileAsViewed"
    return GitHubCLI.graphQLArguments("""
      mutation($pullRequestId: ID!, $path: String!) { \(mutation)(input: {pullRequestId: $pullRequestId, \
      path: $path}) { clientMutationId } }
      """, variables: ["pullRequestId": .string(pullRequestID), "path": .string(path)])
  }

  /// Submits the pending review with its verdict and summary.
  public static func submit(reviewID: String, event: Event, body: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($reviewId: ID!, $event: PullRequestReviewEvent!, $body: String) { submitPullRequestReview(input: \
      {pullRequestReviewId: $reviewId, event: $event, body: $body}) { clientMutationId } }
      """, variables: ["reviewId": .string(reviewID), "event": .string(event.rawValue), "body": .string(body)])
  }

  /// A review with no pending comments: the verdict and the summary, posted at once.
  public static func review(pullRequestID: String, event: Event, body: String) -> [String] {
    GitHubCLI.graphQLArguments("""
      mutation($pullRequestId: ID!, $event: PullRequestReviewEvent!, $body: String) { addPullRequestReview(input: \
      {pullRequestId: $pullRequestId, event: $event, body: $body}) { clientMutationId } }
      """, variables: ["pullRequestId": .string(pullRequestID), "event": .string(event.rawValue),
                       "body": .string(body)])
  }
}
