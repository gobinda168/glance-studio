import Foundation
import GlanceCore
import GlanceKit

/// Command Center's Make explainer (spec 2026-11-01-command-center-design.md §4.3): one click runs the project's own
/// `explainer.command`, or the user's own Claude to write the scenes and then this Mac to render them
/// (`ExplainerRenderer`). It runs only from that click; nothing starts it by itself.
///
/// Step and progress are published in memory (`live`) as they happen; a copy goes to the session's record at most once a
/// second, and when the run ends, so that a restart can say what happened (`ExplainerState.shown`). A finished video is
/// a capture (Outcome in Assets); the record keeps nothing of it.
@MainActor
final class ExplainerRun: ObservableObject {
    static let shared = ExplainerRun()

    /// The newest run of each session: running, or failed. `done` stands for "nothing to show" (finished, or stopped by
    /// the user), so that a card doesn't flash "Interrupted" from a record that hasn't been read again yet.
    @Published private(set) var live: [String: ExplainerState] = [:]

    /// One run's own state; the run is `Job.id`.
    private final class Job {
        let id = UUID().uuidString
        let session: String
        let startedAt = Date()
        var state: ExplainerState
        var cancelled = false
        var log = ""
        var lastWrite = Date.distantPast
        let stop = ProofScript.Stop()
        let claude = ExplainerClaude.Session()
        var renderer: ExplainerRenderer?

        init(session: String) {
            self.session = session
            state = ExplainerState(id: id, phase: .running, step: .writing, progress: nil, log: nil, startedAt: startedAt)
        }

        func append(_ line: String) {
            log += (log.isEmpty ? "" : "\n") + line
            if log.count > 8_000 { log = String(log.suffix(6_000)) }
        }
    }

    /// What a run is made from.
    private struct Request {
        var session: String
        var record: WorkRecord
        var setup: ProofSetup?
        var cwd: String
        var prBase: String?
    }

    private var jobs: [String: Job] = [:]
    private let store: WorkStore
    /// Record writes happen in the order they were asked for.
    private let writes = DispatchQueue(label: "dev.glance.explainer.record", qos: .utility)

    init(store: WorkStore = WorkStore()) { self.store = store }

    /// The one file of the skill's folder Claude may read: the design tokens beside SKILL.md (which `Skill` loads itself).
    private static var tokensFile: String {
        ModFolders.builtInCopies.appendingPathComponent("glance-proof/skills/glance-explainer/tokens.css").path
    }

    // MARK: Asking

    func isActive(session: String) -> Bool { jobs[session] != nil }

    /// Starts a run for `session`; ignored while one is running, with Command Center off, or for an unsafe id.
    /// `prBase`: the base branch of the session's PR, when it has one.
    func start(session: String, record: WorkRecord, setup: ProofSetup?, cwd: String, prBase: String?) {
        guard StudioFeatures.shared.isOn(.commandCenter), WorkStore.isSessionID(session), jobs[session] == nil else { return }
        let job = Job(session: session)
        jobs[session] = job
        live[session] = job.state
        persist(job.state, session: session)
        let request = Request(session: session, record: record, setup: setup, cwd: cwd, prBase: prBase)
        Task { await run(job, request) }
    }

    /// Stops the run: the command's whole process group, Claude, or the render. Nothing is left to show, from now on:
    /// the card goes at once, however long what's underneath takes to stop. It winds down in its own folder.
    func cancel(session: String) {
        guard let job = jobs[session], !job.cancelled else { return }
        job.cancelled = true
        job.stop.cancel()
        job.claude.cancel()
        job.renderer?.cancel()
        end(job, as: nil)
    }

    // MARK: Running

