import Foundation
import GlanceCore

/// One side Claude writing one explainer page: no tools at all, no hooks, no MCP, no settings, no mods, its own system
/// prompt, in an empty folder. It can't read a file or run anything, however hostile the reply it was given, and the
/// session's own Claude never hears about it (spec 2026-11-03-explainer-mode-design.md §6.1).
@MainActor
public final class ExplainerPageRun {
  public enum Event: Equatable {
    /// The answer sentence, as soon as it closes in the stream.
    case answer(String)
    /// The checked page and the model that wrote it.
    case page(ExplainerPage)
    case failed(String)
  }

  public typealias Runner = (_ arguments: [String], _ prompt: String, _ folder: String, _ timeout: TimeInterval,
                             _ onEvent: @escaping @MainActor (ClaudeRunner.Event) -> Void) -> ClaudeOneShot.Run

  public static let model = "claude-sonnet-5-5"
  public static let timeout: TimeInterval = 90

  public static let realRunner: Runner = { arguments, prompt, folder, timeout, onEvent in
    ClaudeRunner.run(arguments: arguments, prompt: prompt, folder: folder, timeout: timeout,
                     removing: [ClaudeMods.pluginDirsKey], onEvent: onEvent)
  }

  static var systemPrompt: URL { Resources.web.appendingPathComponent("explainer/system.md") }

  static func arguments(systemPrompt: String) -> [String] {
    ["-p", "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
     "--no-session-persistence", "--settings", #"{"disableAllHooks":true}"#, "--strict-mcp-config", "--setting-sources", "",
     "--disable-slash-commands", "--tools", "", "--system-prompt-file", systemPrompt]
  }

  private let runner: Runner
  private var run: ClaudeOneShot.Run?
  private var folder: URL?
  private var streamed = ""
  private var answered = false
  private var ended = false

  public init(runner: Runner? = nil) {
    self.runner = runner ?? Self.realRunner
  }

  public func start(prompt: String, onEvent: @escaping @MainActor (Event) -> Void) {
    guard FileManager.default.fileExists(atPath: Self.systemPrompt.path) else {
      onEvent(.failed("The explainer's instructions are missing from this build."))
      return
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("glance-explainer-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      onEvent(.failed("Couldn't make a folder for the run."))
      return
    }
    self.folder = folder
    run = runner(Self.arguments(systemPrompt: Self.systemPrompt.path), prompt, folder.path, Self.timeout) { [weak self] event in
      self?.received(event, onEvent: onEvent)
    }
  }

  public func cancel() {
    ended = true
    run?.cancel()
    clean()
  }

  private func received(_ event: ClaudeRunner.Event, onEvent: @MainActor (Event) -> Void) {
    guard !ended else { return }
    switch event {
    case .text(let piece):
      streamed += piece
      if !answered, let answer = ExplainerPage.answerSentence(inPartial: streamed), !answer.isEmpty {
        answered = true
        onEvent(.answer(answer))
      }
    case .tool:
      break
    case .done(let text):
      finish()
      switch ExplainerPage.check(text) {
      case .success(let page): onEvent(.page(page))
      case .failure(let problem): onEvent(.failed("Claude's page didn't pass Glance's checks (\(problem))."))
      }
    case .failed(let message):
      finish()
      onEvent(.failed(message))
    }
  }

  private func finish() {
    ended = true
    clean()
  }

  private func clean() {
    if let folder { try? FileManager.default.removeItem(at: folder) }
    folder = nil
  }
}
