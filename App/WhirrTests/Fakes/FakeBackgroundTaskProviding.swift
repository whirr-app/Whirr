import Foundation
import SyncEngine

/// Test double for `BackgroundTaskProviding`. No real `UIApplication`. Tests drive expiration via
/// `simulateExpiration()`, and force the no-time branch with `hasAvailableBackgroundTime = false`.
final class FakeBackgroundTaskProviding: BackgroundTaskProviding, @unchecked Sendable {
  var hasAvailableBackgroundTime = true

  private(set) var beginCallCount = 0
  private(set) var endCallCount = 0
  private(set) var endedRawValues: [Int] = []
  private var nextRawValue = 0
  private var pendingExpirationHandlers: [Int: @Sendable () -> Void] = [:]

  func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> Int? {
    beginCallCount += 1
    guard hasAvailableBackgroundTime else { return nil }
    let rawValue = nextRawValue
    nextRawValue += 1
    pendingExpirationHandlers[rawValue] = expirationHandler
    return rawValue
  }

  func endTask(_ rawValue: Int) {
    endCallCount += 1
    endedRawValues.append(rawValue)
    pendingExpirationHandlers.removeValue(forKey: rawValue)
  }

  /// Simulates the system revoking every in-flight task's time before its `endTask` arrives.
  func simulateExpiration() {
    for handler in pendingExpirationHandlers.values {
      handler()
    }
  }
}
