import Foundation
import GlanceCore

/// Make explainer's Claude step (spec 2026-11-01-command-center-design.md §4.3): one `claude -p` that writes
/// `scenes.html` and `narration.json`. What Claude said is kept, so that a failure shows why.
@MainActor
public enum ExplainerClaude {
  /// How `claude -p` is started: its arguments, prompt, folder and time limit, and where its events go. Tests inject one.
  public typealias Runner = (_ arguments: [String], _ prompt: String, _ folder: String, _ timeout: TimeInterval,
                             _ onEvent: @escaping @MainActor (ClaudeRunner.Event) -> Void) -> ClaudeOneShot.Run

  public static let realRunner: Runner = { arguments, prompt, folder, timeout, onEvent in
    ClaudeRunner.run(arguments: arguments, prompt: prompt, folder: folder, timeout: timeout, onEvent: onEvent)
  }

  /// Most of what Claude said that is kept for the log.
  public static let sayingKept = 4_000

  /// The run under way, for Cancel.
  public final class Session {
    var run: ClaudeOneShot.Run?
    var abandon: (() -> Void)?
    public private(set) var cancelled = false
    public init() {}

    /// Ends the step: the process stops and `ask` throws `CancellationError`.
    public func cancel() {
      cancelled = true
      run?.cancel()
      abandon?()
    }
  }

  /// Runs Claude and returns when it has answered. A tool it uses goes to `log` as it happens; when it ends, the tail of
  /// what it said ("Claude said:") follows, whether it finished or failed. Throws `ExplainerFailure` at the writing step,
  /// or `CancellationError`.
  public static func ask(arguments: [String], prompt: String, folder: String, timeout: TimeInterval = 10 * 60,
                         session: Session, runner injected: Runner? = nil, log: @escaping (String) -> Void) async throws {
    let runner = injected ?? realRunner
    final class Box { var resume: ((Result<Void, Error>) -> Void)?; var said = "" }
    let box = Box()
    func remember(_ text: String) {
      box.said += text
      if box.said.count > sayingKept * 2 { box.said = String(box.said.suffix(sayingKept)) }
    }
    func finish(_ result: Result<Void, Error>, final: String? = nil) {
      guard let resume = box.resume else { return }
      box.resume = nil
      let said = (final.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? box.said)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !said.isEmpty { log("Claude said:\n" + String(said.suffix(sayingKept))) }
      resume(result)
    }
    if session.cancelled { throw CancellationError() }
    defer { session.run = nil; session.abandon = nil }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      box.resume = { continuation.resume(with: $0) }
      session.abandon = { finish(.failure(CancellationError())) }
      session.run = runner(arguments, prompt, folder, timeout) { event in
        switch event {
        case .text(let piece): remember(piece)
        case .tool(let label): log(label)
        case .done(let answer): finish(.success(()), final: answer)
        case .failed(let message): finish(.failure(ExplainerFailure(step: .writing, message: message)))
        }
      }
      if session.cancelled { session.abandon?() }
    }
  }
}
