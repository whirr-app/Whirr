import SyncEngine

/// Decides whether one status snapshot may replace an episode's server-save presentation. The show
/// keeps one per episode and the card keeps one, so both filter stale snapshots by the same rule.
///
/// A snapshot is stale when older than what the presentation shows, in attempt-ID order (a new
/// attempt has a strictly newer durable ID). The projection picks the current attempt by
/// `updatedAt` first, so an older attempt updated late can become current there; the fence still
/// rejects it, so a superseded attempt's late transition never replaces the fresh one.
struct NativeEpisodeServerSaveAttemptFence: Sendable, Equatable {
  /// The highest attempt ID seen from an accepted snapshot or an outcome. Only a fresh fence lowers
  /// it: a dismissal or a `nil` ID leaves it where it is.
  private(set) var latestAttemptID: Int64?
  /// The removed attempt a queued pre-removal snapshot must not replace. A strictly newer attempt
  /// clears it.
  private(set) var removedAttemptID: Int64?
  /// While a save or remove awaits its durable result, that result owns the presentation; a
  /// buffered snapshot would overwrite the local preparing or removing state.
  private(set) var isMutationInFlight = false

  mutating func accept(_ snapshot: NativeEpisodeServerSaveStatusSnapshot) -> Bool {
    guard admits(snapshot) else { return false }
    advanceLatest(to: snapshot.attemptID)
    if snapshot.status == .removed, let attemptID = snapshot.attemptID {
      removedAttemptID = attemptID
    }
    return true
  }

  /// A single save passes `true`. A remove, and a batch save, leave the removal fence for the first
  /// strictly newer snapshot to clear; while new attempt IDs only grow, that is the same result.
  mutating func beginMutation(clearingRemoval: Bool) {
    isMutationInFlight = true
    if clearingRemoval { removedAttemptID = nil }
  }

  mutating func endMutation() {
    isMutationInFlight = false
  }

  mutating func record(_ outcome: NativeEpisodeServerSaveOutcome) {
    advanceLatest(to: outcome.attemptID)
    if case .inProgress(let attemptID, .removed, _) = outcome {
      removedAttemptID = attemptID
    }
  }

  private mutating func admits(_ snapshot: NativeEpisodeServerSaveStatusSnapshot) -> Bool {
    if isMutationInFlight { return false }
    if let latestAttemptID, let incoming = snapshot.attemptID, incoming < latestAttemptID {
      return false
    }
    guard let removedAttemptID else { return true }
    if snapshot.status == .removed {
      if let incoming = snapshot.attemptID, incoming < removedAttemptID { return false }
      return true
    }
    guard let incoming = snapshot.attemptID, incoming > removedAttemptID else { return false }
    self.removedAttemptID = nil
    return true
  }

  private mutating func advanceLatest(to attemptID: Int64?) {
    guard let attemptID else { return }
    if let latestAttemptID, attemptID <= latestAttemptID { return }
    latestAttemptID = attemptID
  }
}
