import AppKit
import SwiftUI
import GlanceCore

/// The paths `@` offers: tracked files of the project (git), else a shallow walk of the folder.
enum ProjectFiles {
    static func list(in folder: String, cap: Int) -> [String] {
        if let result = GitHubCLI.execute("/usr/bin/git", ["-C", folder, "ls-files", "-z"], environment: WorkingChanges.environment),
           result.status == 0 {
            var paths: [String] = []
            for part in result.output.split(separator: 0, omittingEmptySubsequences: true) {
                paths.append(String(decoding: part, as: UTF8.self))
                if paths.count >= cap { break }
            }
            return paths
        }
        var paths: [String] = []
        let root = URL(fileURLWithPath: folder)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in walker {
            if walker.level > 4 || url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            paths.append(String(url.path.dropFirst(root.path.count + 1)))
            if paths.count >= cap { break }
        }
        return paths
    }
}
