/// Frees something expensive once it has gone unused for a while, e.g. the on-device voice model. Callers bracket each
/// use with `begin()` and `end()`; when the last use ends and nothing begins for `after`, `release` runs. A use that
/// begins while a release is pending cancels it.
@MainActor
public final class IdleRelease {
  private let after: Duration
  private let release: @MainActor () async -> Void
  private var uses = 0
  private var pending: Task<Void, Never>?

  public init(after: Duration, release: @escaping @MainActor () async -> Void) {
    self.after = after
    self.release = release
  }

  public func begin() {
    uses += 1
    pending?.cancel()
    pending = nil
  }

  public func end() {
    guard uses > 0 else { return }
    uses -= 1
    guard uses == 0 else { return }
    pending = Task { [after, weak self] in
      try? await Task.sleep(for: after)
      guard !Task.isCancelled, let self, self.uses == 0 else { return }
      self.pending = nil
      await self.release()
    }
  }
}
