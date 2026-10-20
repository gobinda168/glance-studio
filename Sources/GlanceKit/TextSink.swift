import AppKit

/// Where dictated text goes. The overlay types into the app in front; Glance Studio writes into its own terminal.
@MainActor
public protocol TextSink: AnyObject {
  /// False when text can't go in yet (Accessibility isn't granted, say); dictation then shows `accessHint`.
  var canInsert: Bool { get }
  var accessHint: String { get }
  /// Asks macOS for whatever permission `canInsert` is waiting on.
  func requestAccess()
  func insert(_ text: String) -> TextInserter.Outcome
}

/// Types into whichever app has keyboard focus, through Accessibility. The overlay's sink.
@MainActor
public final class AccessibilityTextSink: TextSink {
  public init() {}

  public var canInsert: Bool { TextInserter.canType }
  public var accessHint: String { TextInserter.accessibilityHint }
  public func requestAccess() { CGRequestPostEventAccess() }
  public func insert(_ text: String) -> TextInserter.Outcome { TextInserter.insert(text) }
}
