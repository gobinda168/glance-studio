import Foundation
import GlanceCore

/// Settings → Secrets' data. Rows carry no values. The vault opens with Touch ID (`unlock`); saving a change to a
/// value or rule, deleting one, revealing a value or resetting asks again (`OwnerCheck`); adding one doesn't.
/// Only this model and the broker ever read a value; the views get one only from `reveal`.
@MainActor
public final class SecretsModel: ObservableObject {
  public struct Row: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let note: String
    public let hosts: [String]
    /// How it is sent: "bearer", "header X-API-Key", "basic".
    public let sentAs: String
    /// The header it fills (name, prefix or Basic username; never the value), for the row's "sent as" line.
    public let slot: SecretSlot
    public let approval: SecretApproval
    public let folders: [String]
    public let lastUsed: Date?
    /// Requests that were sent (the log keeps the last 1,000 entries, so older ones aren't counted).
    public let uses: Int
  }

  /// The newest activity, newest first (at most `recentLimit`).
  @Published public private(set) var recent: [SecretActivity] = []
  @Published public private(set) var rows: [Row] = []
  @Published public private(set) var locked = true
  /// Why the last unlock or reset failed, shown with "Reset secrets".
  @Published public private(set) var problem: String?

  public static let recentLimit = 200
  static let ownerReason = "change your Glance secrets"

  private let service: SecretsService
  private let log: SecretActivityLog
  private var observer: NSObjectProtocol?

  public init(service: SecretsService? = nil, log: SecretActivityLog = .standard) {
    self.service = service ?? .shared
    self.log = log
    observer = NotificationCenter.default.addObserver(forName: SecretsService.didLock, object: nil, queue: .main) {
      [weak self] _ in MainActor.assumeIsolated { self?.reload() }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  private var vault: SecretVault { service.vault }

  /// Re-reads the vault (rows are empty while it's locked) and the activity log.
  public func reload() {
    let activity = log.recent(limit: SecretActivityLog.keep)
    recent = Array(activity.prefix(Self.recentLimit))
    locked = !vault.isUnlocked
    // A failure from an earlier unlock is over once the vault is open (Claude's call may have opened it); without this
    // it would come back, with "Reset secrets…", after the next lock.
    if !locked { problem = nil }
    rows = vault.records().sorted { $0.name < $1.name }.map { record in
      // A request that was sent has a status code as its outcome; "denied", "refused: …" and "failed: …" don't.
      let sent = activity.filter { $0.secret == record.name && Int($0.outcome) != nil }
      return Row(id: record.id, name: record.name, note: record.note, hosts: record.hosts,
                 sentAs: record.slot.summary, slot: record.slot, approval: record.approval, folders: record.folders,
                 lastUsed: sent.first?.date, uses: sent.count)
    }
  }

  /// Touch ID, then the rows. Settings' unlock always shows the sheet when the vault is locked (it clears the
  /// back-off a Claude-caused cancel started); `problem` says why when it didn't open.
  public func unlock() async {
    problem = await service.unlock()
    reload()
  }

  /// Deletes every secret and the key, for a vault that can't be opened any more. Needs the owner (Touch ID or the
  /// login password).
  public func reset() async {
    guard await OwnerCheck.confirm(Self.ownerReason) else { return }
    do { try vault.reset() } catch {
      // The key stays: the vault is still there, and without its key it could never be opened again.
      problem = Self.message(for: error)
      reload()
      return
    }
    do {
      if FileManager.default.fileExists(atPath: SecureEnclaveKey.standardFile.path) {
        try FileManager.default.removeItem(at: SecureEnclaveKey.standardFile)
      }
    } catch {
      service.lockNow()
      problem = "Your secrets were deleted, but the old key file (secrets.key) couldn't be removed."
      reload()
      return
    }
    service.lockNow()
    problem = nil
    reload()
  }

  /// Problems to show, or [] when saved. Opens the vault first (Touch ID) if it's locked.
  public func add(_ draft: SecretDraft) async -> [String] {
    if let problem = await service.unlock() { return [problem] }
    let now = Date()
    switch draft.record(id: UUID(), created: now, now: now, otherNames: Set(vault.records().map(\.name)),
                        keeping: nil) {
    case .failure(let problems): return problems.sentences
    case .success(let record):
      do { try vault.save(record) } catch { return [Self.message(for: error)] }
      reload()
      return []
    }
  }

  /// The sheet's fields for an existing secret (the value left empty). No Touch ID: the draft holds no value, and
  /// `update` asks when a save changes the value or a rule. nil when the secret is gone or the vault locked.
  public func draft(for id: UUID) async -> SecretDraft? {
    guard let record = try? vault.load(id) else { return nil }
    return SecretDraft(record: record)
  }

  static let staleAnswer = "This secret changed since you opened it. Open it again."

  /// Problems to show, or [] when saved. An empty value field keeps the saved value. A save that changes the value, the
  /// hosts, how it is sent, the folders or the approval needs Touch ID, which names the change; a name or note change
  /// doesn't. The secret's session grants go.
  public func update(_ draft: SecretDraft, id: UUID) async -> [String] {
    guard let old = try? vault.load(id) else {
      return ["That secret is gone, or your secrets locked. Unlock and try again."]
    }
    guard draft.baseUpdated == old.updated else { return [Self.staleAnswer] }
    let others = Set(vault.records().map(\.name)).subtracting([old.name])
    let record: SecretRecord
    switch draft.record(id: id, created: old.created, now: Date(), otherNames: others, keeping: old.value) {
    case .failure(let problems): return problems.sentences
    case .success(let made): record = made
    }
    if let reason = SecretDraft.changeReason(from: old, to: record) {
      // A finger right before the save: a script can fill the sheet and press Save, but not this.
      guard await OwnerCheck.confirm(reason) else {
        return ["Nothing was saved: Touch ID was cancelled."]
      }
      // The vault may have locked or the secret changed while the sheet was up.
      guard let now = try? vault.load(id) else {
        return ["That secret is gone, or your secrets locked. Unlock and try again."]
      }
      guard now.updated == old.updated else { return [Self.staleAnswer] }
    }
    do { try vault.save(record) } catch { return [Self.message(for: error)] }
    service.secretChanged(id)
    reload()
    return []
  }

  /// After Touch ID. Returns why it failed, nil when it's gone or the owner said no.
  @discardableResult
  public func delete(_ id: UUID) async -> String? {
    guard await OwnerCheck.confirm(Self.ownerReason) else { return nil }
    do { try vault.delete(id) } catch {
      reload()
      return Self.message(for: error)
    }
    service.secretChanged(id)
    reload()
    return nil
  }

  /// The saved value, after Touch ID; nil when that was cancelled or the secret is gone. The caller shows it and
  /// drops it.
  public func reveal(_ id: UUID) async -> String? {
    guard let name = try? vault.load(id).name,
          await OwnerCheck.confirm("show the value of \(name)") else { return nil }
    return try? vault.load(id).value
  }

  /// Sentences for `SecretVault` errors; nothing in them comes from a record.
  private static func message(for error: Error) -> String {
    switch error as? SecretVault.Failure {
    case .locked?: return "Your secrets locked. Unlock them and try again."
    case .notFound?: return "That secret is gone."
    case .io(let why)?: return "Couldn't save your secrets: \(why)"
    case .damaged?, .keyUnavailable?, nil: return "Couldn't change your secrets."
    }
  }
}
