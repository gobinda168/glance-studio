import GlanceCore
import GlanceKit
import SwiftUI

/// One of the New pull request page's automation switches (spec 2026-10-09-automations-design.md, stage A5): Claude
/// Code Review, Watch for CI and review comments, Let Claude fix red CI. On: installs that automation for the
/// repository (the first time), approves it and switches it on, after a popover that lists what it may do. Off:
/// switches it off (the package and its history stay in Automations). A package already in the library is reused as
/// it is: the switch never overwrites the user's edits.
struct AutomationPRSwitch: View {
    enum Layout {
        /// Checkbox first, then the title and its line (After creating).
        case leading
        /// Claude's dot, the title and its line, the checkbox last (Reviewers).
        case trailing
    }

    /// What the popover shows, and what "Approve and turn on" approves.
    private struct Shown {
        var lines: [String]
        /// `AutomationApproval.hash` of the manifest behind `lines`.
        var hash: String
        /// The package to install first; nil when it is in the library already.
        var install: [String: String]?
        /// Some step asks before it pushes or comments, and the user hasn't trusted the automation.
        var asksFirst: Bool
    }

    let kit: AutomationPRKit
    let repository: String
    /// The repository's local clone (Fix red CI works in a worktree of it).
    let folder: String
    var layout: Layout = .leading
    @ObservedObject private var engine = AutomationEngine.shared
    @State private var shown: Shown?
    @ObservedObject private var origins = AutomationOriginCache.shared
    @State private var problem: String?

    private var id: String? { kit.id(repository: repository) }

    /// Why it can't be switched on yet: Fix red CI would need the repository's own clone (its checkout step refuses
    /// a folder whose origin, fetch or push, is another repository, such as a fork).
    private var blocker: String? {
        guard kit == .fixCI, let id, engine.entry(id) == nil else { return nil }
        guard kit.files(repository: repository, folder: folder) != nil else {
            return "Open this repository in a folder to let Claude fix CI."
        }
        switch origins.verdict(folder: folder, repository: repository) {
        case .matches: return nil
        case .other: return "This folder's origin isn't \(repository). Open that repository's own clone."
        case .unknown: return "Checking this folder's origin…"
        }
    }

    var body: some View {
        let state = AutomationPRKit.state(id.flatMap { engine.entry($0) })
        let neverApproved = id.flatMap { engine.entry($0) }?.approval == .never
        let isOn = Binding<Bool>(get: { state == .on || state == .needsApproval },
                                 set: { on in
                                     // Checked but never approved: a click asks for the approval instead of leaving.
                                     if on || (state == .needsApproval && neverApproved) { turnOn() } else { turnOff() }
                                 })
        VStack(alignment: .leading, spacing: 6) {
            switch layout {
            case .leading:
                Toggle(isOn: isOn) { label(state, neverApproved: neverApproved) }
                    .toggleStyle(.checkbox)
            case .trailing:
                HStack(spacing: 8) {
                    CoralDot(size: 11)
                    label(state, neverApproved: neverApproved)
                    Spacer(minLength: 8)
                    Toggle(kit.title, isOn: isOn)
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                }
            }
            if let problem { InlineError(message: problem) }
        }
        .disabled(id == nil || blocker != nil)
        .help(helpText)
        .task(id: folder + "\n" + repository) {
            if kit == .fixCI, let id, engine.entry(id) == nil { origins.check(folder: folder, repository: repository) }
        }
        .popover(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } }),
                 arrowEdge: .trailing) {
            if let shown {
                AutomationPRConfirm(kit: kit, repository: repository, lines: shown.lines, asksFirst: shown.asksFirst,
                                    cancel: { self.shown = nil }, confirm: confirmed)
            }
        }
    }

    private var helpText: String {
        if id == nil { return "Needs a GitHub repository" }
        return blocker ?? "\(kit.subtitle), for your pull requests in \(repository)"
    }

    private func label(_ state: AutomationPRKit.State, neverApproved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(kit.title).font(.studio(12.5)).foregroundStyle(StudioColors.ink)
            Text(blocker ?? (state == .needsApproval && neverApproved ? "Not approved yet" : kit.caption(state)))
                .font(.studio(11.5))
                .foregroundStyle(state == .needsApproval || state.isBroken ? StudioColors.amber : StudioColors.muted)
        }
    }

    /// What approving allows: the installed version's, or the package about to be installed.
    private func whatApprovingAllows() -> Shown? {
        guard let id else { return nil }
        if let entry = engine.entry(id) {
            guard !entry.isBroken, let manifest = entry.manifest else { return nil }
            return Shown(lines: engine.approvalLines(id), hash: AutomationApproval.hash(manifest), install: nil,
                         asksFirst: !entry.trusted && manifest.steps.contains(where: \.isOutward))
        }
        guard let files = kit.files(repository: repository, folder: folder),
              let text = files[AutomationManifest.fileName],
              let manifest = AutomationManifest.parse(Data(text.utf8)).manifest else { return nil }
        return Shown(lines: AutomationApproval.summary(manifest), hash: AutomationApproval.hash(manifest),
                     install: files, asksFirst: manifest.steps.contains(where: \.isOutward))
    }

    private func turnOn() {
        problem = nil
        guard let id else { return }
        if let entry = engine.entry(id) {
            if entry.isBroken {
                problem = "It has problems. Open it in Automations to fix it, then switch it on."
                return
            }
            // Installed and approved before, only switched off: back on without asking again.
            if entry.approval.isApproved {
                engine.setEnabled(id, true)
                return
            }
        }
        guard let next = whatApprovingAllows() else {
            problem = "It couldn't be set up for \(repository)."
            return
        }
        shown = next
    }

    private func turnOff() {
        problem = nil
        guard let id, engine.entry(id) != nil else { return }
        engine.setEnabled(id, false)
    }

    /// "Approve and turn on": install when missing (a save, so it has history), approve exactly what the popover
    /// showed, switch on.
    private func confirmed() {
        guard let id, let shown else { return }
        self.shown = nil
        if let files = shown.install, engine.entry(id) == nil,
           case .failure(let error) = engine.save(id, files: files) {
            problem = error.message
            return
        }
        switch engine.approve(id, expecting: shown.hash) {
        case .approved: engine.setEnabled(id, true)
        case .changedSinceShown: problem = "It changed while you were looking. Switch it on again to review it."
        case .broken: problem = "It has problems. Open it in Automations to see why."
        case .restoring: problem = "It is being restored. Try again in a moment."
        case .notSaved: problem = "Glance couldn't save the approval. Try again."
        }
    }
}

