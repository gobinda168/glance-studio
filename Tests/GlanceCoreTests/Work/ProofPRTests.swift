import Foundation
import Testing
@testable import GlanceCore

// Real `gh pr view --json number,url,state,headRefName,statusCheckRollup` output (a check run and a commit status).
private let viewOpen = """
  {"headRefName":"feat/command-center-proof","number":143,"state":"OPEN","statusCheckRollup":[\
  {"__typename":"CheckRun","completedAt":"2026-11-01T10:12:03Z","conclusion":"SUCCESS","detailsUrl":"https://github.com/gobinda168/glance/actions/runs/1/job/2","name":"build","startedAt":"2026-11-01T10:10:00Z","status":"COMPLETED","workflowName":"CI"},\
  {"__typename":"StatusContext","context":"vercel","startedAt":"2026-11-01T10:11:00Z","state":"SUCCESS","targetUrl":"https://vercel.com/x"}],\
  "url":"https://github.com/gobinda168/glance/pull/143"}
  """

private let viewFailing = """
  {"headRefName":"fix/x","number":7,"state":"OPEN","statusCheckRollup":[\
  {"__typename":"CheckRun","conclusion":"FAILURE","name":"test","status":"COMPLETED","workflowName":"CI"},\
  {"__typename":"CheckRun","conclusion":"SUCCESS","name":"lint","status":"COMPLETED","workflowName":"CI"}],\
  "url":"https://github.com/acme/widgets/pull/7"}
  """

@Test func aPRIsReadFromGhPrView() throws {
  let info = try #require(ProofPR.parse(Data(viewOpen.utf8)))
  #expect(info == ProofPR.Info(number: 143, url: "https://github.com/gobinda168/glance/pull/143", state: "OPEN",
                               merged: false, checksFailing: false, head: "feat/command-center-proof",
                               repository: "gobinda168/glance", checks: .passing))
}

@Test func theBranchThePRMergesIntoIsRead() throws {
  let withBase = """
    {"baseRefName":"main","headRefName":"feat/x","number":12,"state":"OPEN","statusCheckRollup":[],"url":"https://github.com/o/r/pull/12"}
    """
  #expect(try #require(ProofPR.parse(Data(withBase.utf8))).base == "main")
  #expect(try #require(ProofPR.parse(Data(viewOpen.utf8))).base.isEmpty)
}

@Test func aFailingCheckMarksThePR() throws {
  let info = try #require(ProofPR.parse(Data(viewFailing.utf8)))
  #expect(info.checksFailing)
  #expect(info.repository == "acme/widgets")
}

@Test func aCancelledOrPendingCheckIsJudgedLikeThePRList() throws {
  let cancelled = """
    {"headRefName":"a","number":1,"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","conclusion":"CANCELLED","status":"COMPLETED"}],"url":"https://github.com/o/r/pull/1"}
    """
  let pending = """
    {"headRefName":"a","number":1,"state":"OPEN","statusCheckRollup":[{"__typename":"CheckRun","conclusion":"","status":"IN_PROGRESS"}],"url":"https://github.com/o/r/pull/1"}
    """
  #expect(try #require(ProofPR.parse(Data(cancelled.utf8))).checksFailing)
  #expect(try !#require(ProofPR.parse(Data(pending.utf8))).checksFailing)
}

@Test func theRepositoryComesFromThePRAddressNotTheFork() throws {
  // A PR from a fork: gh also reports headRepository (the fork); the PR itself lives in the base repository.
  let fork = """
    {"headRefName":"patch-1","headRepository":{"id":"R_1","name":"widgets"},"headRepositoryOwner":{"id":"U_1","login":"someone"},\
    "number":9,"state":"MERGED","statusCheckRollup":[],"url":"https://github.com/acme/widgets/pull/9"}
    """
  let info = try #require(ProofPR.parse(Data(fork.utf8)))
  #expect(info.repository == "acme/widgets")
  #expect(info.merged && info.state == "MERGED")
}

@Test func nothingUsableIsNoPR() {
  #expect(ProofPR.parse(Data()) == nil)
  #expect(ProofPR.parse(Data("not json".utf8)) == nil)
  #expect(ProofPR.parse(Data(#"{"state":"OPEN"}"#.utf8)) == nil)
  // One PR is asked for by number or branch, so a list is not an answer.
  #expect(ProofPR.parse(Data(#"[{"number":12,"state":"OPEN"}]"#.utf8)) == nil)
}

