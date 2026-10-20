import AppKit
import Foundation
import GlanceCore

/// Studio's secrets broker (spec 2026-10-10-secrets-broker-design.md): the vault, the broker, and the session grants.
/// The orb channel's hub routes `secrets_list` and `http_request` here. The vault unlocks at the first need (Touch
/// ID, for opening it and for creating it) and locks when the Mac sleeps, its screen sleeps or locks, or the user
/// switches away.
@MainActor
public final class SecretsService {
  public static let shared = SecretsService()
  /// Posted when the vault locks, so Settings can show it.
  public static let didLock = Notification.Name("dev.glance.secrets.didLock")

  /// With no vault file yet, `load` may make a new key; once the vault exists its key must be the saved one.
  public let vault = SecretVault(keys: {
    try SecureEnclaveKey.load(create: !FileManager.default.fileExists(atPath: SecretVault.standardFile.path))
  })
  private var grants = SecretGrants()
  /// Bumped by every lock, and per session id by its end (ids are socket descriptors, reused once closed): an answer
  /// that arrives after either is a Deny, and grants nothing.
  private var lockEpoch = 0
  private var sessionEpochs: [Int32: Int] = [:]
  /// Bumped per secret by `secretChanged`: an edit or delete while its card waits makes the answer a Deny.
  private var secretEpochs: [UUID: Int] = [:]
  /// After an unlock Claude caused was cancelled, or Touch ID didn't recognise the finger, Claude's calls don't put
  /// the sheet up again until then.
  private var quietUntil: Date?
  static let quietFor: TimeInterval = 60
  static let quietAnswer = "Your Glance secrets are locked. Unlock them in Settings → Secrets."
  private lazy var broker = SecretBroker(records: vault, transport: URLSessionSecretTransport(),
                                         approver: Approver(service: self), log: SecretActivityLog.standard)
  private var observers: [NSObjectProtocol] = []

  private init() {
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { SecretsService.shared.lockNow() }
      })
    }
    observers.append(DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { SecretsService.shared.lockNow() }
      })
  }

  /// Opens the vault (Touch ID unless it's open already). nil when open, else why not, in words for the user and
  /// Claude. Settings' Unlock: always asks.
  public func unlock() async -> String? {
    let problem = await open().problem
    if problem == nil { quietUntil = nil }
    return problem
  }

  /// For Claude's calls: like `unlock`, but after one Claude caused was cancelled or failed, no sheet for
  /// `quietFor` (so a Claude can't keep putting it up until a finger lands on it).
  private func unlockForClaude() async -> String? {
    if vault.isUnlocked { return nil }
    if let quietUntil, Date() < quietUntil { return Self.quietAnswer }
    let (problem, declined) = await open()
    // Quiet only after the owner said no (cancel, or a finger Touch ID didn't take), as this unlock's own result
    // says. A debuggable build, a damaged vault or Touch ID being unavailable keep answering with their own reason.
    quietUntil = problem != nil && declined ? Date().addingTimeInterval(Self.quietFor) : nil
    return problem
  }

  /// The unlock's outcome: why it stayed locked (nil when open), and whether that was the owner declining the sheet.
  private func open() async -> (problem: String?, declined: Bool) {
    guard !DebuggerCheck.attachable else {
      return ("This Studio build lets debuggers attach, so your secrets stay locked. Rebuild it with scripts/build-terminal.sh.",
              false)
    }
    do {
      try await vault.unlock()
      return (nil, false)
    } catch SecretVault.Failure.keyUnavailable(let why, let declined) {
      return ("Your Glance secrets stayed locked: \(why)", declined)
    } catch SecretVault.Failure.damaged {
      return ("Your Glance secrets file can't be opened (it was changed, or its key no longer works). Reset secrets in Settings to start again.",
              false)
    } catch SecretVault.Failure.locked {
      return ("Your Glance secrets locked again before they opened. Try again.", false)
    } catch SecretVault.Failure.io(let why) {
      return ("Your Glance secrets stayed locked: \(why)", false)
    } catch {
      return ("Your Glance secrets stayed locked.", false)
    }
  }

  /// Forgets the unlocked vault and every session grant; any card still waiting is Deny (nobody is there).
  public func lockNow() {
    vault.lock()
    lockEpoch += 1
    grants = SecretGrants()
    SecretApprovalCards.shared.denyAll()
    NotificationCenter.default.post(name: Self.didLock, object: nil)
  }

  public func list(caller: SecretCaller) async -> (JSONValue, Bool) {
    if let problem = await unlockForClaude() { return (.string(problem), true) }
    return (broker.list(caller: caller), false)
  }

  public func request(_ call: SecretHTTPCall, caller: SecretCaller) async -> (JSONValue, Bool) {
    if let problem = await unlockForClaude() { return (.string(problem), true) }
    let result = await broker.request(call, caller: caller)
    return (result.value, result.isError)
  }

  /// A session ended: its grants go, and its waiting cards are Deny.
  public func sessionEnded(_ session: Int32) {
    sessionEpochs[session, default: 0] += 1
    grants.end(session: session)
    SecretApprovalCards.shared.sessionEnded(session)
  }

  /// Settings edited or deleted a secret: its session grants go, and a card waiting for it can only be a Deny.
  public func secretChanged(_ id: UUID) {
    secretEpochs[id, default: 0] += 1
    grants.forget(secret: id)
  }

  fileprivate func decide(_ ask: SecretApprovalAsk) async -> SecretApprovalDecision {
    let session = ask.caller.session, secret = ask.secretID
    guard grants.needsAsking(ask.approval, session: session, secret: secret) else { return .allow }
    let cards = SecretApprovalCards.shared
    guard cards.waiting(session: session) < SecretApprovalCards.perSession,
          cards.queue.count < SecretApprovalCards.allSessions else { return .tooManyWaiting }
    let before = (lock: lockEpoch, session: sessionEpochs[session, default: 0],
                  secret: secretEpochs[secret, default: 0])
    let answer = await cards.ask(ask)
    // The answer resumes a moment later: a lock, the session's end, or the secret edited or deleted in between makes
    // it a Deny (the request would go out with what the user no longer has).
    guard lockEpoch == before.lock, sessionEpochs[session, default: 0] == before.session,
          secretEpochs[secret, default: 0] == before.secret, let updated = ask.updated,
          (try? vault.load(secret))?.updated == updated else { return .deny }
    switch answer {
    case .deny: return .deny
    case .once: return .allow
    case .session:
      grants.grant(session: session, secret: secret)
      return .allow
    }
  }

  private final class Approver: SecretApprover, @unchecked Sendable {
    weak var service: SecretsService?
    init(service: SecretsService) { self.service = service }
    func approve(_ ask: SecretApprovalAsk) async -> Bool { await decide(ask) == .allow }
    func decide(_ ask: SecretApprovalAsk) async -> SecretApprovalDecision {
      guard let service = await MainActor.run(body: { self.service }) else { return .deny }
      return await service.decide(ask)
    }
  }
}
