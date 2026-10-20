import Foundation

/// Monaco language ids for the editor's languages.
public enum EditorLanguage {
  private static let byExtension: [String: String] = [
    "ts": "typescript", "tsx": "typescript", "mts": "typescript", "cts": "typescript",
    "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
    "json": "json", "html": "html", "htm": "html", "css": "css",
    "md": "markdown", "markdown": "markdown", "yaml": "yaml", "yml": "yaml",
    "py": "python", "swift": "swift", "go": "go", "rs": "rust",
    "sh": "shell", "bash": "shell", "zsh": "shell",
  ]

  public static func id(forPath path: String) -> String {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "plaintext" }
    return byExtension[name[name.index(after: dot)...].lowercased()] ?? "plaintext"
  }
}
