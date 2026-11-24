import Foundation
import SyncEngine

/// Test double for `PathObserving`. No real `NWPathMonitor` or queue. Tests drive updates via
/// `simulate(_:)`.
final class FakePathObserving: PathObserving, @unchecked Sendable {
  let currentPath: PathSnapshot
  private var onUpdate: (@Sendable (PathSnapshot) -> Void)?
  private(set) var stopObservingCallCount = 0

  init(initial: PathSnapshot) {
    currentPath = initial
  }

  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void) {
    self.onUpdate = onUpdate
  }

  func stopObserving() {
    stopObservingCallCount += 1
  }

  func simulate(_ path: PathSnapshot) {
    onUpdate?(path)
  }
}
