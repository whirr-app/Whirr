import Foundation
import SyncEngine

public final class FakeNetworkConditions: NetworkConditions, @unchecked Sendable {
  private let lock = NSLock()
  private var lowPower = false
  private var cellular = false
  private var subscribers: [UUID: AsyncStream<NetworkConditionsSnapshot>.Continuation] = [:]

  public var isLowPowerMode: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return lowPower
    }
    set {
      lock.lock()
      lowPower = newValue
      lock.unlock()
    }
  }

  public var isConstrainedOrCellular: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return cellular
    }
    set {
      lock.lock()
      cellular = newValue
      lock.unlock()
    }
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
      continuation.yield(
        NetworkConditionsSnapshot(isLowPowerMode: lowPower, isConstrainedOrCellular: cellular))
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeNetworkSubscriber(id)
      }
    }
  }

  public init(isLowPowerMode: Bool = false, isConstrainedOrCellular: Bool = false) {
    lowPower = isLowPowerMode
    cellular = isConstrainedOrCellular
  }

  /// How many `changes` streams are live: one per `changes` read, dropped when its consumer
  /// finishes or is cancelled. A test uses it to prove a coordinator subscribed or tore down.
  public var subscriberCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return subscribers.count
  }

  /// Test-only: simulates a condition change reaching every subscriber. Omitted parameters
  /// keep their current value; the plain getters above are updated too, so a caller reading them
  /// synchronously afterward sees the same values the emitted snapshot carries.
  public func simulateChange(isLowPowerMode: Bool? = nil, isConstrainedOrCellular: Bool? = nil) {
    lock.lock()
    if let isLowPowerMode { lowPower = isLowPowerMode }
    if let isConstrainedOrCellular { cellular = isConstrainedOrCellular }
    let snapshot = NetworkConditionsSnapshot(
      isLowPowerMode: lowPower, isConstrainedOrCellular: cellular)
    for continuation in subscribers.values {
      continuation.yield(snapshot)
    }
    lock.unlock()
  }

  private func removeNetworkSubscriber(_ id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }
}
