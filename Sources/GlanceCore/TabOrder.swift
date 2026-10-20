import Foundation

/// Drag-and-drop maths for reordering tabs.
public enum TabOrder {
  public static func insertionIndex(from: Int, toOffset: Int) -> Int? {
    guard from >= 0, toOffset >= 0 else { return nil }
    let destination = toOffset > from ? toOffset - 1 : toOffset
    return destination == from ? nil : destination
  }
}
