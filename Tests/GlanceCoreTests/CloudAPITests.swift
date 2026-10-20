import Foundation
import Testing
@testable import GlanceCore

@Suite struct CloudAPITests {
  @Test func meDecodesFromTheServersJSON() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/me", 200, #"""
      {"user":{"id":"u1","name":"Ada","email":"ada@example.com","avatar_url":null},
       "identities":[{"id":"i1","provider":"github","email":"ada@example.com"}],
       "workspaces":[{"id":"w1","name":"Personal","kind":"personal","role":"owner"},
                     {"id":"w2","name":"Glance","kind":"team","role":"admin"}]}
      """#)
    let me = try await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000))).me()
    #expect(me.user.displayName == "Ada")
    #expect(me.identities == [CloudIdentity(id: "i1", provider: .github, email: "ada@example.com")])
    #expect(me.workspaces.map(\.kind) == [.personal, .team] && me.workspaces[1].role == .admin)
  }

  @Test func listsDecodeUnixSecondsAndSnakeCase() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/me/sessions", 200, #"[{"id":"s1","device_name":"Ada's Mac","created_at":1000,"last_used_at":2000,"current":true}]"#)
    await server.answer("GET /v1/workspaces/w2/members", 200, #"[{"user_id":"u2","name":"Bo","email":null,"avatar_url":"https://example.com/b.png","role":"member"}]"#)
    await server.answer("GET /v1/workspaces/w2/invites", 200, #"[{"id":"i9","role":"admin","created_by_name":"Ada","created_at":1000,"expires_at":9000}]"#)
    let cloud = cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000)))
    let mac = try #require(try await cloud.macs().first)
    #expect(mac.deviceName == "Ada's Mac" && mac.current && mac.lastUsedAt == Date(timeIntervalSince1970: 2000))
    let member = try #require(try await cloud.members(of: "w2").first)
    #expect(member.id == "u2" && member.role == .member && member.avatarURL != nil)
    let invite = try #require(try await cloud.invites(of: "w2").first)
    #expect(invite.createdByName == "Ada" && invite.expiresAt == Date(timeIntervalSince1970: 9000))
  }

  @Test func changesSendTheRightMethodPathAndBody() async throws {
    let server = FakeServer()
    await server.answer("PATCH /v1/workspaces/w2/members/u2", 204, "")
    await server.answer("POST /v1/workspaces/w2/invites", 201, #"{"id":"i1","url":"http://localhost:8080/i/tok","role":"member","expires_at":9000}"#)
    await server.answer("POST /v1/workspaces/w2/transfer", 204, "")
    let cloud = cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000)))
    try await cloud.setRole(.admin, for: "u2", in: "w2")
    let link = try await cloud.createInvite(to: "w2", role: .member)
    try await cloud.transfer("w2", to: "u2")
    #expect(link.url.absoluteString == "http://localhost:8080/i/tok")
    let bodies = await server.requests.map { $0.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } }
    #expect(bodies == [["role": "admin"], ["role": "member"], ["user_id": "u2"]])
  }

  @Test func theServersRefusalBecomesRejected() async throws {
    let server = FakeServer()
    await server.answer("DELETE /v1/me", 409, #"{"error":{"code":"owns_teams","message":"Hand over or delete your teams first: Glance."}}"#)
    await #expect(throws: CloudError.rejected(code: "owns_teams", message: "Hand over or delete your teams first: Glance.")) {
      try await cloudClient(server, MemoryStore(cloudSession(expiresAt: 5_000))).deleteAccount()
    }
  }

  @Test func theInvitePreviewNeedsNoSession() async throws {
    let server = FakeServer()
    await server.answer("GET /v1/invites/tok", 200, #"{"workspace_name":"Glance","inviter_name":"Ada","role":"member","expires_at":9000}"#)
    let preview = try await cloudClient(server, MemoryStore(nil)).invitePreview("tok")
    #expect(preview.workspaceName == "Glance" && preview.role == .member)
    #expect(await server.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func featureTitlesHideTheServerNames() {
    #expect(CloudFeature.title("cloud_voice") == "Cloud Glance Voice")
    #expect(CloudFeature.title("journal_sync") == "Journal sync")
    #expect(CloudFeature.title("something_new") == "something_new")
  }
}
