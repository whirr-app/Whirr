import ABSApi
import Foundation
import Persistence

/// The save state machine: everything after a flight is admitted, from the attempt checkpoint to
/// the accepted result and its foreground convergence.
extension NativeEpisodeServerSaveCoordinator {
  func runSave(
    feedId: Int64,
    episodeId: Int64,
    choice: ServerPodcastSaveChoice?,
    convergence: NativeEpisodeServerSaveConvergencePolicy,
    knownShow: NativeEpisodeServerSaveKnownShow? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    guard await capabilityReader.capability().canSave else {
      return .failed(attemptID: nil, state: .failed, category: .permissionChanged)
    }
    guard Task.isCancelled == false else {
      return .failed(attemptID: nil, state: .failed, category: .cancelled)
    }

    let account: NativeEpisodeServerSaveAccount
    do {
      account = try await accountReader.currentAccount()
    } catch let error as NativeEpisodeServerSaveAccountReadingError {
      return .failed(
        attemptID: nil, state: .failed,
        category: NativeEpisodeServerSaveSupport.accountCategory(error))
    } catch {
      return .failed(attemptID: nil, state: .failed, category: .unknown)
    }

    let command: NativeEpisodeServerSaveCommand
    do {
      try Task.checkCancellation()
      command = try await commandReader.read(feedId: feedId, episodeId: episodeId)
    } catch is CancellationError {
      return .failed(attemptID: nil, state: .failed, category: .cancelled)
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      return .failed(
        attemptID: nil, state: .failed,
        category: NativeEpisodeServerSaveSupport.readerCategory(error))
    } catch {
      return .failed(attemptID: nil, state: .failed, category: .unknown)
    }

    do {
      try Task.checkCancellation()
      guard await fencer.accountStillMatches(account, on: self) else {
        return .failed(attemptID: nil, state: .failed, category: .accountReplaced)
      }
      let attempt = try await attemptStore.beginAttemptAsync(
        accountId: account.accountID, feedId: feedId, episodeId: episodeId,
        episodeIdentityKey: command.episodeIdentityKey)
      let fence = NativeEpisodeServerSaveAccountFence(account: account)
      guard NativeEpisodeServerSaveFencer.matchesFence(attempt, fence: fence), let attemptID = attempt.id else {
        return .failed(attemptID: attempt.id, state: .failed, category: .accountReplaced)
      }
      return await continueSave(
        NativeEpisodeServerSaveFlight(fence: fence, command: command, attempt: attempt),
        attemptID: attemptID,
        choice: choice,
        convergence: convergence,
        knownShow: knownShow)
    } catch is CancellationError {
      return .failed(attemptID: nil, state: .failed, category: .cancelled)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .failed(
        attemptID: nil,
        state: .failed,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence)
    } catch {
      return .failed(attemptID: nil, state: .failed, category: .localPersistence)
    }
  }

  func continueSave(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    choice: ServerPodcastSaveChoice?,
    convergence: NativeEpisodeServerSaveConvergencePolicy = .foreground,
    knownShow: NativeEpisodeServerSaveKnownShow? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    if let settled = await presentSettledFlight(flight, attemptID: attemptID) { return settled }

    // The batch already resolved and used this show for an earlier episode. Re-running the
    // resolver would list every podcast library again to arrive at the same id.
    if let knownShow {
      return await prepareKnownShow(
        knownShow.itemID,
        flight: flight,
        attemptID: attemptID,
        convergence: convergence,
        sharedDetail: knownShow.detail)
    }

    let resolution: NativeEpisodeServerSaveDestinationResolution
    do {
      try Task.checkCancellation()
      let account = try await fencer.verifiedAccount(flight, scope: .source, on: self)
      resolution = try await destinationResolver.resolveNativeEpisodeServerSaveDestination(
        feedURL: flight.command.feedURL,
        nativeFeedTitle: flight.command.feedTitle,
        account: account.tokenAccount,
        choice: choice)
      try Task.checkCancellation()
    } catch is CancellationError {
      return await finishFailure(flight, attemptID: attemptID, state: .preparing, category: .cancelled)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceBeforeSend(failure, flight: flight, attemptID: attemptID)
    } catch let error as ServerPodcastDestinationResolverError {
      return await finishFailure(
        flight,
        attemptID: attemptID,
        state: .preparing,
        category: NativeEpisodeServerSaveSupport.resolverCategory(error))
    } catch let error as APIError {
      return await finishFailure(
        flight,
        attemptID: attemptID,
        state: .preparing,
        category: NativeEpisodeServerSaveSupport.apiCategory(error))
    } catch {
      return await finishFailure(flight, attemptID: attemptID, state: .preparing, category: .unknown)
    }

    switch resolution {
    case .needsChoice(let prompt):
      return await present(
        .needsChoice(attemptID: attemptID, prompt: prompt), flight: flight, sentPhase: nil)
    case .noAccessiblePodcastLibraries:
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .invalidDestination)
    case .reuse(let itemID):
      return await prepareKnownShow(
        itemID, flight: flight, attemptID: attemptID, convergence: convergence)
    case .create(let destination):
      // No item exists to expand yet. The store's preparing-only provenance rule therefore records
      // the conservative no-match absence before the create checkpoint; detail completeness is
      // still checked before enqueue.
      do {
        try await fencer.persistPreflight(
          .absentBeforeRequest, flight: flight, attemptID: attemptID, on: self)
      } catch let failure as NativeEpisodeServerSaveFenceFailure {
        return await handleFenceBeforeSend(failure, flight: flight, attemptID: attemptID)
      } catch {
        return await finishFailure(
          flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
      }
      return await createShow(
        destination, flight: flight, attemptID: attemptID, convergence: convergence)
    }
  }

