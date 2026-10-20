import Foundation

/// Where a web tab's downloads go: ~/Downloads/<name>, with " 2", " 3"… before the extension when the name is taken.
enum WebDownloads {
    static func destination(for name: String) -> URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name.isEmpty ? "download" : name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }
}
