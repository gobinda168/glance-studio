import Foundation
import LocalAuthentication

/// Touch ID, or the login password on a Mac without it (spec "Approval card"): the one answer a script driving
/// Studio's buttons through Accessibility can't give.
public enum OwnerCheck {
  /// Shows the system sheet ("Glance Studio is trying to <reason>."). False when it was cancelled or failed, or the
  /// Mac can't ask.
  public static func confirm(_ reason: String) async -> Bool { await confirm(reason, context: LAContext()) }

  /// The same, with a context the caller keeps: `context.invalidate()` closes a sheet nobody needs any more (the
  /// answer is then false).
  static func confirm(_ reason: String, context: LAContext) async -> Bool {
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
    return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
  }
}
