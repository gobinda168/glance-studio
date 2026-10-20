import Foundation

/// The Glance server's `/v1` answers (spec 2026-10-18-glance-server-core-design.md, "API"): snake_case keys, times in
/// Unix seconds.
public enum CloudAPI {
  public static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }()
}

/// What paid features are called on screen. The server's names never show; neither do providers.
public enum CloudFeature {
  public static func title(_ id: String) -> String {
    switch id {
    case "cloud_voice": "Cloud Glance Voice"
    case "journal_sync": "Journal sync"
    default: id
    }
  }
}

public enum CloudRole: String, Codable, Sendable, CaseIterable {
  case owner, admin, member

  public var title: String {
    switch self {
    case .owner: "Owner"
    case .admin: "Admin"
    case .member: "Member"
    }
  }
}

public struct CloudIdentity: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let provider: CloudProvider
  public let email: String?

  public init(id: String, provider: CloudProvider, email: String?) {
    self.id = id
    self.provider = provider
    self.email = email
  }
}

public struct CloudWorkspace: Codable, Equatable, Sendable, Identifiable {
  public enum Kind: String, Codable, Sendable { case personal, team }

  public let id: String
  public let name: String
  public let kind: Kind
  public let role: CloudRole
}

public struct CloudMe: Codable, Equatable, Sendable {
  public let user: CloudUser
  public let identities: [CloudIdentity]
  public let workspaces: [CloudWorkspace]
}

/// One signed-in Mac.
public struct CloudMac: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let deviceName: String
  public let createdAt: Date
  public let lastUsedAt: Date
  public let current: Bool

  enum CodingKeys: String, CodingKey {
    case id, current
    case deviceName = "device_name", createdAt = "created_at", lastUsedAt = "last_used_at"
  }
}

public struct CloudMember: Codable, Equatable, Sendable, Identifiable {
  public let userID: String
  public let name: String
  public let email: String?
  public let avatarURL: URL?
  public let role: CloudRole

  public var id: String { userID }

  enum CodingKeys: String, CodingKey {
    case name, email, role
    case userID = "user_id", avatarURL = "avatar_url"
  }
}

public struct CloudInvite: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let role: CloudRole
  public let createdByName: String
  public let createdAt: Date
  public let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case id, role
    case createdByName = "created_by_name", createdAt = "created_at", expiresAt = "expires_at"
  }
}

public struct CloudInviteLink: Codable, Equatable, Sendable {
  public let id: String
  public let url: URL
  public let role: CloudRole
  public let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case id, url, role
    case expiresAt = "expires_at"
  }
}

public struct CloudInvitePreview: Codable, Equatable, Sendable {
  public let workspaceName: String
  public let inviterName: String
  public let role: CloudRole
  public let expiresAt: Date

  enum CodingKeys: String, CodingKey {
    case role
    case workspaceName = "workspace_name", inviterName = "inviter_name", expiresAt = "expires_at"
  }
}

public struct CloudEntitlement: Codable, Equatable, Sendable {
  public let feature: String
  public let source: String
  public let expiresAt: Date?

  enum CodingKeys: String, CodingKey {
    case feature, source
    case expiresAt = "expires_at"
  }
}

private struct LinkTicket: Decodable { let ticket: String }

extension CloudClient {
  public func me() async throws -> CloudMe { try await call("GET", "/v1/me") }
  public func rename(to name: String) async throws { try await callEmpty("PATCH", "/v1/me", ["name": name]) }
  public func deleteAccount() async throws { try await callEmpty("DELETE", "/v1/me") }
  public func macs() async throws -> [CloudMac] { try await call("GET", "/v1/me/sessions") }
  public func signOutMac(_ id: String) async throws { try await callEmpty("DELETE", "/v1/me/sessions/\(id)") }
  public func removeIdentity(_ id: String) async throws { try await callEmpty("DELETE", "/v1/me/identities/\(id)") }
  public func linkTicket() async throws -> String { (try await call("POST", "/v1/auth/link") as LinkTicket).ticket }

  public func createTeam(named name: String) async throws -> CloudWorkspace {
    try await call("POST", "/v1/workspaces", ["name": name])
  }

  public func renameWorkspace(_ id: String, to name: String) async throws {
    try await callEmpty("PATCH", "/v1/workspaces/\(id)", ["name": name])
  }

  public func deleteWorkspace(_ id: String) async throws { try await callEmpty("DELETE", "/v1/workspaces/\(id)") }

  public func transfer(_ id: String, to userID: String) async throws {
    try await callEmpty("POST", "/v1/workspaces/\(id)/transfer", ["user_id": userID])
  }

  public func members(of id: String) async throws -> [CloudMember] { try await call("GET", "/v1/workspaces/\(id)/members") }

  public func setRole(_ role: CloudRole, for userID: String, in id: String) async throws {
    try await callEmpty("PATCH", "/v1/workspaces/\(id)/members/\(userID)", ["role": role.rawValue])
  }

  public func removeMember(_ userID: String, from id: String) async throws {
    try await callEmpty("DELETE", "/v1/workspaces/\(id)/members/\(userID)")
  }

  public func leave(_ id: String) async throws { try await callEmpty("DELETE", "/v1/workspaces/\(id)/members/me") }

  public func createInvite(to id: String, role: CloudRole) async throws -> CloudInviteLink {
    try await call("POST", "/v1/workspaces/\(id)/invites", ["role": role.rawValue])
  }

  public func invites(of id: String) async throws -> [CloudInvite] { try await call("GET", "/v1/workspaces/\(id)/invites") }

  public func revokeInvite(_ invite: String, in id: String) async throws {
    try await callEmpty("DELETE", "/v1/workspaces/\(id)/invites/\(invite)")
  }

  public func invitePreview(_ token: String) async throws -> CloudInvitePreview {
    try await callUnsigned("GET", "/v1/invites/\(token)")
  }

  public func acceptInvite(_ token: String) async throws -> CloudWorkspace {
    try await call("POST", "/v1/invites/\(token)/accept")
  }

  public func workspaceEntitlements(_ id: String) async throws -> [CloudEntitlement] {
    try await call("GET", "/v1/workspaces/\(id)/entitlements")
  }
}
