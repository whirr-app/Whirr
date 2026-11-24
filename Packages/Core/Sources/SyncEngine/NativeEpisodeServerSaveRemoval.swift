import ABSApi
import Foundation
import Persistence

/// Deletion entry points. The destructive state machine lives in
/// `NativeEpisodeServerSaveRemovalPipeline`; these forward its three entry points and keep flight
/// serialization on the coordinator.
extension NativeEpisodeServerSaveCoordinator {
  /// Starts one explicit removal attempt. A delete-uncertain or delete-failed row is retried only
  /// by this user-invoked method, and only after a complete reconciliation observation.
  public func remove(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    await serializedAttempt(attemptID) { [self] in
      await removalPipeline.run(attemptID: attemptID, on: self)
    }
  }

  /// Shared bounded reconciliation entry for deletion states. It reports observation only; the
  /// removal command owns the legal state transition after that observation.
  func reconcileRemoval(attemptID: Int64) async -> NativeEpisodeServerSaveReconciliationOutcome {
    await removalPipeline.reconcile(attemptID: attemptID, on: self)
  }

  func recoverRemoval(
    attemptID: Int64,
    snapshot: NativeEpisodeServerSaveAttemptRecord
  ) async -> NativeEpisodeServerSaveOutcome {
    await removalPipeline.recover(attemptID: attemptID, snapshot: snapshot, on: self)
  }
}
