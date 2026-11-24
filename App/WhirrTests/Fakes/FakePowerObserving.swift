import Foundation
import SyncEngine

/// Test double for `PowerObserving`. No real `ProcessInfo` or `NotificationCenter`. Tests drive
/// updates via `simulate(_:)`.
final class FakePowerObserving: PowerObserving, @unchecked Sendable {
  let isLowPowerModeEnabled: Bool
  private var onChange: (@Sendable (Bool) -> Void)?
  private(set) var stopObservingCallCount = 0

  init(initial: Bool) {
    isLowPowerModeEnabled = initial
  }

  func startObserving(onChange: @escaping @Sendable (Bool) -> Void) {
    self.onChange = onChange
  }

  func stopObserving() {
    stopObservingCallCount += 1
  }

  func simulate(_ isLowPowerModeEnabled: Bool) {
    onChange?(isLowPowerModeEnabled)
  }
}
