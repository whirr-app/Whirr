import ABSApi
import Foundation
import Persistence

/// The destructive half. Deletes target only the two opaque identities durably recorded on
/// confirmation; no server catalogue matching chooses a delete.
///
/// Every async member takes the coordinator as an `isolated` parameter, so removal runs on the
/// coordinator's executor and save and removal only interleave at `await`s, exactly as when these
/// methods were actor members. The type is a value with no mutable state. Through that
/// parameter it reaches only the coordinator's single item-detail read helper, which carries the
/// diagnostics every absence decision must use; everything else comes from the dependencies
/// stored here.
struct NativeEpisodeServerSaveRemovalPipeline: Sendable {
  let fencer: NativeEpisodeServerSaveFencer
  let attemptStore: any NativeEpisodeServerSaveAttemptStoring
  let capabilityReader: any ServerPodcastMutationCapabilityReading
  let podcastWriter: any NativeEpisodeServerSavePodcastWriting

  /// Shared bounded reconciliation entry for deletion states. It reports observation only; the
  /// removal command owns the legal state transition after that observation.
  func reconcile(
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveReconciliationOutcome {
    let state =
      (try? await attemptStore.fetchAttemptAsync(id: attemptID))??.state ?? .failed
    do {
      let flight = try await makeRemovalFlight(attemptID: attemptID, on: coordinator)
      switch await observeRemoval(flight, on: coordinator) {
      case .absent, .itemGone:
        return .absent(attemptID: attemptID, state: flight.attempt.state)
      case .present:
        return .inconclusive(
          attemptID: attemptID, state: flight.attempt.state, category: .serverFailure)
      case .inconclusive(let category):
        return .inconclusive(
          attemptID: attemptID, state: flight.attempt.state, category: category)
      }
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(
        attemptID: attemptID, state: state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .inconclusive(
        attemptID: attemptID, state: state,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
          ? .accountReplaced : .localPersistence)
    } catch is CancellationError {
      return .inconclusive(attemptID: attemptID, state: state, category: .cancelled)
    } catch {
      return .inconclusive(attemptID: attemptID, state: state, category: .transport)
    }
  }

  enum RemovalObservation: Sendable {
    /// Carries the validated complete episode list so `finishRemovalObservation` can reconcile
    /// the local episode/count snapshot atomically with the `.removed` transition.
    case absent(PodcastMedia)
    /// The server no longer has the podcast item at all, so it cannot contain the episode. There
    /// is no episode list to reconcile locally; the attempt still converges to `.removed`.
    case itemGone
    case present
    case inconclusive(NativeEpisodeServerSaveErrorCategory)
  }

  /// The removal phases, in order: load the durable flight, prove the row may be deleted, take
  /// the durable `.deleting` checkpoint with an account for the request, send the one DELETE, then
  /// observe the server to converge the result.
  func run(
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    let loaded = await loadRemovalFlight(attemptID: attemptID, on: coordinator)
    if let failure = loaded.failure { return failure }
    guard let flight = loaded.flight else {
      return removalFailure(attemptID: attemptID, state: .failed, category: .localPersistence)
    }

    guard
      let current = try? await fencer.verifyFence(flight, scope: .account, on: coordinator)
    else {
      return removalFailure(
        attemptID: attemptID, state: flight.attempt.state, category: .accountReplaced)
    }
    let currentFlight = NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: current)

    guard
      current.state == .confirmed || current.state == .deleting
        || current.state == .deleteUncertain || current.state == .deleteFailed
    else {
      return await presentRemoval(
        .failed(attemptID: attemptID, state: current.state, category: .invalidDestination),
        flight: currentFlight, on: coordinator)
    }

    guard current.preflightPresence == .absentBeforeRequest,
      let itemID = current.serverItemId, NativeEpisodeServerSaveSupport.usableServerIdentity(itemID),
      let episodeID = current.serverEpisodeId,
      NativeEpisodeServerSaveSupport.usableServerIdentity(episodeID)
    else {
      return await presentRemoval(
        .failed(attemptID: attemptID, state: current.state, category: .invalidDestination),
        flight: currentFlight, on: coordinator)
    }

    guard await capabilityReader.capability().canRemove else {
      return await presentRemoval(
        .failed(attemptID: attemptID, state: current.state, category: .permissionChanged),
        flight: currentFlight, on: coordinator)
    }

    if let failure = await observeRemovalBeforeDelete(
      currentFlight, attemptID: attemptID, on: coordinator)
    {
      return failure
    }

    let prepared = await markRemovalDeleting(
      currentFlight, attemptID: attemptID, on: coordinator)
    if let failure = prepared.failure { return failure }
    guard let account = prepared.account else {
      return await presentRemoval(
        .failed(
          attemptID: attemptID, state: prepared.flight.attempt.state, category: .accountReplaced),
        flight: prepared.flight, on: coordinator)
    }

    if let failure = await sendRemovalDelete(
      prepared.flight, account: account, itemID: itemID, episodeID: episodeID,
      attemptID: attemptID, on: coordinator)
    {
      return failure
    }

    // The endpoint returns no body. Reaching here means the server accepted the delete; the
    // complete-item observation below establishes server-wide record absence.
    return await finishRemovalAfterResponse(
      flight: prepared.flight, attemptID: attemptID, on: coordinator)
  }

  private func loadRemovalFlight(
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> (flight: NativeEpisodeServerSaveFlight?, failure: NativeEpisodeServerSaveOutcome?) {
    do {
      return (try await makeRemovalFlight(attemptID: attemptID, on: coordinator), nil)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return (
        nil,
        removalFailure(
          attemptID: attemptID, state: .confirmed,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
      )
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return (
        nil,
        removalFailure(
          attemptID: attemptID, state: .failed,
          category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
            ? .accountReplaced : .localPersistence)
      )
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      return (
        nil,
        removalFailure(
          attemptID: attemptID, state: .confirmed,
          category: NativeEpisodeServerSaveSupport.readerCategory(error))
      )
    } catch is CancellationError {
      return (
        nil, removalFailure(attemptID: attemptID, state: .confirmed, category: .cancelled)
      )
    } catch {
      return (
        nil, removalFailure(attemptID: attemptID, state: .confirmed, category: .localPersistence)
      )
    }
  }

  /// A row that is already past `.confirmed` is re-observed before the DELETE: a complete absence
  /// converges here, and an inconclusive read leaves the durable row for a later attempt. `nil`
  /// means the DELETE may be sent.
  private func observeRemovalBeforeDelete(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome? {
    guard flight.attempt.state != .confirmed else { return nil }
    let observation = await observeRemoval(flight, on: coordinator)
    switch observation {
    case .absent, .itemGone:
      return await finishRemovalObservation(observation, flight: flight, on: coordinator)
    case .inconclusive(let category):
      return await presentRemoval(
        removalUncertainOutcome(for: flight.attempt, category: category),
        flight: flight, on: coordinator)
    case .present:
      // Absence was already proven but the local transaction failed. Keep the
      // convergence-pending row durable; a later read of a stale/present item must not
      // trigger a second DELETE.
      if flight.attempt.state == .deleteUncertain, flight.attempt.errorCategory == .localPersistence {
        return await presentRemoval(
          .uncertain(
            attemptID: attemptID, state: flight.attempt.state, category: .localPersistence),
          flight: flight, on: coordinator)
      }
      return nil
    }
  }

  /// The durable pre-DELETE checkpoint and the account the DELETE is authorized with.
  private func markRemovalDeleting(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> (
    flight: NativeEpisodeServerSaveFlight, account: NativeEpisodeServerSaveAccount?,
    failure: NativeEpisodeServerSaveOutcome?
  ) {
    var preparedFlight = flight
    do {
      // The DELETE has not been sent yet, so the native toggle still gates it; only the
      // checkpoints after a send are account-scoped.
      let deleting = try await fencer.persistTransition(
        .deleting, flight: preparedFlight, attemptID: attemptID,
        itemID: preparedFlight.attempt.serverItemId, category: nil, scope: .subscription,
        on: coordinator)
      preparedFlight = NativeEpisodeServerSaveFlight(
        fence: preparedFlight.fence, command: preparedFlight.command, attempt: deleting)
      try Task.checkCancellation()
    } catch is CancellationError {
      return (
        preparedFlight, nil,
        await finishRemovalBeforeSendFailure(
          .cancelled, flight: preparedFlight, attemptID: attemptID, on: coordinator)
      )
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return (
        preparedFlight, nil,
        await presentRemoval(
          .failed(
            attemptID: attemptID, state: preparedFlight.attempt.state,
            category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
          flight: preparedFlight, on: coordinator)
      )
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return (
        preparedFlight, nil,
        await presentRemoval(
          .failed(
            attemptID: attemptID,
            state: preparedFlight.attempt.state,
            category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
              ? .accountReplaced : .localPersistence),
          flight: preparedFlight, on: coordinator)
      )
    } catch {
      return (
        preparedFlight, nil,
        await presentRemoval(
          .failed(
            attemptID: attemptID, state: preparedFlight.attempt.state, category: .localPersistence),
          flight: preparedFlight, on: coordinator)
      )
    }

    do {
      return (
        preparedFlight,
        try await fencer.verifiedAccount(
          preparedFlight, scope: .subscription, on: coordinator), nil
      )
    } catch is CancellationError {
      return (
        preparedFlight, nil,
        await finishRemovalBeforeSendFailure(
          .cancelled, flight: preparedFlight, attemptID: attemptID, on: coordinator)
      )
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return (
        preparedFlight, nil,
        await presentRemoval(
          .failed(
            attemptID: attemptID, state: .deleting,
            category: NativeEpisodeServerSaveFencer.fenceCategory(failure)),
          flight: preparedFlight, on: coordinator)
      )
    } catch {
      return (
        preparedFlight, nil,
        await presentRemoval(
          .failed(attemptID: attemptID, state: .deleting, category: .accountReplaced),
          flight: preparedFlight, on: coordinator)
      )
    }
  }

  /// One DELETE. `nil` means the server accepted it; every other path ends the removal here.
  private func sendRemovalDelete(
    _ flight: NativeEpisodeServerSaveFlight,
    account: NativeEpisodeServerSaveAccount,
    itemID: String,
    episodeID: String,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome? {
    var requestEntered = false
    do {
      try Task.checkCancellation()
      requestEntered = true
      try await podcastWriter.removePodcastEpisode(
        account: account.tokenAccount, itemID: itemID, episodeID: episodeID)
      return nil
    } catch is CancellationError {
      guard requestEntered else {
        return await finishRemovalBeforeSendFailure(
          .cancelled, flight: flight, attemptID: attemptID, on: coordinator)
      }
      return await persistRemovalUncertain(
        flight: flight, attemptID: attemptID, category: .cancelled, on: coordinator)
    } catch let error as APIError {
      switch error {
      case .badRequest, .unexpectedStatus(400):
        return await finishRemovalDefinitiveFailure(
          .invalidDestination, flight: flight, attemptID: attemptID, on: coordinator)
      case .forbidden, .unexpectedStatus(403):
        return await finishRemovalDefinitiveFailure(
          .permissionChanged, flight: flight, attemptID: attemptID, on: coordinator)
      case .notFound, .unexpectedStatus(404):
        return await finishRemovalAfterResponse(
          flight: flight, attemptID: attemptID, on: coordinator)
      case .decoding:
        return await persistRemovalUncertain(
          flight: flight, attemptID: attemptID, category: .malformedResponse, on: coordinator)
      case .serverFailure:
        return await persistRemovalUncertain(
          flight: flight, attemptID: attemptID, category: .serverFailure, on: coordinator)
      case .transport:
        return await persistRemovalUncertain(
          flight: flight, attemptID: attemptID, category: .transport, on: coordinator)
      default:
        return await persistRemovalUncertain(
          flight: flight,
          attemptID: attemptID,
          category: NativeEpisodeServerSaveSupport.apiCategory(error),
          on: coordinator)
      }
    } catch {
      return await persistRemovalUncertain(
        flight: flight, attemptID: attemptID, category: .unknown, on: coordinator)
    }
  }

  private func makeRemovalFlight(
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveFlight {
    try await fencer.rebuildFlight(
      attemptID: attemptID, command: .durableIdentity, scope: .account, on: coordinator)
  }

  func observeRemoval(
    _ flight: NativeEpisodeServerSaveFlight,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> RemovalObservation {
    guard let itemID = flight.attempt.serverItemId,
      let episodeID = flight.attempt.serverEpisodeId,
      NativeEpisodeServerSaveSupport.usableServerIdentity(itemID),
      NativeEpisodeServerSaveSupport.usableServerIdentity(episodeID)
    else { return .inconclusive(.invalidDestination) }

    let account: NativeEpisodeServerSaveAccount
    do {
      account = try await fencer.verifiedAccount(flight, scope: .account, on: coordinator)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return .inconclusive(.cancelled)
    } catch {
      return .inconclusive(.accountReplaced)
    }

    let read: NativeEpisodeServerSaveCoordinator.ItemDetailRead
    do {
      read = try await coordinator.readItemDetail(
        account: account.tokenAccount, itemID: itemID)
    } catch let error as APIError {
      // A missing item is a definite answer, not an ambiguous read: the recorded (item, episode)
      // identity cannot exist under an item the server does not have. Treating it as
      // inconclusive would leave a delete-uncertain row with no exit.
      if Self.isItemNotFound(error) {
        guard (try? await fencer.verifyFence(flight, scope: .account, on: coordinator)) != nil else {
          return .inconclusive(.accountReplaced)
        }
        return .itemGone
      }
      return .inconclusive(NativeEpisodeServerSaveSupport.apiCategory(error))
    } catch is CancellationError {
      return .inconclusive(.cancelled)
    } catch {
      return .inconclusive(.transport)
    }

    let detail = read.detail
    guard detail.id == itemID, detail.mediaType == ItemMediaCategory.podcast.rawValue,
      case .podcast(let media)? = detail.media,
      media.episodeListProvesAbsence(detailDiagnostics: read.diagnostics)
    else { return .inconclusive(.incompleteEpisodeList) }

    guard (try? await fencer.verifyFence(flight, scope: .account, on: coordinator)) != nil else {
      return .inconclusive(.accountReplaced)
    }
    return media.episodes.contains(where: { $0.id == episodeID }) ? .present : .absent(media)
  }

  private static func isItemNotFound(_ error: APIError) -> Bool {
    switch error {
    case .notFound: return true
    case .unexpectedStatus(let statusCode): return statusCode == 404
    default: return false
    }
  }

  /// Relaunch recovery observes a deleting row but never sends a request. An explicit `remove`
  /// call is required to retry when a complete observation still finds the episode present.
  func recover(
    attemptID: Int64,
    snapshot: NativeEpisodeServerSaveAttemptRecord,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      let flight = try await makeRemovalFlight(attemptID: attemptID, on: coordinator)
      let observation = await observeRemoval(flight, on: coordinator)
      switch observation {
      case .absent, .itemGone:
        return await finishRemovalObservation(observation, flight: flight, on: coordinator)
      case .present:
        if snapshot.state == .deleting {
          return await persistRemovalUncertain(
            flight: flight, attemptID: attemptID, category: .serverFailure, on: coordinator)
        }
        return await presentRemoval(
          removalUncertainOutcome(for: snapshot, category: snapshot.errorCategory ?? .unknown),
          flight: flight, on: coordinator)
      case .inconclusive(let category):
        if snapshot.state == .deleting {
          return await persistRemovalUncertain(
            flight: flight, attemptID: attemptID, category: category, on: coordinator)
        }
        return await presentRemoval(
          removalUncertainOutcome(for: snapshot, category: category), flight: flight,
          on: coordinator)
      }
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .uncertain(
        attemptID: attemptID, state: snapshot.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .uncertain(
        attemptID: attemptID, state: snapshot.state,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error)
          ? .accountReplaced : .localPersistence)
    } catch is CancellationError {
      return .uncertain(attemptID: attemptID, state: snapshot.state, category: .cancelled)
    } catch {
      return .uncertain(attemptID: attemptID, state: snapshot.state, category: .transport)
    }
  }
}
