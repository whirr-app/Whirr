import Foundation

/// One observed network path characteristic relevant to API-CONVENTIONS.md rule 7's
/// degraded-cadence predicate. A plain, `Network`-free shape so the mapping stays Foundation-only
/// and testable without a real `NWPathMonitor` (ARCHITECTURE.md). `isSatisfied == false` covers
/// both "genuinely offline" and "not yet known"; it is not an online/offline oracle, so both map
/// to not-degraded (see `NetworkConditionsReducer`).
public struct PathSnapshot: Sendable, Equatable {
  public let isSatisfied: Bool
  public let isCellular: Bool
  public let isConstrained: Bool

  public init(isSatisfied: Bool, isCellular: Bool, isConstrained: Bool) {
    self.isSatisfied = isSatisfied
    self.isCellular = isCellular
    self.isConstrained = isConstrained
  }
}

/// Narrow abstraction over `NWPathMonitor`'s update delivery (no Core target may import
/// `Network`; see ARCHITECTURE.md). The concrete conformance, `RealPathObserving`, lives in App.
/// Tests inject a fake that calls `onUpdate` directly.
public protocol PathObserving: Sendable {
  /// The path as of the moment observation starts. Read once, synchronously, so a fresh
  /// `NetworkConditionsReducer`'s first snapshot is never "unknown" while waiting on a first
  /// `onUpdate` callback.
  var currentPath: PathSnapshot { get }
  /// Begins delivering every subsequent path change to `onUpdate`. Called at most once per
  /// instance.
  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void)
  /// Cancels the underlying monitor/queue. Safe to call even if `startObserving` was never
  /// called.
  func stopObserving()
}

/// Narrow abstraction over `ProcessInfo.isLowPowerModeEnabled` +
/// `.powerStateDidChangeNotification` (no Core target may read `ProcessInfo` power state
/// directly; see ARCHITECTURE.md). The concrete conformance, `RealPowerObserving`, lives in App.
/// Tests inject a fake that calls `onChange` directly.
public protocol PowerObserving: Sendable {
  var isLowPowerModeEnabled: Bool { get }
  /// Begins delivering every subsequent Low Power Mode change to `onChange`. Called at most once
  /// per instance.
  func startObserving(onChange: @escaping @Sendable (Bool) -> Void)
  /// Cancels the underlying notification observer. Safe to call even if `startObserving` was
  /// never called.
  func stopObserving()
}

/// `NetworkConditions`'s pure-mapping half. Maps an injected `PathObserving` + `PowerObserving`
/// pair onto API-CONVENTIONS.md rule 7's `isConstrainedOrCellular`/`isLowPowerMode` predicate and
/// republishes only changes, on a fresh `changes` stream per subscriber that replays the latest
/// snapshot. Foundation-only (macOS-host testable) since `Network`/`ProcessInfo` sit behind the
/// two protocols; the App target supplies the real adapters.
public final class NetworkConditionsReducer: NetworkConditions, @unchecked Sendable {
  private let lock = NSLock()
  private var snapshot: NetworkConditionsSnapshot
  private var subscribers: [UUID: AsyncStream<NetworkConditionsSnapshot>.Continuation] = [:]

  private let path: PathObserving
  private let power: PowerObserving

  public init(path: PathObserving, power: PowerObserving) {
    self.path = path
    self.power = power
    snapshot = NetworkConditionsSnapshot(
      isLowPowerMode: power.isLowPowerModeEnabled,
      isConstrainedOrCellular: Self.isConstrainedOrCellular(path.currentPath)
    )

    path.startObserving { [weak self] pathSnapshot in
      self?.apply(isConstrainedOrCellular: Self.isConstrainedOrCellular(pathSnapshot))
    }
    power.startObserving { [weak self] isLowPowerModeEnabled in
      self?.apply(isLowPowerMode: isLowPowerModeEnabled)
    }
  }

  public var isLowPowerMode: Bool {
    lock.lock()
    defer { lock.unlock() }
    return snapshot.isLowPowerMode
  }

  public var isConstrainedOrCellular: Bool {
    lock.lock()
    defer { lock.unlock() }
    return snapshot.isConstrainedOrCellular
  }

  public var changes: AsyncStream<NetworkConditionsSnapshot> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      lock.lock()
      subscribers[id] = continuation
      continuation.yield(snapshot)
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id)
      }
    }
  }

  deinit {
    path.stopObserving()
    power.stopObserving()
    lock.lock()
    let continuations = Array(subscribers.values)
    subscribers.removeAll()
    lock.unlock()
    for continuation in continuations {
      continuation.finish()
    }
  }

  private func apply(isLowPowerMode: Bool? = nil, isConstrainedOrCellular: Bool? = nil) {
    lock.lock()
    let updated = NetworkConditionsSnapshot(
      isLowPowerMode: isLowPowerMode ?? snapshot.isLowPowerMode,
      isConstrainedOrCellular: isConstrainedOrCellular ?? snapshot.isConstrainedOrCellular
    )
    guard updated != snapshot else {
      lock.unlock()
      return
    }
    snapshot = updated
    for continuation in subscribers.values {
      continuation.yield(updated)
    }
    lock.unlock()
  }

  private func removeSubscriber(_ id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }

  /// Wi-Fi (unconstrained) maps to `false`; cellular or constrained Wi-Fi maps to `true`; an
  /// unsatisfied (or not-yet-known) path maps to `false`, since reachability is not treated as
  /// an online/offline oracle and "no path at all" is not a degraded-cadence signal.
  private static func isConstrainedOrCellular(_ path: PathSnapshot) -> Bool {
    path.isSatisfied && (path.isCellular || path.isConstrained)
  }
}
