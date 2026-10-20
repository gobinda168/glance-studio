/// Glance Studio's two editor tabs (spec 2026-10-06-vscode-editor-tab-design.md, "Two editors"). The raw values are
/// the tab kinds the editor windows register under.
public enum EditorKind: String, CaseIterable, Sendable {
  /// The built-in Monaco editor: instant and light. The default.
  case razor
  /// VS Code's workbench from the local VSCodium server: extensions and IntelliSense, downloaded on first use.
  case studio

  public static let defaultKind = EditorKind.razor

  /// The saved choice; anything missing or unknown is the default.
  public init(stored: String?) {
    self = stored.flatMap(EditorKind.init(rawValue:)) ?? .defaultKind
  }

  public var name: String {
    switch self {
    case .razor: return "Razor Code"
    case .studio: return "GS Code"
    }
  }

  /// The SF Symbol shown with the name.
  public var symbol: String {
    switch self {
    case .razor: return "bolt.fill"
    case .studio: return "g.square.fill"
    }
  }

  public var other: EditorKind { self == .razor ? .studio : .razor }

  /// The swap button in an editor tab of this kind.
  public var swapTitle: String { "Open in \(other.name)" }

  /// Where a link to a project's file opens: the project's open tab (the preferred kind when both are open), else a
  /// new tab of the preferred kind.
  public static func target(open: [EditorKind], preferred: EditorKind) -> EditorKind {
    open.contains(preferred) ? preferred : open.first ?? preferred
  }
}
