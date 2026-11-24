import ABSApi
import Foundation
import Persistence

/// Sends a `progressReset` operation's currently-persisted phase, one network step at a time,
/// persisting the next phase before it is attempted so a crash or retry resumes rather than
/// repeats a step that already landed.
extension OutboxDrainer {
  /// One attempt at whichever phase the operation is currently in. The phase is read fresh from
  /// the record on every call, never cached, so a resumed row (after a crash, a backoff wait, or a
  /// fresh `OutboxDrainer` instance) continues from what was last durably persisted.
  func sendProgressReset(
    _ operation: OutboxOperationRecord
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let operationId = operation.id else { return .decodeAmbiguous }
    guard let medium = operation.progressResetMedium else {
      // A `progressReset` row with no recorded medium cannot be sent to either leg, and a retry
      // cannot supply one. The payload is wrong.
      return .localReferenceGone(reason: "progressResetMediumMissing")
    }
    let episodeServerID: String?
    switch resolveProgressScope(operation) {
    case .resolved(let resolvedEpisodeServerID, _):
      episodeServerID = resolvedEpisodeServerID
    case .decodeAmbiguous:
      return .decodeAmbiguous
    case .localReferenceGone:
      return .localReferenceGone(reason: "episodeRowMissing")
    }

    switch operation.progressResetPhase {
    case .resolve:
      return await sendProgressResetResolve(
        operationId: operationId, medium: medium, libraryItemID: operation.entityKey,
        episodeServerID: episodeServerID)
    case .delete:
      return await sendProgressResetDelete(
        operationId: operationId, medium: medium, capture: operation.progressResetCapture,
        knownRow: nil, libraryItemID: operation.entityKey, episodeServerID: episodeServerID)
    case .restore:
      return await sendProgressResetRestore(
        medium: medium, capture: operation.progressResetCapture, libraryItemID: operation.entityKey,
        episodeServerID: episodeServerID)
    }
  }

  /// Resolve: `GET` the row. A 404 means there is nothing to reset, so it is an ordinary success
  /// with no capture and no `DELETE`. Otherwise capture the server's current value of the medium
  /// that must survive, from this same response, before anything is deleted: a stale device's local
  /// row must never be the source of a value that could regress a newer write another device made
  /// to the other medium.
  private func sendProgressResetResolve(
    operationId: Int64, medium: ProgressResetMedium, libraryItemID: String, episodeServerID: String?
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    switch await fetchProgressResetRow(libraryItemID: libraryItemID, episodeServerID: episodeServerID) {
    case .failure(let outcome):
      return outcome
    case .success(nil):
      return .ordinarySuccess
    case .success(let row?):
      let capture = Self.capture(forMedium: medium, from: row)
      do {
        try await outboxStore.recordProgressResetCaptureAsync(operationId: operationId, capture: capture)
      } catch {
        // The store could not durably record the capture. Retry the whole attempt rather than
        // `DELETE` on the strength of a capture that never persisted.
        return .apiFailure(.transport)
      }
      return await sendProgressResetDelete(
        operationId: operationId, medium: medium, capture: capture, knownRow: row,
        libraryItemID: libraryItemID, episodeServerID: episodeServerID)
    }
  }

