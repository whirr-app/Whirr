import ABSApi
import Foundation
import Persistence

/// Outcome shaping for the removal pipeline: the durable checkpoints, the convergence-pending
/// fallback and the fenced presentation of every result.
extension NativeEpisodeServerSaveRemovalPipeline {
  func finishRemovalAfterResponse(
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    let observation = await observeRemoval(flight, on: coordinator)
    switch observation {
    case .absent, .itemGone:
      return await finishRemovalObservation(observation, flight: flight, on: coordinator)
    case .present:
      return await persistRemovalUncertain(
        flight: flight, attemptID: attemptID, category: .serverFailure, on: coordinator)
    case .inconclusive(let category):
      return await persistRemovalUncertain(
        flight: flight, attemptID: attemptID, category: category, on: coordinator)
    }
  }

  func finishRemovalObservation(
    _ observation: RemovalObservation,
    flight: NativeEpisodeServerSaveFlight,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    let media: PodcastMedia?
    switch observation {
    case .absent(let observed): media = observed
    case .itemGone: media = nil
    case .present, .inconclusive:
      return await presentRemoval(
        .uncertain(
          attemptID: flight.attempt.id ?? 0, state: flight.attempt.state, category: .unknown),
        flight: flight, on: coordinator)
    }
    guard let attemptID = flight.attempt.id else {
      return await presentRemoval(
        .uncertain(attemptID: 0, state: flight.attempt.state, category: .unknown),
        flight: flight, on: coordinator)
    }
    var currentFlight = flight
    do {
      if flight.attempt.state == .deleteFailed {
        let deleting = try await fencer.persistTransition(
          .deleting, flight: flight, attemptID: attemptID,
          itemID: flight.attempt.serverItemId, category: nil, scope: .account, on: coordinator)
        currentFlight = NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: deleting)
      }
      let finalState = try await persistRemoved(
        flight: currentFlight, attemptID: attemptID, media: media, on: coordinator)
      return await presentRemoval(
        .inProgress(
          attemptID: attemptID, state: finalState.state, serverItemID: finalState.serverItemId),
        flight: NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: finalState),
        on: coordinator)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID, state: currentFlight.attempt.state,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
        flight: currentFlight, on: coordinator)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      if NativeEpisodeServerSaveFencer.isAccountFenceError(error) {
        return await presentRemoval(
          .uncertain(
            attemptID: attemptID, state: currentFlight.attempt.state, category: .accountReplaced),
          flight: currentFlight, on: coordinator)
      }
      return await persistRemovalConvergencePending(
        flight: currentFlight, attemptID: attemptID, on: coordinator)
    } catch is PodcastRefreshStoreError {
      // A missing/cross-account/non-podcast local row means the local reconciliation cannot
      // commit; the transaction above already rolled back the `.removed` transition with it, so
      // the attempt stays nonterminal rather than falsely reporting removal. Persist the
      // convergence-pending checkpoint so a later retry cannot resend DELETE.
      return await persistRemovalConvergencePending(
        flight: currentFlight, attemptID: attemptID, on: coordinator)
    } catch {
      return await persistRemovalConvergencePending(
        flight: currentFlight, attemptID: attemptID, on: coordinator)
    }
  }

  /// Commits the `.removed` transition with the post-delete episode/count snapshot in one
  /// transaction, so a stale or incomplete local write cannot leave the attempt `.removed` while
  /// Save stays unavailable or the emptied show lingers in the catalogue.
  private func persistRemoved(
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    media: PodcastMedia?,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await fencer.fencedWrite(flight, scope: .account, on: coordinator) {
      guard let serverItemId = flight.attempt.serverItemId else {
        throw NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
      }
      let episodeRecords = media.map { media in
        PodcastRefreshStore.episodeRecords(
          from: media.episodes.map(PodcastRefreshCoordinator.mapEpisode),
          accountId: flight.attempt.accountId,
          itemId: 0)
      }
      return try await attemptStore.transitionToRemovedApplyingReconciliation(
        attemptId: attemptID, serverItemId: serverItemId, accountId: flight.attempt.accountId,
        episodes: episodeRecords, refreshedAt: Date())
    }
  }

  func persistRemovalUncertain(
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    category: NativeEpisodeServerSaveErrorCategory,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      let record = try await fencer.persistTransition(
        .deleteUncertain, flight: flight, attemptID: attemptID,
        itemID: flight.attempt.serverItemId, category: category, scope: .account,
        on: coordinator)
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID, state: record.state, category: record.errorCategory ?? category),
        flight: NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: record),
        on: coordinator)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID, state: .deleting,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
        flight: flight, on: coordinator)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID, state: .deleting,
          category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
            ? .accountReplaced : category),
        flight: flight, on: coordinator)
    } catch {
      return await presentRemoval(
        .uncertain(attemptID: attemptID, state: .deleting, category: category),
        flight: flight, on: coordinator)
    }
  }

  /// Records that the server absence is known but the local snapshot could not yet be committed.
  /// Nonterminal and durable: retrying reconciliation is safe, while a second DELETE would not
  /// be (the server-side mutation already happened).
  private func persistRemovalConvergencePending(
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    guard let serverItemID = flight.attempt.serverItemId else {
      return await presentRemoval(
        .uncertain(attemptID: attemptID, state: flight.attempt.state, category: .localPersistence),
        flight: flight, on: coordinator)
    }
    do {
      let record = try await attemptStore.markRemovalConvergencePendingAsync(
        attemptId: attemptID, serverItemId: serverItemID, accountId: flight.attempt.accountId,
        errorCategory: .localPersistence)
      return await presentRemoval(
        .uncertain(attemptID: attemptID, state: record.state, category: .localPersistence),
        flight: NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: record),
        on: coordinator)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID, state: flight.attempt.state,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
        flight: flight, on: coordinator)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return await presentRemoval(
        .uncertain(
          attemptID: attemptID,
          state: flight.attempt.state,
          category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
            ? .accountReplaced : .localPersistence),
        flight: flight, on: coordinator)
    } catch {
      return await presentRemoval(
        .uncertain(attemptID: attemptID, state: flight.attempt.state, category: .localPersistence),
        flight: flight, on: coordinator)
    }
  }

  func finishRemovalDefinitiveFailure(
    _ category: NativeEpisodeServerSaveErrorCategory,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      let record = try await fencer.persistTransition(
        .deleteFailed, flight: flight, attemptID: attemptID,
        itemID: flight.attempt.serverItemId, category: category, scope: .account,
        on: coordinator)
      return await presentRemoval(
        .failed(
          attemptID: attemptID, state: record.state, category: record.errorCategory ?? category),
        flight: NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: record),
        on: coordinator)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await presentRemoval(
        .failed(
          attemptID: attemptID, state: .deleting,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
        flight: flight, on: coordinator)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return await presentRemoval(
        .failed(
          attemptID: attemptID, state: .deleting,
          category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
            ? .accountReplaced : .localPersistence),
        flight: flight, on: coordinator)
    } catch {
      return await presentRemoval(
        .failed(attemptID: attemptID, state: .deleting, category: .localPersistence),
        flight: flight, on: coordinator)
    }
  }

  func finishRemovalBeforeSendFailure(
    _ category: NativeEpisodeServerSaveErrorCategory,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    await finishRemovalDefinitiveFailure(
      category, flight: flight, attemptID: attemptID, on: coordinator)
  }

  func removalUncertainOutcome(
    for attempt: NativeEpisodeServerSaveAttemptRecord,
    category: NativeEpisodeServerSaveErrorCategory
  ) -> NativeEpisodeServerSaveOutcome {
    if attempt.state == .deleteFailed {
      return .failed(attemptID: attempt.id!, state: attempt.state, category: category)
    }
    return .uncertain(attemptID: attempt.id!, state: attempt.state, category: category)
  }

  func removalFailure(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory
  ) -> NativeEpisodeServerSaveOutcome {
    .failed(attemptID: attemptID, state: state, category: category)
  }

  func presentRemoval(
    _ outcome: NativeEpisodeServerSaveOutcome,
    flight: NativeEpisodeServerSaveFlight,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      _ = try await fencer.verifyFence(flight, scope: .account, on: coordinator)
      return outcome
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .failed(
        attemptID: flight.attempt.id, state: outcome.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return .failed(attemptID: flight.attempt.id, state: outcome.state, category: .cancelled)
    } catch {
      return .failed(attemptID: flight.attempt.id, state: outcome.state, category: .localPersistence)
    }
  }

}
