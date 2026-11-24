import Foundation
import SyncEngine

/// Injected `SyncClock` for backoff-pacing tests. Mutable, so a test can advance time without a
/// real sleep.
public final class FakeSyncClock: SyncClock, @unchecked Sendable {
  private struct State {
    var now: Date
    /// Instants handed out by successive `now()` calls before `now` takes over.
    var pending: [Date] = []
  }

  private let storage: Locked<State>

  public init(now: Date = Date(timeIntervalSince1970: 0)) {
    storage = Locked(State(now: now))
  }

  /// A clock whose successive `now()` calls return `readings` in order; once one is left it repeats
  /// that instant. For a test that needs two reads of the same clock to differ, such as a
  /// backwards step. `readings` must not be empty.
  public init(reading readings: [Date]) {
    precondition(readings.isEmpty == false, "FakeSyncClock(reading:) needs at least one instant")
    storage = Locked(State(now: readings[readings.count - 1], pending: Array(readings.dropLast())))
  }

  public func now() -> Date {
    storage.withValue { state in
      state.pending.isEmpty ? state.now : state.pending.removeFirst()
    }
  }

  public func advance(by interval: TimeInterval) {
    storage.withValue { $0.now = $0.now.addingTimeInterval(interval) }
  }

  public func set(_ date: Date) {
    storage.withValue { $0.now = date }
  }
}
