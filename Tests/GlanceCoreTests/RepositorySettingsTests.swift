import Foundation
import Testing
@testable import GlanceCore

@Test func readsTheRepositorysMergeSettings() throws {
  // gobinda168/glance, as GitHub answered on 2026-10-07.
  let output = """
    {"data":{"viewer":{"login":"gobinda168"},"repository":{"autoMergeAllowed":false,"viewerDefaultMergeMethod":"MERGE",\
    "mergeCommitAllowed":true,"squashMergeAllowed":true,"rebaseMergeAllowed":true,"defaultBranchRef":{"name":"main"}}}}
    """
  let settings = try #require(RepositorySettings.parse(Data(output.utf8)))
  #expect(settings == .init(viewer: "gobinda168", defaultBranch: "main", methods: [.merge, .squash, .rebase],
                            preferred: .merge, autoMergeAllowed: false))
}

@Test func theViewersMethodIsOfferedOnlyWhenAllowed() throws {
  let output = """
    {"data":{"viewer":{"login":"g"},"repository":{"autoMergeAllowed":true,"viewerDefaultMergeMethod":"MERGE",\
    "mergeCommitAllowed":false,"squashMergeAllowed":true,"rebaseMergeAllowed":false,"defaultBranchRef":{"name":"trunk"}}}}
    """
  let settings = try #require(RepositorySettings.parse(Data(output.utf8)))
  #expect(settings.methods == [.squash])
  #expect(settings.preferred == .squash)
  #expect(settings.autoMergeAllowed)
  #expect(settings.defaultBranch == "trunk")
  #expect(RepositorySettings.parse(Data(#"{"errors":[{"message":"no"}]}"#.utf8)) == nil)
}

@Test func asksGitHubForTheRepositorysSettings() throws {
  let arguments = try #require(RepositorySettings.arguments(repository: "gobinda168/glance"))
  #expect(arguments.prefix(3) == ["api", "graphql", "-f"])
  #expect(arguments.contains("owner=gobinda168"))
  #expect(arguments.contains("name=glance"))
  #expect(RepositorySettings.arguments(repository: "nope") == nil)
}
