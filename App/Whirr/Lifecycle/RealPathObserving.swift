import Foundation
import Network
import SyncEngine

/// Real `PathObserving`, wrapping `NWPathMonitor` (ARCHITECTURE.md §3) on its own serial queue,
/// never the main queue: `NetworkConditionsReducer` doesn't assume `onUpdate`'s thread. Until the
/// first update `currentPath` is empty and unsatisfied, reading as "not cellular, not
/// constrained", so a caller deciding from the first snapshot (the background refresh's cellular
/// guard) awaits `firstPath(within:)`.
nonisolated final class RealPathObserving: PathObserving, @unchecked Sendable {
  private let monitor: NWPathMonitor
  private let queue = DispatchQueue(label: "com.remoteconcern.whirr.network-path-observing")
  private let latch = PathUpdateLatch()
  private let lock = NSLock()
  private var onUpdate: (@Sendable (PathSnapshot) -> Void)?
  private var isStarted = false

  var currentPath: PathSnapshot {
    latch.latest ?? Self.snapshot(monitor.currentPath)
  }

  init() {
    monitor = NWPathMonitor()
  }

  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void) {
    lock.withLock { self.onUpdate = onUpdate }
    start()
  }

  func stopObserving() {
    monitor.cancel()
  }

  /// The monitor's first reported path, or `nil` if none arrives within `timeout`.
  func firstPath(within timeout: Duration) async -> PathSnapshot? {
    start()
    return await latch.first(within: timeout)
  }

  private func start() {
    let shouldStart = lock.withLock {
      defer { isStarted = true }
      return isStarted == false
    }
    guard shouldStart else { return }
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let snapshot = Self.snapshot(path)
      latch.record(snapshot)
      lock.withLock { self.onUpdate }?(snapshot)
    }
    monitor.start(queue: queue)
  }

  private static func snapshot(_ path: NWPath) -> PathSnapshot {
    PathSnapshot(
      isSatisfied: path.status == .satisfied,
      isCellular: path.usesInterfaceType(.cellular),
      isConstrained: path.isConstrained
    )
  }
}

/// The latest path a monitor has actually reported, and a bounded wait for the first one.
nonisolated final class PathUpdateLatch: @unchecked Sendable {
  private let lock = NSLock()
  private var value: PathSnapshot?

  var latest: PathSnapshot? { lock.withLock { value } }

  func record(_ snapshot: PathSnapshot) {
    lock.withLock { value = snapshot }
  }

  func first(within timeout: Duration) async -> PathSnapshot? {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      if let latest { return latest }
      guard clock.now < deadline, Task.isCancelled == false else { return nil }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }
}
