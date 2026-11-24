import Foundation
import Persistence

/// NativeEpisodeServerSaveFlight coalescing: one task per episode, shared by every re-entrant caller with the same key.
extension NativeEpisodeServerSaveCoordinator {
  /// Adds a recovery operation to the same per-episode flight map used by a normal save. Recovery
  /// and retry callers must use this gate so a relaunch-time operation cannot race a live save.
  func startSerializedFlight(
    key: NativeEpisodeServerSaveFlightKey,
    operation: @escaping @Sendable () async -> NativeEpisodeServerSaveOutcome
  ) async -> NativeEpisodeServerSaveOutcome {
    if let existing = flightRegistry.flight(for: key) {
      _ = await waitForFlight(existing, key: key)
    }
    // Actor reentrancy while waiting above permits another caller to install a flight first.
    if let existing = flightRegistry.flight(for: key) {
      return await waitForFlight(existing, key: key)
    }
    let flightID = flightRegistry.nextID()
    let task = Task<NativeEpisodeServerSaveOutcome, Never> { await operation() }
    let flight = FlightTask(id: flightID, task: task)
    flightRegistry.install(flight, for: key)
    return await waitForFlight(flight, key: key)
  }

  func waitForFlight(
    _ flight: FlightTask,
    key: NativeEpisodeServerSaveFlightKey
  ) async -> NativeEpisodeServerSaveOutcome {
    flight.addWaiter()
    let outcome = await withTaskCancellationHandler(
      operation: {
        await flight.task.value
      },
      onCancel: {
        flight.removeWaiterCancellingIfAbandoned()
      })
    flightRegistry.retire(flight, for: key)
    return outcome
  }
}