  /// Delete: delete the row this device observed, then re-`GET` to confirm nothing is left. The
  /// server can return duplicate rows for one identity, and a replay after a crash must re-run
  /// this loop from whatever the store last persisted. `alreadyGone` (a 404 on the `DELETE`) counts
  /// as done, like an empty follow-up `GET`, so a lost acknowledgement never re-deletes. Bounded
  /// at three `DELETE`s (`knownRow` from the resolve step counts as the first); a row surviving
  /// that is treated as gone for good (`localReferenceGone`), not retained forever.
  private func sendProgressResetDelete(
    operationId: Int64, medium: ProgressResetMedium, capture: ProgressResetCapture,
    knownRow: MediaProgress?, libraryItemID: String, episodeServerID: String?
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    var row = knownRow
    if row == nil {
      switch await fetchProgressResetRow(libraryItemID: libraryItemID, episodeServerID: episodeServerID) {
      case .failure(let outcome): return outcome
      case .success(let fetched): row = fetched
      }
    }

    var deleteCount = 0
    while let currentRow = row {
      guard let progressID = currentRow.serverProgressID, progressID.isEmpty == false else {
        return .localReferenceGone(reason: "progressResetMissingRowId")
      }
      guard deleteCount < 3 else {
        return .localReferenceGone(reason: "progressResetRowPersists")
      }
      do {
        _ = try await absClient.deleteMediaProgress(account: account, progressID: progressID)
      } catch is CancellationError {
        return .cancelled
      } catch let apiError as APIError {
        return .apiFailure(apiError)
      } catch {
        return .apiFailure(.transport)
      }
      deleteCount += 1
      switch await fetchProgressResetRow(libraryItemID: libraryItemID, episodeServerID: episodeServerID) {
      case .failure(let outcome): return outcome
      case .success(let fetched): row = fetched
      }
    }

    do {
      try await outboxStore.advanceProgressResetToRestoreAsync(operationId: operationId)
    } catch {
      // Not yet durable: the next attempt re-enters at `.delete` and repeats only the idempotent
      // confirming `GET`, never a further `DELETE`.
      return .apiFailure(.transport)
    }
    return await sendProgressResetRestore(
      medium: medium, capture: capture, libraryItemID: libraryItemID, episodeServerID: episodeServerID)
  }

  /// Restore: restores the captured medium only if it was non-trivial. A mixed-format item's other
  /// medium must reappear at the server's value, but an untouched-medium reset must not recreate a
  /// row at 0/empty just to carry it. The PATCH is field-scoped to the captured fields: never `id`,
  /// never the reset medium's own fields, and never `isFinished` (the deleted row's finish flag was
  /// already cleared locally and the restored row is new and defaults unfinished).
  private func sendProgressResetRestore(
    medium: ProgressResetMedium, capture: ProgressResetCapture, libraryItemID: String,
    episodeServerID: String?
  ) async -> OutboxAcknowledgementPolicy.AttemptOutcome {
    guard let update = Self.restoreUpdate(medium: medium, capture: capture) else {
      return .ordinarySuccess
    }
    do {
      try await absClient.updateProgress(
        account: account, libraryItemID: libraryItemID, episodeID: episodeServerID, update: update)
      return .ordinarySuccess
    } catch is CancellationError {
      return .cancelled
    } catch let apiError as APIError {
      return .apiFailure(apiError)
    } catch {
      return .apiFailure(.transport)
    }
  }

  private enum ProgressRowFetch {
    case success(MediaProgress?)
    case failure(OutboxAcknowledgementPolicy.AttemptOutcome)
  }

  private func fetchProgressResetRow(
    libraryItemID: String, episodeServerID: String?
  ) async -> ProgressRowFetch {
    do {
      let row = try await absClient.fetchMediaProgress(
        account: account, libraryItemID: libraryItemID, episodeID: episodeServerID)
      return .success(row)
    } catch is CancellationError {
      return .failure(.cancelled)
    } catch let apiError as APIError {
      return .failure(.apiFailure(apiError))
    } catch {
      return .failure(.apiFailure(.transport))
    }
  }

  /// The server's value of the medium a reset must not disturb, read from the row this device's
  /// `GET` just observed, never from the local row.
  private static func capture(forMedium medium: ProgressResetMedium, from row: MediaProgress) -> ProgressResetCapture {
    switch medium {
    case .audio:
      return ProgressResetCapture(ebookProgress: row.ebookProgress, ebookLocation: row.ebookLocation)
    case .ebook:
      return ProgressResetCapture(currentTime: row.currentTime, progress: row.progress)
    }
  }

  /// `nil` when the captured medium was trivial (0 / empty), so no restore PATCH is sent at all.
  private static func restoreUpdate(medium: ProgressResetMedium, capture: ProgressResetCapture) -> ProgressUpdate? {
    switch medium {
    case .audio:
      let hasLocation = capture.ebookLocation?.isEmpty == false
      guard (capture.ebookProgress ?? 0) > 0 || hasLocation else { return nil }
      return ProgressUpdate(ebookProgress: capture.ebookProgress, ebookLocation: capture.ebookLocation)
    case .ebook:
      guard let currentTime = capture.currentTime, currentTime > 0 else { return nil }
      return ProgressUpdate(currentTime: currentTime, progress: capture.progress)
    }
  }
}
