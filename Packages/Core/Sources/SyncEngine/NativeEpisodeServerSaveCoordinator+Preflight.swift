import ABSApi
import Foundation
import Persistence

/// The preflight that decides whether the episode must be requested: one complete view of the
/// show's episode list, checked for the evidence absence needs, then the enqueue itself.
///
/// Each stage returns its value and, when the stage ends the save, the outcome to return. Exactly
/// one side is non-nil on every path.
extension NativeEpisodeServerSaveCoordinator {
  func preflightAndMaybeEnqueue(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    createWasSent: Bool,
    knownPresence: NativeEpisodeServerSavePreflightPresence?,
    convergence: NativeEpisodeServerSaveConvergencePolicy = .foreground,
    sharedDetail: ItemDetailRead? = nil
  ) async -> NativeEpisodeServerSaveOutcome {
    let detail = await readPreflightDetail(
      itemID, flight: flight, attemptID: attemptID, createWasSent: createWasSent,
      sharedDetail: sharedDetail)
    if let failure = detail.failure { return failure }
    guard let read = detail.read else {
      return await failPreflight(
        .incompleteEpisodeList, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
    }

    let verdict = await admitPreflightPresence(
      read, itemID: itemID, flight: flight, attemptID: attemptID, createWasSent: createWasSent,
      knownPresence: knownPresence)
    if let failure = verdict.failure { return failure }
    guard let presence = verdict.presence, let media = verdict.media else {
      return await failPreflight(
        .incompleteEpisodeList, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
    }
    if presence == .preExisting {
      return await confirmPreExisting(itemID, flight: flight, attemptID: attemptID, media: media)
    }

    let transition = await beginEnqueueTransition(
      itemID, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
    if let failure = transition.failure { return failure }
    guard let account = transition.account else {
      return await failPreflight(
        .accountReplaced, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
    }

    if let failure = await enqueuePreflightedEpisode(
      itemID, account: account, flight: flight, attemptID: attemptID)
    {
      return failure
    }
    return await acceptEnqueuedEpisode(
      itemID, flight: flight, attemptID: attemptID, convergence: convergence)
  }

  /// `createWasSent` decides three things at once: the state a preflight failure is recorded
  /// against, the scope the account fence is read at, and the scope the failure is checked at.
  private func failPreflight(
    _ category: NativeEpisodeServerSaveErrorCategory,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    createWasSent: Bool
  ) async -> NativeEpisodeServerSaveOutcome {
    await finishFailure(
      flight, attemptID: attemptID,
      state: createWasSent ? .creatingShow : .preparing,
      category: category,
      scope: createWasSent ? .account : .source)
  }

  private func readPreflightDetail(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    createWasSent: Bool,
    sharedDetail: ItemDetailRead?
  ) async -> (read: ItemDetailRead?, failure: NativeEpisodeServerSaveOutcome?) {
    do {
      try Task.checkCancellation()
      let read: ItemDetailRead
      if let sharedDetail, sharedDetail.detail.id == itemID {
        // A batch's shared read. It predates this episode's request by a few requests at most,
        // and the preflight it feeds asks only whether this episode was already on the server.
        read = sharedDetail
      } else {
        let account = try await fencer.verifiedAccount(
          flight, scope: createWasSent ? .subscription : .source, on: self)
        read = try await readItemDetail(account: account.tokenAccount, itemID: itemID)
      }
      try Task.checkCancellation()
      return (read, nil)
    } catch is CancellationError {
      return (
        nil,
        await failPreflight(
          .cancelled, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
      )
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      if case .accountReplaced = failure, createWasSent {
        return (
          nil,
          await handleFenceAfterSend(
            failure, flight: flight, attemptID: attemptID, phase: .create)
        )
      }
      return (
        nil,
        await handleFenceBeforeEnqueue(
          failure, flight: flight, attemptID: attemptID,
          state: createWasSent ? .creatingShow : .preparing)
      )
    } catch let error as APIError {
      return (
        nil,
        await failPreflight(
          NativeEpisodeServerSaveSupport.apiCategory(error), flight: flight, attemptID: attemptID,
          createWasSent: createWasSent)
      )
    } catch {
      return (
        nil,
        await failPreflight(
          .transport, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
      )
    }
  }

  private func admitPreflightPresence(
    _ read: ItemDetailRead,
    itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    createWasSent: Bool,
    knownPresence: NativeEpisodeServerSavePreflightPresence?
  ) async -> (
    presence: NativeEpisodeServerSavePreflightPresence?, media: PodcastMedia?,
    failure: NativeEpisodeServerSaveOutcome?
  ) {
    guard case .podcast(let media)? = read.detail.media,
      media.isEpisodeListStructurallyComplete
    else {
      return (
        nil, nil,
        await failPreflight(
          .incompleteEpisodeList, flight: flight, attemptID: attemptID,
          createWasSent: createWasSent)
      )
    }

    if NativeEpisodeServerSaveSupport.hasDuplicateGUIDMatches(command: flight.command, media: media) {
      return (
        nil, nil,
        await failPreflight(
          .incompleteEpisodeList, flight: flight, attemptID: attemptID,
          createWasSent: createWasSent)
      )
    }
    let presence = NativeEpisodeServerSaveSupport.preflightPresence(
      command: flight.command, media: media)
    // Finding the episode proves presence even in a lossy list; only absence needs the stricter
    // evidence, because absence is what authorises sending the request.
    if presence == .absentBeforeRequest,
      media.episodeListProvesAbsence(detailDiagnostics: read.diagnostics) == false
    {
      return (
        nil, nil,
        await failPreflight(
          .incompleteEpisodeList, flight: flight, attemptID: attemptID,
          createWasSent: createWasSent)
      )
    }
    if let knownPresence, knownPresence != presence {
      // A create path is seeded with absence because the store forbids rewriting provenance after
      // the request checkpoint. Do not present a pre-existing result while the durable provenance
      // still says absent; fail closed and let the next explicit attempt resolve the race.
      return (
        nil, nil,
        await failPreflight(
          .localPersistence, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
      )
    }

    if knownPresence == nil {
      do {
        try await fencer.persistPreflight(presence, flight: flight, attemptID: attemptID, on: self)
      } catch let failure as NativeEpisodeServerSaveFenceFailure {
        return (
          nil, nil,
          await handleFenceBeforeEnqueue(
            failure, flight: flight, attemptID: attemptID,
            state: createWasSent ? .creatingShow : .preparing)
        )
      } catch {
        return (
          nil, nil,
          await failPreflight(
            .localPersistence, flight: flight, attemptID: attemptID, createWasSent: createWasSent)
        )
      }
    }
    return (presence, media, nil)
  }

  /// The durable request checkpoint and the account the enqueue is authorized with, taken
  /// together because a fence failure between them must not leave the request unsent but
  /// unrecorded.
  private func beginEnqueueTransition(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    createWasSent: Bool
  ) async -> (
    account: NativeEpisodeServerSaveAccount?, failure: NativeEpisodeServerSaveOutcome?
  ) {
    do {
      try await fencer.persistTransition(
        .requestingDownload,
        flight: flight,
        attemptID: attemptID,
        itemID: itemID,
        category: nil,
        scope: createWasSent ? .subscription : .source,
        on: self)
      try Task.checkCancellation()
      return (
        try await fencer.verifiedAccount(
          flight, scope: createWasSent ? .subscription : .source, on: self),
        nil
      )
    } catch is CancellationError {
      return (
        nil,
        await finishFailure(
          flight,
          attemptID: attemptID,
          state: .requestingDownload,
          category: .cancelled,
          scope: createWasSent ? .account : .source)
      )
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return (
        nil,
        await handleFenceBeforeEnqueue(
          failure, flight: flight, attemptID: attemptID, state: .requestingDownload)
      )
    } catch {
      return (
        nil,
        await finishFailure(
          flight,
          attemptID: attemptID,
          state: .requestingDownload,
          category: .localPersistence,
          scope: createWasSent ? .account : .source)
      )
    }
  }

  /// `nil` means the server accepted the enqueue; otherwise the save ends here.
  private func enqueuePreflightedEpisode(
    _ itemID: String,
    account: NativeEpisodeServerSaveAccount,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64
  ) async -> NativeEpisodeServerSaveOutcome? {
    let episode = PodcastEpisodeDownloadRequest(
      title: flight.command.episodeTitle,
      description: flight.command.episodeSynopsis,
      enclosureURL: flight.command.enclosureURL.absoluteString,
      enclosureType: flight.command.enclosureType,
      declaredBytes: flight.command.declaredBytes,
      publishedAt: flight.command.publishedAt,
      guid: flight.command.episodeGUID,
      seasonNumber: flight.command.seasonNumber.map(String.init),
      episodeNumber: flight.command.episodeNumber.map(String.init))
    var requestEntered = false
    do {
      try Task.checkCancellation()
      requestEntered = true
      try await podcastWriter.enqueuePodcastEpisode(
        account: account.tokenAccount, itemID: itemID, episode: episode)
      return nil
    } catch is CancellationError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .enqueue, requestEntered: requestEntered,
        category: .cancelled)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      if requestEntered {
        return await handleFenceAfterSend(
          failure, flight: flight, attemptID: attemptID, phase: .enqueue)
      }
      return await handleFenceBeforeEnqueue(
        failure, flight: flight, attemptID: attemptID, state: .requestingDownload)
    } catch is PodcastWriteError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .enqueue, requestEntered: requestEntered,
        category: .invalidDestination)
    } catch let error as APIError {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .enqueue, requestEntered: requestEntered,
        category: NativeEpisodeServerSaveSupport.apiCategory(error))
    } catch {
      return await finishMutatingFailure(
        flight, attemptID: attemptID, phase: .enqueue, requestEntered: requestEntered,
        category: .unknown)
    }
  }

  /// The durable caller-visible result, computed before the detached convergence starts so a fast
  /// catalogue response cannot rewrite this save result.
  private func acceptEnqueuedEpisode(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    convergence: NativeEpisodeServerSaveConvergencePolicy
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      try await fencer.persistTransition(
        .accepted,
        flight: flight,
        attemptID: attemptID,
        itemID: itemID,
        category: nil,
        scope: .account,
        on: self)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceAfterSend(
        failure, flight: flight, attemptID: attemptID, phase: .enqueue)
    } catch {
      return await persistUncertainAfterSend(
        flight, attemptID: attemptID, phase: .enqueue, category: .localPersistence)
    }
    let acceptedOutcome = await present(
      .accepted(attemptID: attemptID, serverItemID: itemID), flight: flight, sentPhase: .enqueue)
    // Acceptance is the durable caller-visible result. Compute it before starting the detached
    // observation so a fast catalogue response cannot rewrite this save result.
    if convergence == .foreground {
      lastConvergence = Task { [self] in
        await convergeAccepted(attemptID: attemptID)
      }
    }
    return acceptedOutcome
  }
}
