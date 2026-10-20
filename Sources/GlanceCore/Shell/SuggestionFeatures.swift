import Foundation

/// The terminal suggestions' switches (spec "Settings: the Suggestions section"); the raw values are the names
/// `config` sends the zsh plugin.
public enum SuggestionFeature: String, CaseIterable, Sendable {
  /// The Tab menu.
  case tab
  /// Ghost text while typing.
  case ghost
  /// The next command on an empty prompt.
  case next
  /// The ↑ history list.
  case up
  /// ⌃R history search.
  case search
  /// Error marks while typing.
  case marks
  /// Fixes after a failed command.
  case fixes
  /// Claude in the terminal (`#` requests, Ask Claude ⌘I).
  case claude
}

/// What is on. Stored as what was switched off, so a feature added later starts on.
public struct SuggestionSettings: Equatable, Sendable, Codable {
  private var off: Set<String>
  public var recordHistory: Bool

  public init(off: Set<SuggestionFeature> = [], recordHistory: Bool = true) {
    self.off = Set(off.map(\.rawValue))
    self.recordHistory = recordHistory
  }

  public func isOn(_ feature: SuggestionFeature) -> Bool { !off.contains(feature.rawValue) }

  public mutating func set(_ feature: SuggestionFeature, _ on: Bool) {
    if on { off.remove(feature.rawValue) } else { off.insert(feature.rawValue) }
  }

  /// What `config` sends: the features that are on, in a fixed order.
  public var wireFeatures: [String] { SuggestionFeature.allCases.filter(isOn).map(\.rawValue) }
}