@Test func aBodyIsMergedIntoTheCurrentDescription() throws {
  let current = #"{"body":"Fixes the login.\n\nTested by hand."}"#
  let body = try ProofPR.updatedBody(from: Data(current.utf8), summary: "### Proof").get()
  #expect(body.hasPrefix("Fixes the login.\n\nTested by hand."))
  #expect(body.contains(ProofSummary.start) && body.contains("### Proof"))
  // An empty description arrives as "" (or null) and is simply replaced.
  #expect(try ProofPR.updatedBody(from: Data(#"{"body":""}"#.utf8), summary: "S").get()
    == ProofSummary.replacing(in: "", with: "S"))
  #expect(try ProofPR.updatedBody(from: Data(#"{"body":null}"#.utf8), summary: "S").get()
    == ProofSummary.replacing(in: "", with: "S"))
}

@Test func aDescriptionGhDidNotGiveIsNeverOverwritten() {
  for answer in [#"{}"#, #"{"title":"x"}"#, #"{"body":42}"#, "[]", "not json", ""] {
    guard case .failure = ProofPR.updatedBody(from: Data(answer.utf8), summary: "S") else {
      Issue.record("accepted \(answer)"); continue
    }
  }
}

@Test func anEnterpriseHostKeepsItsNameInTheRepository() {
  #expect(ProofPR.repository(ofPullRequestURL: "https://git.acme.io/team/app/pull/4") == "git.acme.io/team/app")
  #expect(ProofPR.repository(ofPullRequestURL: "https://github.com/o/r/pull/4") == "o/r")
  #expect(ProofPR.repository(ofPullRequestURL: "https://github.com/o/r/issues/4") == "")
  #expect(ProofPR.repository(ofPullRequestURL: "") == "")
}

@Test func mergingARefusesAPRThatIsNotOpen() {
  let merged = ProofPR.Info(number: 5, url: "", state: "MERGED", merged: true, checksFailing: false, head: "a",
                            repository: "o/r")
  guard case .failure(let failure) = ProofPR.merge(info: merged, folder: "/tmp") else { Issue.record("merged"); return }
  #expect(failure == .init("#5 is merged, not open."))
}

// Real `gh api repos/o/r/deployments` and `.../deployments/<id>/statuses` shapes.
@Test func deploymentsAreReadNewestFirst() {
  let list = #"[{"id":2002,"ref":"feat/x","environment":"Preview","sha":"abc"},{"id":2001,"ref":"feat/x","environment":"Preview"}]"#
  #expect(ProofPR.deploymentIDs(Data(list.utf8)) == [2002, 2001])
  #expect(ProofPR.deploymentIDs(Data("{}".utf8)).isEmpty)
}

@Test func theDeploymentURLIsTheNewestSuccessWithAnEnvironmentURL() {
  let statuses = """
    [{"id":3,"state":"in_progress","environment_url":"","target_url":"https://vercel.com/x/inspect"},\
    {"id":2,"state":"success","environment":"Preview","environment_url":"https://app-git-feat-x.vercel.app","target_url":"https://vercel.com/x/inspect"},\
    {"id":1,"state":"success","environment_url":"https://older.vercel.app"}]
    """
  #expect(ProofPR.deploymentURL(inStatuses: Data(statuses.utf8)) == "https://app-git-feat-x.vercel.app")
  #expect(ProofPR.deploymentURL(inStatuses: Data(#"[{"id":1,"state":"failure","environment_url":""}]"#.utf8)) == nil)
  #expect(ProofPR.deploymentURL(inStatuses: Data("oops".utf8)) == nil)
}

@Test func aFixedURLNeedsNoScript() {
  let env = ProofSetup.Environment(name: "Local", url: "http://localhost:3000")
  #expect(ProofPR.previewURL(env: env, info: nil, root: "/nonexistent", branch: nil, worktree: nil)
    == .success("http://localhost:3000"))
  let none = ProofSetup.Environment(name: "Local")
  #expect(ProofPR.previewURL(env: none, info: nil, root: "/nonexistent", branch: nil, worktree: nil)
    == .failure(.init("No url or urlScript.")))
}

@Test func theChecksStateIsKept() throws {
  let json = #"{"number":7,"url":"https://github.com/o/n/pull/7","state":"OPEN","headRefName":"x","baseRefName":"main","statusCheckRollup":[{"status":"IN_PROGRESS"}]}"#
  #expect(ProofPR.parse(Data(json.utf8))?.checks == .pending)
}
