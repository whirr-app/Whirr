import Foundation

@testable import SyncEngine

/// Test double for `PathObserving`: no real `NWPathMonitor` or queue. Tests drive updates
/// directly via `simulate(_:)`. The lock keeps a reducer's callback and a test's `simulate` from
/// racing; the stop count lets lifecycle tests assert the reducer cancels what it started.
final class FakePathObserving: PathObserving, @unchecked Sendable {
  let currentPath: PathSnapshot
  private let lock = NSLock()
  private var onUpdate: (@Sendable (PathSnapshot) -> Void)?
  private(set) var stopObservingCallCount = 0

  init(initial: PathSnapshot) {
    currentPath = initial
  }

  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void) {
    lock.lock()
    self.onUpdate = onUpdate
    lock.unlock()
  }

  func stopObserving() {
    lock.lock()
    stopObservingCallCount += 1
    lock.unlock()
  }

  func simulate(_ path: PathSnapshot) {
    lock.lock()
    let callback = onUpdate
    lock.unlock()
    callback?(path)
  }
}
