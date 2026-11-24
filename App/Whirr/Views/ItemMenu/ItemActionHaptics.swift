import SwiftUI

/// The taps for queue or shelf edits, in one place so surfaces don't drift in weight. No
/// `.success`: that notification pattern is for something the listener must notice and feels like
/// a warning on a routine "add to Up Next"; only a failure escalates. No enabled check:
/// `sensoryFeedback` honours the system Haptics setting.
enum ItemActionHaptics {
  /// A completed edit: added to Up Next, played next, reordered, removed, saved, unsaved.
  static let mutation = SensoryFeedback.impact(weight: .light, intensity: 0.7)

  /// A confirmation that nothing changed: the identity was already queued, or already saved.
  /// Softer and quieter than `mutation`, so "already there" is distinguishable from "just added"
  /// without stopping to read the banner.
  static let noOp = SensoryFeedback.impact(flexibility: .soft, intensity: 0.4)

  /// The one thing on these channels the listener must notice.
  static let failure = SensoryFeedback.error
}
