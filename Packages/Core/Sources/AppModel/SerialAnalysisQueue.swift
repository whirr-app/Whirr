import Foundation

/// One serial worker for an analysis coordinator: a wake coalesces into a queued pass, one pass
/// runs at a time, an idle hook runs only when nothing else is queued, and every idle waiter is
/// resumed exactly once.
///
/// The coordinator keeps its policy (what a pass does, the conditions that allow it, what a pass
/// leaves behind) and supplies it as hooks. This type owns only the loop, so
/// `AdSkipCoordinator` and `PauseTrimCoordinator` cannot drift apart on wake, cancellation or
/// resume. A cancelled or failed pass is reported and left pending until the next input, so a
/// persistent fault cannot spin the queue.
actor SerialAnalysisQueue {
  /// The coordinator's half of the queue. Each closure runs while the queue is suspended on it, so
  /// a closure may call back into the queue (`requestPass`, `hasPendingPass`) without deadlocking.
  struct Hooks: Sendable {
    /// One pass: reconcile the inputs against the store and do at most one unit of work. It may
    /// `requestPass()` for a follow-up, as a pass that analysed one episode does.
    var pass: @Sendable () async throws -> Void
    /// After every pass, whatever its outcome: `AdSkipCoordinator` publishes progress here.
    var passDidRun: (@Sendable () async -> Void)?
    /// Once the queue is otherwise empty, and only while not stopped. It may `requestPass()` for
    /// another pass, as AdSkip's carried-plan check does when it finds more to do.
    var idle: (@Sendable () async -> Void)?
    /// Once when the worker ends, before idle waiters resume: per-coordinator cleanup such as
    /// AdSkip's `underAnalysis = nil`.
    var willIdle: (@Sendable () async -> Void)?

    init(
      pass: @escaping @Sendable () async throws -> Void,
      passDidRun: (@Sendable () async -> Void)? = nil,
      idle: (@Sendable () async -> Void)? = nil,
      willIdle: (@Sendable () async -> Void)? = nil
    ) {
      self.pass = pass
      self.passDidRun = passDidRun
      self.idle = idle
      self.willIdle = willIdle
    }
  }

  /// A pass that ended without doing its work. The coordinator owns the wording and the logger,
  /// so each feature keeps logging under its own category.
  struct Reporting: Sendable {
    var cancelled: @Sendable () -> Void
    var failed: @Sendable (any Error) -> Void

    init(cancelled: @escaping @Sendable () -> Void, failed: @escaping @Sendable (any Error) -> Void) {
      self.cancelled = cancelled
      self.failed = failed
    }
  }

  private let hooks: Hooks
  private let reporting: Reporting
  private var worker: Task<Void, Never>?
  private var isDirty = false
  private var isStopped = false
  private var feeders: [Task<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []

  init(hooks: Hooks, reporting: Reporting) {
    self.hooks = hooks
    self.reporting = reporting
  }

  /// Whether the queue has been stopped. Actor-isolated, so a coordinator reads it with `await`.
  var hasStopped: Bool { isStopped }

  /// Whether a pass is queued. A pass reads this to stop early when an input has arrived.
  var hasPendingPass: Bool { isDirty }

  /// Asks for a pass, starting the worker when none is running.
  func wake() {
    guard isStopped == false else { return }
    isDirty = true
    guard worker == nil else { return }
    worker = Task { await self.drain() }
  }

  /// Asks for another pass from inside one, without starting a worker.
  func requestPass() { isDirty = true }

  /// Returns once the worker has nothing left to do.
  func waitUntilIdle() async {
    guard worker != nil else { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }

  /// Installs the input feeders, once. False when they are already installed or the queue has
  /// stopped, so the caller leaves each input stream unconsumed.
  func installFeeders(_ make: @Sendable () -> [Task<Void, Never>]) -> Bool {
    guard feeders.isEmpty, isStopped == false else { return false }
    feeders = make()
    return true
  }

  /// Ends the queue for good: no pass runs again and the feeders are cancelled. The coordinator
  /// still cancels its own in-flight work.
  func stop() {
    isStopped = true
    for feeder in feeders { feeder.cancel() }
    feeders = []
  }

  private func drain() async {
    while true {
      while isDirty && isStopped == false {
        isDirty = false
        do {
          try await hooks.pass()
        } catch is CancellationError {
          reporting.cancelled()
        } catch {
          reporting.failed(error)
        }
        await hooks.passDidRun?()
      }
      // Only once nothing else waits; it stops early when an input arrives.
      if isStopped == false { await hooks.idle?() }
      if isDirty && isStopped == false { continue }
      await hooks.willIdle?()
      // A wake that arrived while the end-of-drain hook ran must not be lost with the worker.
      if isDirty && isStopped == false { continue }
      break
    }
    worker = nil
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }
}
