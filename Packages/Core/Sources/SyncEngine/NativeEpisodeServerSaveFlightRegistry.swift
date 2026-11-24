import Foundation

/// Waiters-by-key flight table for one account-scoped save. The coordinator owns the only
/// instance and is the only thing that serializes it, so the table needs no isolation of its own;
/// it has the same shape as `URLFlightPool`. Every access is a synchronous call from an
/// actor-isolated method, so no read-modify-write of the table spans an `await`.
struct NativeEpisodeServerSaveFlightRegistry {
  /// Reference-counted around a coalesced flight's task: the underlying task is cancelled only
  /// when the last coalesced waiter has stopped waiting, so one caller's teardown cannot cancel
  /// another caller's still-active save. `onCancel` handlers run off the actor, so the waiter count
  /// needs its own lock rather than actor isolation.
  final class FlightTask: @unchecked Sendable {
    let id: UInt64
    let task: Task<NativeEpisodeServerSaveOutcome, Never>
    private let lock = NSLock()
    private var waiterCount = 0

    init(id: UInt64, task: Task<NativeEpisodeServerSaveOutcome, Never>) {
      self.id = id
      self.task = task
    }

    func addWaiter() {
      lock.lock()
      waiterCount += 1
      lock.unlock()
    }

    func removeWaiterCancellingIfAbandoned() {
      lock.lock()
      waiterCount -= 1
      let abandoned = waiterCount <= 0
      lock.unlock()
      if abandoned { task.cancel() }
    }
  }

  private var nextFlightID: UInt64 = 0
  private var flights = [NativeEpisodeServerSaveFlightKey: FlightTask]()

  mutating func nextID() -> UInt64 {
    nextFlightID &+= 1
    return nextFlightID
  }

  func flight(for key: NativeEpisodeServerSaveFlightKey) -> FlightTask? {
    flights[key]
  }

  mutating func install(_ flight: FlightTask, for key: NativeEpisodeServerSaveFlightKey) {
    flights[key] = flight
  }

  /// Removes `flight` only while it is still the one installed for `key`, so a finished flight
  /// cannot retire a newer one installed under the same key while it waited.
  mutating func retire(_ flight: FlightTask, for key: NativeEpisodeServerSaveFlightKey) {
    guard flights[key]?.id == flight.id else { return }
    flights.removeValue(forKey: key)
  }
}

extension NativeEpisodeServerSaveCoordinator {
  /// The registry owns the type; this alias keeps it spellable as a coordinator member, where the
  /// coalescing code and the waiter-cancellation test refer to it.
  typealias FlightTask = NativeEpisodeServerSaveFlightRegistry.FlightTask
}