  /// A flight another caller already carried past `.preparing` reports its durable state rather
  /// than sending anything. `nil` means this save is the one that must continue.
  private func presentSettledFlight(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64
  ) async -> NativeEpisodeServerSaveOutcome? {
    guard flight.attempt.state != .preparing else { return nil }
    let fallback: NativeEpisodeServerSaveOutcome
    switch flight.attempt.state {
    case .accepted:
      fallback = .accepted(
        attemptID: attemptID, serverItemID: flight.attempt.serverItemId ?? "")
    case .createUncertain, .uncertain:
      fallback = .uncertain(
        attemptID: attemptID,
        state: flight.attempt.state,
        category: flight.attempt.errorCategory ?? .unknown)
    default:
      fallback = .inProgress(
        attemptID: attemptID,
        state: flight.attempt.state,
        serverItemID: flight.attempt.serverItemId)
    }
    return await present(fallback, flight: flight, sentPhase: nil)
  }

  func prepareKnownShow(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    convergence: NativeEpisodeServerSaveConvergencePolicy,
    sharedDetail: ItemDetailRead? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    guard NativeEpisodeServerSaveSupport.usableServerIdentity(itemID) else {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .invalidDestination)
    }
    do {
      try await fencer.persistServerItemID(
        itemID, flight: flight, attemptID: attemptID, on: self)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceBeforeSend(failure, flight: flight, attemptID: attemptID)
    } catch {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
    }
    return await preflightAndMaybeEnqueue(
      itemID,
      flight: flight,
      attemptID: attemptID,
      createWasSent: false,
      knownPresence: nil,
      convergence: convergence,
      sharedDetail: sharedDetail)
  }

  func createShow(
    _ destination: ServerPodcastDestination,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    convergence: NativeEpisodeServerSaveConvergencePolicy
  ) async -> NativeEpisodeServerSaveOutcome {
    let account: NativeEpisodeServerSaveAccount
    do {
      try await fencer.persistTransition(
        .creatingShow, flight: flight, attemptID: attemptID, itemID: nil, category: nil,
        on: self)
      try Task.checkCancellation()
      account = try await fencer.verifiedAccount(flight, scope: .source, on: self)
    } catch is CancellationError {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .cancelled)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceBeforeSend(
        failure, flight: flight, attemptID: attemptID, state: .creatingShow)
    } catch {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
    }

    let request = PodcastCreateRequest(
      libraryID: destination.libraryID,
      folderID: destination.folderID,
      path: destination.childPath,
      title: flight.command.feedTitle,
      author: flight.command.feedAuthor,
      feedURL: flight.command.feedURL.absoluteString,
      imageURL: flight.command.feedArtworkURL?.absoluteString)
    var requestEntered = false
    do {
      try Task.checkCancellation()
      requestEntered = true
      let itemID = try await podcastWriter.createPodcast(
        account: account.tokenAccount, request: request, diagnostics: nil)
      guard NativeEpisodeServerSaveSupport.usableServerIdentity(itemID) else {
        return await finishMutatingFailure(
          flight, attemptID: attemptID, phase: .create, requestEntered: true,
          category: .malformedResponse)
      }
      do {
        try await fencer.persistServerItemID(
          itemID, flight: flight, attemptID: attemptID, scope: .account, on: self)
      } catch let failure as NativeEpisodeServerSaveFenceFailure {
        return await handleFenceAfterSend(
          failure, flight: flight, attemptID: attemptID, phase: .create)
      } catch {
        return await persistUncertainAfterSend(
          flight, attemptID: attemptID, phase: .create, category: .localPersistence)
      }
      return await preflightAndMaybeEnqueue(
        itemID,
        flight: flight,
        attemptID: attemptID,
        createWasSent: true,
        knownPresence: .absentBeforeRequest,
        convergence: convergence)
    } catch is CancellationError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .create, requestEntered: requestEntered,
        category: .cancelled)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceAfterSend(
        failure, flight: flight, attemptID: attemptID, phase: .create)
    } catch is PodcastWriteError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .create, requestEntered: requestEntered,
        category: .invalidDestination)
    } catch let error as APIError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .create, requestEntered: requestEntered,
        category: NativeEpisodeServerSaveSupport.apiCategory(error))
    } catch {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .create, requestEntered: requestEntered,
        category: .unknown)
    }
  }

  /// Observes the accepted attempt now and again after each delay in
  /// `foregroundConvergenceDelays`, stopping at the first confirmation or at an outcome that a
  /// later look cannot change: a fence that no longer matches, a pruned source row, or a server
  /// item that is no longer the one the attempt was saved into.
  func convergeAccepted(attemptID: Int64) async {
    var delays = foregroundConvergenceDelays[...]
    while true {
      let outcome = await reconcile(attemptID: attemptID)
      guard Self.foregroundConvergenceContinues(after: outcome) else { return }
      guard let delay = delays.popFirst() else { return }
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
    }
  }

  static func foregroundConvergenceContinues(
    after outcome: NativeEpisodeServerSaveReconciliationOutcome
  ) -> Bool {
    switch outcome {
    case .confirmed:
      return false
    case .absent(_, let state):
      return state == .accepted
    case .inconclusive(_, let state, let category):
      guard state == .accepted else { return false }
      switch category {
      case .accountReplaced, .unsubscribed, .missingEpisode, .staleIdentity,
        .permissionChanged, .cancelled:
        return false
      default:
        return true
      }
    }
  }
}
