/// One `NetworkConditions` observation: the two booleans together, as they stood at the moment
/// something changed. Carried on `NetworkConditions.changes` so a subscriber never has to race
/// back to the synchronous getters to learn what just changed.
public struct NetworkConditionsSnapshot: Sendable, Equatable {
  public let isLowPowerMode: Bool
  public let isConstrainedOrCellular: Bool

  public init(isLowPowerMode: Bool, isConstrainedOrCellular: Bool) {
    self.isLowPowerMode = isLowPowerMode
    self.isConstrainedOrCellular = isConstrainedOrCellular
  }

  /// API-CONVENTIONS rule 7's degraded-cadence predicate: either condition alone is sufficient
  /// to drop to the 60 s interval.
  public var isDegraded: Bool { isLowPowerMode || isConstrainedOrCellular }
}

/// Degraded-cadence inputs for API-CONVENTIONS rule 7 (60 s under Low Power Mode or
/// cellular) and rule 25's cellular-download opt-in.
///
/// No Core target may import Network or read `ProcessInfo` power state directly; the
/// `NWPathMonitor`/`ProcessInfo` adapter lives in App (ARCHITECTURE.md).
///
/// Every access to `changes` returns a separate subscription that first receives the current
/// snapshot, then each change, so several subsystems can observe one conformance without racing.
public protocol NetworkConditions: Sendable {
  var isLowPowerMode: Bool { get }
  var isConstrainedOrCellular: Bool { get }
  var changes: AsyncStream<NetworkConditionsSnapshot> { get }
}

/// One foreground/background transition. Only the direction matters to the sync trigger: no
/// payload, no timestamp. SyncEngine reacts to the event and does not schedule around it (rule 20
/// forbids timer-based polling).
public enum AppLifecycleTransition: Sendable, Equatable {
  case foreground
  case background
}

/// A single bounded background task's identity, opaque to callers. `beginBackgroundTask` returns
/// one so `endBackgroundTask` can name which to end, mirroring
/// `UIApplication.beginBackgroundTask(expirationHandler:)`.
public struct BackgroundTaskToken: Sendable, Equatable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }
}

/// Foreground/background transitions and bounded background-task handles.
///
/// Foreground pull is the v1 correctness path (API-CONVENTIONS rule 20) and session close on
/// suspension (rule 9) needs the bounded task (ARCHITECTURE.md).
///
/// Every access to `transitions` returns an independent subscription to subsequent lifecycle
/// edges. Transitions are not replayed; read `isForeground` for the current state.
///
/// `beginBackgroundTask`/`endBackgroundTask` default to a no-op pass-through below;
/// `ScenePhaseAppLifecycle` overrides them with a `UIApplication`-backed one.
public protocol AppLifecycle: Sendable {
  var isForeground: Bool { get }
  var transitions: AsyncStream<AppLifecycleTransition> { get }

  /// Requests bounded background execution time for a suspension-time close attempt
  /// (API-CONVENTIONS rule 9). `expirationHandler` fires if the system revokes the time before
  /// the matching `endBackgroundTask` call. Never invoked after that call for the same token.
  func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken
  /// Ends the bounded background task identified by `token`. Safe to call exactly once per token
  /// returned from `beginBackgroundTask`.
  func endBackgroundTask(_ token: BackgroundTaskToken)
}

extension AppLifecycle {
  /// Default behaviour: begins and ends a token that carries no OS-level protection, and never
  /// invokes `expirationHandler` (there is no expiration signal without a platform adapter). The
  /// protected operation simply runs to completion.
  public func beginBackgroundTask(expirationHandler: @escaping @Sendable () -> Void) -> BackgroundTaskToken {
    BackgroundTaskToken(rawValue: 0)
  }
  public func endBackgroundTask(_ token: BackgroundTaskToken) {}

  /// Runs `operation` under one bounded background task (API-CONVENTIONS rule 9): begins one,
  /// ends it once `operation` finishes (success or not), and cancels `operation`'s own `Task` if
  /// the system's expiration handler fires first. A suspension-time close attempt gets a chance
  /// to complete without running on borrowed time. Shared by `SyncEngine`'s lifecycle subscriber
  /// and the reader's background flush, so both follow one cancel-on-expiry rule.
  public func runBoundedBackgroundTask(_ operation: @escaping @Sendable () async -> Void) async {
    let task = Task { await operation() }
    let token = beginBackgroundTask { task.cancel() }
    _ = await task.value
    endBackgroundTask(token)
  }
}
