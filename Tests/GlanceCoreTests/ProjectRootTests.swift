import Testing
@testable import GlanceCore

@Test func theRootIsTheNearestFolderWithAGitDirectory() {
  let repos: Set<String> = ["/Users/me/Code/app"]
  let find = { (dir: String) in ProjectRoot.find(from: dir, home: "/Users/me", hasGit: { repos.contains($0) }) }
  #expect(find("/Users/me/Code/app/Sources/x") == "/Users/me/Code/app")
  #expect(find("/Users/me/Code/app") == "/Users/me/Code/app")
}

@Test func withoutARepoTheFolderItselfIsTheRoot() {
  #expect(ProjectRoot.find(from: "/Users/me/scratch/x", home: "/Users/me", hasGit: { _ in false }) == "/Users/me/scratch/x")
}

@Test func theSearchStopsAtHomeAndNeverClimbsPastIt() {
  let repos: Set<String> = ["/Users"]
  #expect(ProjectRoot.find(from: "/Users/me/Code", home: "/Users/me", hasGit: { repos.contains($0) }) == "/Users/me/Code")
}

@Test func tildeAndTrailingSlashesAreNormalised() {
  let repos: Set<String> = ["/Users/me/Code/app"]
  #expect(ProjectRoot.find(from: "~/Code/app/src/", home: "/Users/me", hasGit: { repos.contains($0) }) == "/Users/me/Code/app")
}
