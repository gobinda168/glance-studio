import Foundation
import GlanceCore

/// New Folder's work, shared by the Open in Editor palette and the Editor start page: make the folder, then `git init`
/// in it when asked. `done` runs on the main actor.
enum NewFolderMaker {
    enum Outcome {
        case made(String)
        /// The folder couldn't be made: why.
        case failed(String)
        /// The folder is there but git init failed: why, and the folder (Open Anyway).
        case gitFailed(String, folder: String)
    }

    @MainActor
    static func make(_ folder: String, gitInit: Bool, done: @escaping @MainActor (Outcome) -> Void) {
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        } catch {
            done(.failed("Couldn't make the folder: \(error.localizedDescription)"))
            return
        }
        guard gitInit else { done(.made(folder)); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = GitHubCLI.execute("/usr/bin/git", ["init", "--quiet"], folder: folder)
            let failure: String? = switch result {
            case nil: "Couldn't run git."
            case let result? where result.status != 0:
                String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            default: nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failure {
                        done(.gitFailed("Made \(EditorFolderPicker.name(folder)), but git init failed: \(failure)", folder: folder))
                    } else {
                        done(.made(folder))
                    }
                }
            }
        }
    }
}