    private func run(_ job: Job, _ request: Request) async {
        let folder = store.folder.appendingPathComponent(".tmp-explainer/\(job.id)", isDirectory: true)
        let store = store
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            await Task.detached { Self.sweep(in: store.folder.appendingPathComponent(".tmp-explainer", isDirectory: true)) }.value
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let command = request.setup?.explainer?.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let made = command.isEmpty
                ? try await writeAndRender(job, request, folder: folder)
                : try await runCommand(command, job, request, folder: folder)
            if job.cancelled { throw CancellationError() }
            let (video, caption) = made
            let session = request.session, record = request.record, id = job.id
            let added = await Task.detached {
                store.addCapture(session: session, id: id, from: video, kind: .explainer, url: nil, environment: nil,
                                 caption: caption, purpose: .outcome, source: .glance, cwd: record.cwd,
                                 worktree: record.worktree, branch: record.branch, commonDir: record.commonDir, budget: 5)
            }.value
            guard added != nil else {
                throw ExplainerFailure(step: .muxing, message: "The video couldn't be added to this session's record: it is over \(WorkStore.maxCaptureBytes / 1_048_576) MB, or the record was busy. Try again.")
            }
            end(job, as: nil)
        } catch is CancellationError {
            end(job, as: nil)
        } catch let failure as ExplainerFailure {
            end(job, as: failure)
        } catch {
            end(job, as: ExplainerFailure(step: job.state.step, message: error.localizedDescription))
        }
    }

    /// `explainer.command`: a command line through `zsh -lc` in the session's folder, expected to leave `explainer.mp4`.
    private func runCommand(_ command: String, _ job: Job, _ request: Request, folder: URL) async throws -> (URL, String) {
        update(job, step: .rendering, progress: nil)
        job.append("$ " + command)
        let record = store.sessionFolder(request.session).appendingPathComponent("record.json").path
        let base = await Task.detached { RepoBase.find(cwd: request.cwd, prBase: request.prBase) }.value
        let environment = [
            "GLANCE_EXPLAINER_OUT": folder.path,
            "GLANCE_RECORD": record,
            "GLANCE_BASE": base ?? "",
            "GLANCE_BRANCH": request.record.branch ?? "",
        ]
        let (cwd, stop) = (request.cwd, job.stop)
        let outcome = await Task.detached {
            ProofScript.runCommand(command, root: cwd, environment: environment, timeout: 30 * 60, stop: stop)
        }.value
        if job.cancelled { throw CancellationError() }
        switch outcome {
        case .failed(let message):
            throw ExplainerFailure(step: .rendering, message: message)
        case .output(let text):
            let video = folder.appendingPathComponent("explainer.mp4")
            guard FileManager.default.fileExists(atPath: video.path) else {
                job.append(String(text.suffix(2_000)))
                throw ExplainerFailure(step: .rendering, message: "The command finished but left no explainer.mp4 in GLANCE_EXPLAINER_OUT.")
            }
            return (video, request.record.branch.map { "Video: \($0)" } ?? "Video")
        }
    }

    /// Claude writes `scenes.html` and `narration.json` into `folder`; this Mac narrates and renders them.
    private func writeAndRender(_ job: Job, _ request: Request, folder: URL) async throws -> (URL, String) {
        update(job, step: .writing, progress: nil)
        // `claude` loads the mods this Studio had on at launch (CLAUDE_CODE_PLUGIN_DIRS), whatever the switch says now.
        if let problem = ExplainerSkill.problem(pluginDirs: ProcessInfo.processInfo.environment[ClaudeMods.pluginDirsKey],
                                                modOn: ModState.load().isOn(ExplainerSkill.mod)) {
            throw ExplainerFailure(step: .writing, message: problem)
        }
        let (cwd, prBase) = (request.cwd, request.prBase)
        let (base, diff) = await Task.detached { () -> (String?, String?) in
            let base = RepoBase.find(cwd: cwd, prBase: prBase)
            return (base, base.flatMap { RepoBase.diff(cwd: cwd, base: $0) })
        }.value
        if job.cancelled { throw CancellationError() }
        job.append(base.map { "Comparing with \($0)" } ?? "No base branch to compare with: explaining from the record alone")

        guard let arguments = ExplainerPrompt.arguments(folder: folder.path, readable: [request.cwd], files: [Self.tokensFile]) else {
            throw ExplainerFailure(step: .writing, message: "Claude can't be given the folder \(folder.path): its name has characters a permission rule can't hold.")
        }
        let prompt = ExplainerPrompt.prompt(record: Self.recordText(request.record), diff: diff, folder: folder.path)
        try await askClaude(job, arguments: arguments, prompt: prompt, folder: request.cwd)
        if job.cancelled { throw CancellationError() }

        let renderer = ExplainerRenderer()
        job.renderer = renderer
        defer { job.renderer = nil }
        let video = try await renderer.render(folder: folder) { [weak self] step, fraction in
            MainActor.assumeIsolated { self?.update(job, step: step, progress: fraction) }
        }
        var title = request.record.branch.map { "Video: \($0)" } ?? "Video"
        if let json = try? Data(contentsOf: folder.appendingPathComponent("narration.json")),
           case .success(let script) = ExplainerScript.parse(json),
           !script.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (video, title)
    }

    /// The record as the prompt's data: everything but this feature's own state, at most 60,000 characters.
    private static func recordText(_ record: WorkRecord) -> String {
        var copy = record
        copy.explainer = nil
        let text = (try? WorkRecord.encoder.encode(copy)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return text.count > 60_000 ? String(text.prefix(60_000)) + "\n(The record was cut here.)" : text
    }

    /// One `claude -p`, 10 minutes at most. What Claude used and said goes to the log that Show log displays.
    private func askClaude(_ job: Job, arguments: [String], prompt: String, folder: String) async throws {
        try await ExplainerClaude.ask(arguments: arguments, prompt: prompt, folder: folder, session: job.claude) { line in
            job.append(line)
        }
    }

    // MARK: State

    /// The run is at `step`, `progress` of the way through it (nil: no measure). The disk copy follows once a second.
    private func update(_ job: Job, step: ExplainerStep, progress: Double?) {
        guard jobs[job.session] === job, !job.cancelled else { return }
        if step != job.state.step { job.append(Self.name(step) + "…") }
        job.state.step = step
        job.state.progress = progress.map { min(1, max(0, $0)) }
        live[job.session] = job.state
        if Date().timeIntervalSince(job.lastWrite) >= 1 {
            job.lastWrite = Date()
            persist(job.state, session: job.session)
        }
    }

    /// The run is over: a failure is kept (and shown with Retry); success and Cancel leave nothing to show.
    private func end(_ job: Job, as failure: ExplainerFailure?) {
        guard jobs[job.session] === job else { return }
        jobs[job.session] = nil
        var state = job.state
        if let failure {
            state.phase = .failed
            state.step = failure.step
            state.progress = nil
            // The reason stays whole at the top; what the run did and Claude said fills the rest, newest last.
            let reason = String(failure.message.prefix(2_000))
            state.log = job.log.isEmpty ? reason : reason + "\n\n" + String(job.log.suffix(4_000 - reason.count - 2))
            live[job.session] = state
            persist(state, session: job.session)
        } else {
            state.phase = .done
            live[job.session] = state
            persist(nil, session: job.session)
        }
    }

    /// Writes `state` (nil: clears it) to the session's record, in order, and tells the panels. The record keeps nothing
    /// of a run that finished.
    private func persist(_ state: ExplainerState?, session: String) {
        let store = store
        writes.async {
            store.update(session: session, budget: 2) { $0.explainer = state }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .workRecordChanged, object: nil, userInfo: ["session": session])
            }
        }
    }

    /// The step as the panel says it.
    nonisolated static func name(_ step: ExplainerStep) -> String {
        switch step {
        case .writing: "Writing"
        case .narrating: "Narrating"
        case .rendering: "Rendering"
        case .muxing: "Muxing"
        }
    }

    /// Removes what an earlier run left in the temporary folder (a crash): anything over a day old. Other Studios may be
    /// running, so a recent folder is left alone.
    nonisolated private static func sweep(in folder: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let changed = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, changed < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