extension AutomationPRKit.State {
    var isBroken: Bool {
        if case .broken = self { return true }
        return false
    }
}

/// The popover: what the automation does and may do, Cancel and Approve and turn on.
private struct AutomationPRConfirm: View {
    let kit: AutomationPRKit
    let repository: String
    let lines: [String]
    let asksFirst: Bool
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(kit.title) for \(repository)")
                    .font(.studio(13.5, .semibold))
                    .foregroundStyle(StudioColors.ink)
                Text(kit.subtitle).font(.studio(12)).foregroundStyle(StudioColors.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Caption("It may")
                ForEach(lines, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.studio(12)).foregroundStyle(StudioColors.muted)
                        Text(Self.plain(line))
                            .font(.studio(12))
                            .foregroundStyle(StudioColors.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if asksFirst {
                Text("Pushing and commenting wait for your approval each time, unless you trust it in Automations.")
                    .font(.studio(11.5))
                    .foregroundStyle(StudioColors.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("It runs while Glance Studio is open. Change or remove it in Automations.")
                .font(.studio(11.5))
                .foregroundStyle(StudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                StudioButton(title: "Cancel", hint: "Esc", style: .quiet, action: cancel)
                    .keyboardShortcut(.escape, modifiers: [])
                StudioButton(title: "Approve and turn on", hint: "↩", style: .primary, action: confirm)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(StudioColors.card)
    }

    /// Approval lines mark names with backticks; the popover shows them plain.
    static func plain(_ line: String) -> String { line.replacingOccurrences(of: "`", with: "") }
}

/// Whether a folder's origin (fetch and push URL) is the page's repository. Fix red CI's checkout step refuses any
/// other, and in a fork's clone the page's repository is the upstream while origin is the fork. Asked of git off the
/// main thread, once per folder and repository while Studio runs (the page asks again when it appears).
@MainActor
final class AutomationOriginCache: ObservableObject {
    static let shared = AutomationOriginCache()

    enum Verdict { case unknown, matches, other }

    @Published private var verdicts: [String: Bool] = [:]
    private var asked: Set<String> = []

    private func key(_ folder: String, _ repository: String) -> String { folder + "\n" + repository.lowercased() }

    func verdict(folder: String, repository: String) -> Verdict {
        switch verdicts[key(folder, repository)] {
        case nil: .unknown
        case true?: .matches
        case false?: .other
        }
    }

    func check(folder: String, repository: String) {
        let key = key(folder, repository)
        guard verdicts[key] == nil, asked.insert(key).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = [["remote", "get-url", "origin"], ["remote", "get-url", "--push", "origin"]]
                .map { Self.git(folder, $0) }
            let matches = urls.allSatisfy {
                $0.flatMap { PullRequests.repository(remoteURL: $0) }?.lowercased() == repository.lowercased()
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.verdicts[key] = matches } }
        }
    }

    private nonisolated static func git(_ folder: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
