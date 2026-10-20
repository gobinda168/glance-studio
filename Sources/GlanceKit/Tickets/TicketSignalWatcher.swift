import Foundation
import GlanceCore

/// git and gh, off the main thread, over the folders Glance knows: recent commits and branches, and the user's
/// pull requests (spec "Signals").
enum TicketSignalWatcher {
  struct Scan {
    var commits: [TicketSignals.Commit] = []
    var branches: [TicketSignals.Branch] = []
    var pullRequests: [TicketSignals.PullRequest] = []
    /// A git suggestion's evidence id ("commit:<hash>", "branch:<repository>:<name>") → its repository's folder.
    var roots: [String: String] = [:]
  }

  @MainActor
  static func scan(now: Date, done: @escaping @MainActor (Scan) -> Void) {
    let folders = Prefs.recentProjects.entries.map(\.path)
    let repositories = Prefs.repositoryFolders
    let home = NSHomeDirectory()
    let calendar = Calendar.current
    DispatchQueue.global(qos: .utility).async {
      var scan = Scan()
      let range = DateInterval(start: now.addingTimeInterval(-TicketSignals.window), end: now.addingTimeInterval(60))
      let roots = JournalGit.roots(folders + repositories.values.sorted(), home: home) {
        git(JournalGit.rootArguments(folder: $0))
      }
      for root in roots {
        let repository = TicketSignals.repository(for: root, in: repositories)
        if let email = git(JournalGit.emailArguments(root: root)), !email.isEmpty,
           let log = git(JournalGit.logArguments(root: root, email: email, range: range, calendar: calendar),
                         trim: false) {
          for event in JournalGit.parse(log, root: root, range: range, calendar: calendar) {
            scan.commits.append(TicketSignals.Commit(hash: event.externalID, subject: event.title,
                                                     repository: repository, date: event.start))
            scan.roots["commit:\(event.externalID)"] = root
          }
        }
        if let refs = git(TicketSignals.branchArguments(root: root), trim: false) {
          for branch in TicketSignals.branches(refs, repository: repository) {
            scan.branches.append(branch)
            scan.roots["branch:\(repository ?? ""):\(branch.name)"] = root
          }
        }
      }
      if case .success(let data) = GitHubCLI.run(PullRequests.executable(), TicketSignals.pullRequestArguments(now: now))
        .flatMap(GitHubCLI.graphQLData) {
        scan.pullRequests = TicketSignals.pullRequests(from: data)
      }
      DispatchQueue.main.async { MainActor.assumeIsolated { done(scan) } }
    }
  }

  private static func git(_ arguments: [String], trim: Bool = true) -> String? {
    guard let result = GitHubCLI.execute(JournalGit.git, arguments), result.status == 0 else { return nil }
    let text = String(decoding: result.output, as: UTF8.self)
    return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
  }
}
