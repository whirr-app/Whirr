import Foundation

/// The state and generation arithmetic both Watch copy stores apply to the same shared row and
/// state enum. Internal: one definition of each rule, not API.
enum WatchCopyArithmetic {
  /// A row the state machine will not move except through a re-request or an inventory entry.
  static func isTerminal(_ state: RSSWatchCopyState) -> Bool {
    switch state {
    case .removed, .declined, .failed, .delivered: return true
    case .wanted, .waitingForWatch, .sending: return false
    }
  }

  /// `UInt64` wire values into the `INTEGER` column without trapping; a value beyond `Int64.max`
  /// is already past anything this device could have issued.
  static func saturated(_ value: UInt64) -> Int64 {
    value > UInt64(Int64.max) ? Int64.max : Int64(value)
  }

  /// One above `value`, saturating at `Int64.max`.
  static func incremented(_ value: Int64) -> Int64 {
    value == Int64.max ? Int64.max : value + 1
  }
}
