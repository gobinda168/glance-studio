import Foundation
import Security

/// Whether this process lets debuggers attach (`com.apple.security.get-task-allow`). If it does, a program could read
/// the unlocked vault out of Studio's memory, so the vault stays locked (spec "Storage").
enum DebuggerCheck {
  static var attachable: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else { return true }
    let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.get-task-allow" as CFString, nil)
    return (value as? Bool) == true
  }
}
