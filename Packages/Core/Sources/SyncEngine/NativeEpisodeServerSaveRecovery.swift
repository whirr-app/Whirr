import ABSApi
import Foundation
import Persistence

/// Crash-safe recovery for the two save states whose network result is not known locally. Every
/// method in this file is an explicit caller entry point; none schedules another send.
extension NativeEpisodeServerSaveCoordinator {
  /// The shared front door of `recover`, `retry` and `remove`: the stored row names the feed and
  /// episode the flight is serialized on, and a row that cannot be read fails locally without
  /// starting one.
  func serializedAttempt(
    _ attemptID: Int64,
    _ operation: @escaping @Sendable () async -> NativeEpisodeServerSaveOutcome
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      guard let attempt = try await attemptStore.fetchAttemptAsync(id: attemptID) else {
        return .failed(attemptID: attemptID, state: .failed, category: .localPersistence)
      }
      return await startSerializedFlight(
        key: NativeEpisodeServerSaveFlightKey(feedID: attempt.feedId, episodeID: attempt.episodeId),
        operation: operation)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .failed(
        attemptID: attemptID,
        state: .failed,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence)
    } catch {
      return .failed(attemptID: attemptID, state: .failed, category: .localPersistence)
    }
  }

  /// Rebuilds a save flight from its durable attempt row. A `createUncertain` row is resolved by
  /// feed URL before the existing enqueue path is resumed. An `uncertain` row receives one bounded
  /// reconciliation pass, but is never retried by recovery itself.
  public func recover(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    await serializedAttempt(attemptID) { [self] in await runRecovery(attemptID: attemptID) }
  }

  /// Performs one explicit, user-initiated retry. The reconciler must return complete-list
  /// absence in this same call before the durable `.uncertain -> .preparing` edge is crossed.
  public func retry(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    await serializedAttempt(attemptID) { [self] in await runExplicitRetry(attemptID: attemptID) }
  }

  private func runRecovery(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    do {
      guard let snapshot = try await attemptStore.fetchAttemptAsync(id: attemptID) else {
        return .failed(attemptID: attemptID, state: .failed, category: .localPersistence)
      }
      return await runRecovery(snapshot: snapshot, attemptID: attemptID)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .failed(
        attemptID: attemptID,
        state: .failed,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence)
    } catch {
      return .failed(attemptID: attemptID, state: .failed, category: .localPersistence)
    }
  }

  private func runRecovery(
    snapshot: NativeEpisodeServerSaveAttemptRecord,
    attemptID: Int64
  ) async -> NativeEpisodeServerSaveOutcome {
    switch snapshot.state {
    case .createUncertain:
      return await recoverUncertainCreate(attemptID: attemptID, state: snapshot)
    case .uncertain:
      return await recoverUncertainEnqueue(attemptID: attemptID, state: snapshot)
    case .deleting, .deleteUncertain, .deleteFailed:
      return await recoverRemoval(attemptID: attemptID, snapshot: snapshot)
    case .creatingShow, .requestingDownload:
      return await recoverInterruptedSend(attemptID: attemptID, snapshot: snapshot)
    case .accepted:
      return await recoverAccepted(attemptID: attemptID, snapshot: snapshot)
    default:
      do {
        let flight = try await makeRecoveryFlight(attemptID: attemptID)
        return await present(
          .inProgress(
            attemptID: attemptID,
            state: snapshot.state,
            serverItemID: snapshot.serverItemId),
          flight: flight,
          sentPhase: nil)
      } catch {
        return fallbackForRecoveryFailure(
          attemptID: attemptID, state: snapshot.state, category: category(for: error))
      }
    }
  }

  /// A row still in a sending state means the process ended after the request began and before
  /// its answer was recorded. That is the same ambiguity a lost response leaves, so checkpoint it
  /// as such under the account fence and let the ordinary uncertain path resolve it.
  private func recoverInterruptedSend(
    attemptID: Int64,
    snapshot: NativeEpisodeServerSaveAttemptRecord
  ) async -> NativeEpisodeServerSaveOutcome {
    let flight: NativeEpisodeServerSaveFlight
    do {
      flight = try await makeRecoveryFlight(attemptID: attemptID)
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: snapshot.state, category: category(for: error))
    }
    let uncertainState: NativeEpisodeServerSaveAttemptState =
      snapshot.state == .creatingShow ? .createUncertain : .uncertain
    let checkpoint: NativeEpisodeServerSaveAttemptRecord
    do {
      try await fencer.persistTransition(
        uncertainState,
        flight: flight,
        attemptID: attemptID,
        itemID: snapshot.serverItemId,
        category: .unknown,
        scope: .account,
        on: self)
      guard let current = try await attemptStore.fetchAttemptAsync(id: attemptID) else {
        throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptID)
      }
      checkpoint = current
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: snapshot.state, category: category(for: error))
    }
    return await runRecovery(snapshot: checkpoint, attemptID: attemptID)
  }

  /// An accepted row is reconciled and never retried: absence from a complete list only means
  /// the queued download has not landed yet.
  private func recoverAccepted(
    attemptID: Int64,
    snapshot: NativeEpisodeServerSaveAttemptRecord
  ) async -> NativeEpisodeServerSaveOutcome {
    let flight: NativeEpisodeServerSaveFlight
    do {
      flight = try await makeRecoveryFlight(attemptID: attemptID)
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: snapshot.state, category: category(for: error))
    }
    let result = await reconcile(attemptID: attemptID)
    let state: NativeEpisodeServerSaveAttemptState
    if case .confirmed = result {
      state = .confirmed
    } else {
      state = .accepted
    }
    return await present(
      .inProgress(attemptID: attemptID, state: state, serverItemID: snapshot.serverItemId),
      flight: flight,
      sentPhase: nil)
  }

  private func recoverUncertainCreate(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptRecord
  ) async -> NativeEpisodeServerSaveOutcome {
    let flight: NativeEpisodeServerSaveFlight
    do {
      flight = try await makeRecoveryFlight(attemptID: attemptID)
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: state.state, category: category(for: error))
    }

    let resolution: NativeEpisodeServerSaveDestinationResolution
    do {
      let account = try await fencer.verifiedAccount(flight, scope: .source, on: self)
      resolution = try await destinationResolver.resolveNativeEpisodeServerSaveDestination(
        feedURL: flight.command.feedURL,
        nativeFeedTitle: flight.command.feedTitle,
        account: account.tokenAccount,
        choice: nil)
    } catch {
      return await presentUnchanged(
        flight, category: category(for: error), state: .createUncertain)
    }

    switch resolution {
    case .reuse(let itemID):
      guard NativeEpisodeServerSaveSupport.usableServerIdentity(itemID) else {
        return await presentUnchanged(
          flight, category: .malformedResponse, state: .createUncertain)
      }
      do {
        try await fencer.persistServerItemID(itemID, flight: flight, attemptID: attemptID, on: self)
        let current = try await fencer.verifyFence(flight, scope: .source, on: self)
        let resumedFlight = NativeEpisodeServerSaveFlight(
          fence: flight.fence, command: flight.command, attempt: current)
        // The create path recorded absence before sending. Keep that provenance while resuming
        // the normal detail check and exactly-one-enqueue path; never issue another create.
        return await preflightAndMaybeEnqueue(
          itemID,
          flight: resumedFlight,
          attemptID: attemptID,
          createWasSent: false,
          knownPresence: .absentBeforeRequest)
      } catch {
        return await presentUnchanged(
          flight, category: category(for: error), state: .createUncertain)
      }

    case .needsChoice, .create, .noAccessiblePodcastLibraries:
      // A complete resolver pass found no existing show. The ambiguous create therefore did not
      // land, so only the legal recovery edge back to preparing may be crossed.
      do {
        try await fencer.persistTransition(
          .preparing, flight: flight, attemptID: attemptID, itemID: nil, category: nil,
          on: self)
        let current = try await fencer.verifyFence(flight, scope: .source, on: self)
        return await present(
          .inProgress(attemptID: attemptID, state: .preparing, serverItemID: current.serverItemId),
          flight: NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: current),
          sentPhase: nil)
      } catch {
        return await presentUnchanged(
          flight, category: category(for: error), state: .createUncertain)
      }
    }
  }

  private func recoverUncertainEnqueue(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptRecord
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      let flight = try await makeRecoveryFlight(attemptID: attemptID)
      let result = await reconcile(attemptID: attemptID)
      switch result {
      case .confirmed:
        return await present(
          .inProgress(
            attemptID: attemptID, state: .confirmed, serverItemID: state.serverItemId),
          flight: flight,
          sentPhase: nil)
      case .absent:
        return await presentUnchanged(
          flight,
          category: state.errorCategory ?? .unknown,
          state: .uncertain)
      case .inconclusive(_, _, let category):
        return await presentUnchanged(flight, category: category, state: .uncertain)
      }
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: state.state, category: category(for: error))
    }
  }

  private func runExplicitRetry(attemptID: Int64) async -> NativeEpisodeServerSaveOutcome {
    let flight: NativeEpisodeServerSaveFlight
    do {
      flight = try await makeRecoveryFlight(attemptID: attemptID)
    } catch {
      let state = (try? await attemptStore.fetchAttemptAsync(id: attemptID))??.state ?? .failed
      return fallbackForRecoveryFailure(
        attemptID: attemptID, state: state, category: category(for: error))
    }

    guard flight.attempt.state == .uncertain else {
      return await presentUnchanged(
        flight, category: .unknown, state: flight.attempt.state)
    }

    let result = await reconcile(attemptID: attemptID)
    guard case .absent = result else {
      switch result {
      case .confirmed:
        return await present(
          .inProgress(
            attemptID: attemptID,
            state: .confirmed,
            serverItemID: flight.attempt.serverItemId),
          flight: flight,
          sentPhase: nil)
      case .absent:
        break
      case .inconclusive(_, _, let category):
        return await presentUnchanged(flight, category: category, state: .uncertain)
      }
      return await presentUnchanged(flight, category: .unknown, state: .uncertain)
    }

    do {
      // This is the sole authorization checkpoint for the explicit retry. It is a separate
      // durable edge, and the refreshed NativeEpisodeServerSaveFlight prevents continueSave from seeing the old
      // `.uncertain` snapshot after the transition.
      try await fencer.persistTransition(
        .preparing, flight: flight, attemptID: attemptID, itemID: nil, category: nil,
        on: self)
      let current = try await fencer.verifyFence(flight, scope: .source, on: self)
      let preparedFlight = NativeEpisodeServerSaveFlight(fence: flight.fence, command: flight.command, attempt: current)
      return await continueSave(preparedFlight, attemptID: attemptID, choice: nil)
    } catch {
      return await presentUnchanged(
        flight, category: category(for: error), state: .uncertain)
    }
  }

  private func makeRecoveryFlight(attemptID: Int64) async throws -> NativeEpisodeServerSaveFlight {
    try await fencer.rebuildFlight(attemptID: attemptID, command: .live, scope: .source, on: self)
  }

  private func presentUnchanged(
    _ flight: NativeEpisodeServerSaveFlight,
    category: NativeEpisodeServerSaveErrorCategory,
    state: NativeEpisodeServerSaveAttemptState
  ) async -> NativeEpisodeServerSaveOutcome {
    let fallback: NativeEpisodeServerSaveOutcome
    switch state {
    case .createUncertain, .uncertain:
      fallback = .uncertain(attemptID: flight.attempt.id!, state: state, category: category)
    default:
      fallback = .inProgress(
        attemptID: flight.attempt.id!, state: state, serverItemID: flight.attempt.serverItemId)
    }
    return await presentRecoveryFallback(fallback, flight: flight)
  }

  /// `present` prefers the durable category when presenting an ordinary save. A
  /// recovery observation also has a fresh, more useful sanitized category (for example an
  /// incomplete list), so retain that value while still fencing the returned presentation.
  private func presentRecoveryFallback(
    _ fallback: NativeEpisodeServerSaveOutcome,
    flight: NativeEpisodeServerSaveFlight
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      _ = try await fencer.verifyFence(flight, scope: .source, on: self)
      return fallback
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return fallbackForRecoveryFailure(
        attemptID: flight.attempt.id!, state: fallback.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return fallbackForRecoveryFailure(
        attemptID: flight.attempt.id!, state: fallback.state, category: .cancelled)
    } catch {
      return fallbackForRecoveryFailure(
        attemptID: flight.attempt.id!, state: fallback.state, category: .localPersistence)
    }
  }

  private func fallbackForRecoveryFailure(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory
  ) -> NativeEpisodeServerSaveOutcome {
    switch state {
    case .createUncertain, .uncertain:
      return .uncertain(attemptID: attemptID, state: state, category: category)
    default:
      return .failed(attemptID: attemptID, state: state, category: category)
    }
  }

  private func category(for error: Error) -> NativeEpisodeServerSaveErrorCategory {
    if let error = error as? NativeEpisodeServerSaveFenceFailure {
      return NativeEpisodeServerSaveFencer.fenceCategory(error)
    }
    if let error = error as? APIError { return NativeEpisodeServerSaveSupport.apiCategory(error) }
    if let error = error as? ServerPodcastDestinationResolverError {
      return NativeEpisodeServerSaveSupport.resolverCategory(error)
    }
    if let error = error as? NativeEpisodeServerSaveCommandReaderError {
      return NativeEpisodeServerSaveSupport.readerCategory(error)
    }
    if let error = error as? NativeEpisodeServerSaveAttemptStoreError {
      return NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence
    }
    if error is CancellationError { return .cancelled }
    return .localPersistence
  }
}

extension NativeEpisodeServerSaveCoordinator: NativeEpisodeServerSaveRecovering {
  /// Every state whose next step is observation or a checkpoint rather than a fresh user action.
  public static let recoverableStates: Set<NativeEpisodeServerSaveAttemptState> = [
    .creatingShow, .requestingDownload, .accepted, .createUncertain, .uncertain,
    .deleting, .deleteUncertain, .deleteFailed,
  ]

  @discardableResult
  public func recoverPendingAttempts(feedId: Int64?) async -> [Int64] {
    guard let account = try? await accountReader.currentAccount(),
      let attempts = try? await attemptStore.fetchAttemptsAsync(
        accountId: account.accountID, states: Self.recoverableStates)
    else { return [] }
    var visited: [Int64] = []
    for attempt in attempts where feedId == nil || attempt.feedId == feedId {
      guard Task.isCancelled == false, let id = attempt.id else { break }
      _ = await recover(attemptID: id)
      visited.append(id)
    }
    return visited
  }
}
