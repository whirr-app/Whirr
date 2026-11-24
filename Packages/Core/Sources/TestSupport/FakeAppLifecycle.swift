import Foundation
import SyncEngine
import Testing

public final class FakeAppLifecycle: AppLifecycle, @unchecked Sendable {
  private let lifecycleLock = NSLock()
  private var foreground = true
  private var lifecycleSubscribers: [UUID: AsyncStream<AppLifecycleTransition>.Continuation] = [:]

  public var isForeground: Bool {
    get {
      lifecycleLock.lock()
      defer { lifecycleLock.unlock() }
      return foreground
    }
    set {
      lifecycleLock.lock()
      foreground = newValue
      lifecycleLock.unlock()
    }
  }

  public var transitions: AsyncStream<AppLifecycleTransition> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      lifecycleLock.lock()
      lifecycleSubscribers[id] = continuation
      lifecycleLock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeLifecycleSubscriber(id)
      }
    }
  }

  /// How many live `transitions` consumers there are. A cancelled subscriber's `for await` exits,
  /// which terminates its continuation and drops it from this count. Waiting for zero is a
  /// deterministic check that a subscription task was torn down, rather than an unbounded
  /// "assert nothing happened" wait.
  public var lifecycleSubscriberCount: Int {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return lifecycleSubscribers.count
  }

  public init() {}

  /// Test-only trigger simulating a foreground transition (used by `ForegroundPullTests`).
  public func simulateForeground() {
    simulateLifecycleTransition(.foreground)
  }

  /// Test-only trigger simulating a background transition.
  public func simulateBackground() {
    simulateLifecycleTransition(.background)
  }

  private func simulateLifecycleTransition(_ transition: AppLifecycleTransition) {
    lifecycleLock.lock()
    foreground = transition == .foreground
    for continuation in lifecycleSubscribers.values {
      continuation.yield(transition)
    }
    lifecycleLock.unlock()
  }

  private func removeLifecycleSubscriber(_ id: UUID) {
    lifecycleLock.lock()
    lifecycleSubscribers.removeValue(forKey: id)
    lifecycleLock.unlock()
  }

  // MARK: - Bounded background tasks

  private struct BackgroundTaskBookkeeping: Sendable {
    var nextRawValue = 0
    /// Holds an entry for a token only between `beginBackgroundTask` and `endBackgroundTask`, so
    /// its size is the number of bounded background tasks in flight.
    var pendingExpirationHandlers: [Int: @Sendable () -> Void] = [:]
    var beginCount = 0
    var endCount = 0
  }
  private let backgroundTasks = WaitableState(
    BackgroundTaskBookkeeping(), label: "FakeAppLifecycle background tasks"
  ) { "saw \($0.beginCount) began and \($0.endCount) ended tasks" }

  public var backgroundTaskBeginCount: Int { backgroundTasks.value.beginCount }
  public var backgroundTaskEndCount: Int { backgroundTasks.value.endCount }
  public var activeBackgroundTaskCount: Int { backgroundTasks.value.pendingExpirationHandlers.count }

  public func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
    backgroundTasks.mutate { state in
      let raw = state.nextRawValue
      state.nextRawValue += 1
      state.pendingExpirationHandlers[raw] = expirationHandler
      state.beginCount += 1
      return BackgroundTaskToken(rawValue: raw)
    }
  }

  public func endBackgroundTask(_ token: BackgroundTaskToken) {
    backgroundTasks.mutate { state in
      state.pendingExpirationHandlers.removeValue(forKey: token.rawValue)
      state.endCount += 1
    }
  }

  /// Test-only: suspends, bounded, until the begin/end counters satisfy `predicate`.
  @discardableResult
  public func waitForBackgroundTasks(
    timeout: TimeInterval = 10,
    sourceLocation: SourceLocation = #_sourceLocation,
    satisfying predicate: @escaping @Sendable (_ beginCount: Int, _ endCount: Int) -> Bool
  ) async -> TestWaitOutcome {
    await backgroundTasks.waitUntil(timeout: timeout, sourceLocation: sourceLocation) {
      predicate($0.beginCount, $0.endCount)
    }
  }

  /// Test-only: simulates the system revoking every currently in-flight bounded background
  /// task's time before its matching `endBackgroundTask` call ever arrived.
  public func simulateBackgroundTaskExpiration() {
    let handlers = backgroundTasks.value.pendingExpirationHandlers.values
    for handler in handlers { handler() }
  }
}
