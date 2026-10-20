import Foundation
import Testing
@testable import GlanceCore

private let acme = ChatWorkspace(teamID: "T0ACME", name: "Acme", iconURL: nil)
private let beta = ChatWorkspace(teamID: "T0BETA", name: "Beta", iconURL: "https://a.slack-edge.com/beta.png")

@Test func aWorkspaceOpensAtItsClientAddress() {
  #expect(acme.clientURL.absoluteString == "https://app.slack.com/client/T0ACME")
  #expect(acme.id == "T0ACME")
}

@Test func theInitialIsTheNamesFirstLetterUppercasedElseTheTeam() {
  #expect(ChatWorkspace(teamID: "T1", name: "acme", iconURL: nil).initial == "A")
  #expect(ChatWorkspace(teamID: "T1", name: "  ", iconURL: nil).initial == "T")
}

@Test func workspacesKeepTheOrderTheyWereAdded() {
  var store = ChatWorkspaceStore()
  let addedBeta = store.add(beta)
  let addedAcme = store.add(acme)
  #expect(addedBeta && addedAcme)
  #expect(store.workspaces.map(\.teamID) == ["T0BETA", "T0ACME"])
}

@Test func addingASavedTeamUpdatesItInPlace() {
  var store = ChatWorkspaceStore(workspaces: [acme, beta])
  let added = store.add(ChatWorkspace(teamID: "T0ACME", name: "Acme Corp", iconURL: "https://x/icon.png"))
  #expect(added == false)
  #expect(store.workspaces.map(\.teamID) == ["T0ACME", "T0BETA"])
  #expect(store.workspace(teamID: "T0ACME")?.name == "Acme Corp")
  #expect(store.workspace(teamID: "T0ACME")?.iconURL == "https://x/icon.png")
}

@Test func updateChangesOnlyWhatItIsGiven() {
  var store = ChatWorkspaceStore(workspaces: [beta])
  store.update(teamID: "T0BETA", name: "Beta Labs", iconURL: nil)
  #expect(store.workspace(teamID: "T0BETA")?.name == "Beta Labs")
  #expect(store.workspace(teamID: "T0BETA")?.iconURL == "https://a.slack-edge.com/beta.png")
  store.update(teamID: "T0NONE", name: "Ghost", iconURL: nil)
  #expect(store.workspaces.count == 1)
}

@Test func removeForgetsTheTeam() {
  var store = ChatWorkspaceStore(workspaces: [acme, beta])
  store.remove(teamID: "T0ACME")
  #expect(store.workspaces == [beta])
}

@Test func theListRoundTripsThroughItsData() {
  let store = ChatWorkspaceStore(workspaces: [acme, beta])
  #expect(ChatWorkspaceStore(data: store.encoded()) == store)
}

@Test func damagedDataIsAnEmptyList() {
  #expect(ChatWorkspaceStore(data: nil).workspaces.isEmpty)
  #expect(ChatWorkspaceStore(data: Data("not json".utf8)).workspaces.isEmpty)
  #expect(ChatWorkspaceStore(data: Data(#"[{"name":"No team"}]"#.utf8)).workspaces.isEmpty)
  #expect(ChatWorkspaceStore(data: Data(#"[{"teamID":"","name":"Empty"}]"#.utf8)).workspaces.isEmpty)
}
