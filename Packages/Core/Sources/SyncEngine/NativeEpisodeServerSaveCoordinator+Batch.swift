import ABSApi
import Foundation
import Persistence

extension NativeEpisodeServerSaveCoordinator: NativeEpisodeServerSaveBatchSaving {
  public func saveBatch(
    _ request: NativeEpisodeServerSaveBatchRequest,
    cancellation: NativeEpisodeServerSaveBatchCancellationToken,
    onEpisodeOutcome: @escaping @Sendable (NativeEpisodeServerSaveBatchEpisodeOutcome) async -> Void
  ) async -> NativeEpisodeServerSaveBatchResult {
    guard let firstEpisodeID = request.episodeIds.first else {
      return NativeEpisodeServerSaveBatchResult(
        outcomes: [], stop: .completed, notAttempted: [], serverItemID: nil)
    }

    guard await capabilityReader.capability().canSave else {
      return batchPreconditionFailure(
        request: request,
        episodeID: firstEpisodeID,
        category: .permissionChanged)
    }

    let account: NativeEpisodeServerSaveAccount
    do {
      account = try await accountReader.currentAccount()
    } catch let error as NativeEpisodeServerSaveAccountReadingError {
      return batchPreconditionFailure(
        request: request,
        episodeID: firstEpisodeID,
        category: NativeEpisodeServerSaveSupport.accountCategory(error))
    } catch {
      return batchPreconditionFailure(
        request: request, episodeID: firstEpisodeID, category: .unknown)
    }
    let fence = NativeEpisodeServerSaveAccountFence(account: account)

    var outcomes = [NativeEpisodeServerSaveBatchEpisodeOutcome]()
    var establishedItemID: String?
    var pendingChoice = request.choice
    if case .existing(let itemID) = request.choice {
      establishedItemID = itemID
    }
    var acceptedAttemptIDs = [Int64]()
    var stop: NativeEpisodeServerSaveBatchStop = .completed
    // Set once an outcome has named the show; the remaining episodes then skip the resolver's
    // catalogue scan and preflight against one shared read. A caller-supplied choice is not
    // enough: the first episode still validates it against the catalogue.
    var knownShow: NativeEpisodeServerSaveKnownShow?

    for episodeID in request.episodeIds {
      // Cancellation is checked only between episodes, so an accepted or uncertain in-flight
      // request keeps the single-save coordinator's normal completion semantics.
      if cancellation.isCancelled {
        stop = .cancelled
        break
      }

      let current: NativeEpisodeServerSaveAccount
      do {
        current = try await accountReader.currentAccount()
        guard NativeEpisodeServerSaveFencer.matchesFence(current, fence: fence) else {
          let outcome = NativeEpisodeServerSaveOutcome.failed(
            attemptID: nil, state: .failed, category: .accountReplaced)
          let entry = NativeEpisodeServerSaveBatchEpisodeOutcome(
            episodeId: episodeID, outcome: outcome)
          outcomes.append(entry)
          stop = .failed(episodeId: episodeID, category: .accountReplaced)
          break
        }
      } catch let error as NativeEpisodeServerSaveAccountReadingError {
        let category = NativeEpisodeServerSaveSupport.accountCategory(error)
        let outcome = NativeEpisodeServerSaveOutcome.failed(
          attemptID: nil, state: .failed, category: category)
        let entry = NativeEpisodeServerSaveBatchEpisodeOutcome(
          episodeId: episodeID, outcome: outcome)
        outcomes.append(entry)
        stop = .failed(episodeId: episodeID, category: category)
        break
      } catch {
        let outcome = NativeEpisodeServerSaveOutcome.failed(
          attemptID: nil, state: .failed, category: .unknown)
        let entry = NativeEpisodeServerSaveBatchEpisodeOutcome(
          episodeId: episodeID, outcome: outcome)
        outcomes.append(entry)
        stop = .failed(episodeId: episodeID, category: .unknown)
        break
      }

      let episodeChoice: ServerPodcastSaveChoice?
      if let establishedItemID {
        episodeChoice = .existing(serverItemID: establishedItemID)
      } else {
        episodeChoice = pendingChoice
      }
      let wasLibraryAndFolderChoice: Bool
      if case .libraryAndFolder = episodeChoice {
        wasLibraryAndFolderChoice = true
      } else {
        wasLibraryAndFolderChoice = false
      }
      let outcome = await save(
        feedId: request.feedId,
        episodeId: episodeID,
        choice: episodeChoice,
        convergence: .deferred,
        knownShow: knownShow)
      let entry = NativeEpisodeServerSaveBatchEpisodeOutcome(episodeId: episodeID, outcome: outcome)
      outcomes.append(entry)
      await onEpisodeOutcome(entry)

      if knownShow == nil, let itemID = outcome.serverItemID, episodeID != request.episodeIds.last {
        // One read of the show for every episode still to come. A failed read costs nothing but
        // the saving: each remaining preflight then fetches for itself as before. The read keeps
        // its diagnostics, so a lossy one fails each preflight it feeds instead of proving absence.
        // Fenced again because the account may have changed while this episode saved.
        let detail = try? await readItemDetail(
          account: fencer.verifiedAccount(fence: fence, on: self).tokenAccount, itemID: itemID)
        knownShow = NativeEpisodeServerSaveKnownShow(itemID: itemID, detail: detail)
      }

      if wasLibraryAndFolderChoice {
        // A create choice may establish the shared show; the resolver rejects reusing that choice
        // after a match exists, so it is legal for only one episode in this batch.
        pendingChoice = nil
      }
      if establishedItemID == nil, let itemID = outcome.serverItemID {
        establishedItemID = itemID
      }
      if case .accepted(let attemptID, _) = outcome {
        acceptedAttemptIDs.append(attemptID)
      }

      switch outcome {
      case .accepted, .alreadyPresent, .inProgress:
        continue
      case .failed(_, _, .missingEpisode):
        continue
      case .needsChoice(let attemptID, let prompt):
        if establishedItemID == nil {
          stop = .needsChoice(episodeId: episodeID, attemptID: attemptID, prompt: prompt)
        } else {
          stop = .failed(episodeId: episodeID, category: .invalidDestination)
        }
        break
      case .uncertain(let attemptID, _, let category):
        stop = .uncertain(episodeId: episodeID, attemptID: attemptID, category: category)
        break
      case .failed(_, _, let category):
        stop = .failed(episodeId: episodeID, category: category)
        break
      }
      if case .completed = stop {
        continue
      }
      break
    }

    let notAttempted: [Int64]
    if let last = outcomes.last, let index = request.episodeIds.firstIndex(of: last.episodeId) {
      switch stop {
      case .completed:
        notAttempted = []
      default:
        notAttempted = Array(request.episodeIds.dropFirst(index + 1))
      }
    } else {
      notAttempted = Array(request.episodeIds.dropFirst(outcomes.count))
    }
    if acceptedAttemptIDs.isEmpty == false, let establishedItemID {
      lastBatchConvergence = Task { [self] in
        await convergeBatch(attemptIDs: acceptedAttemptIDs, serverItemID: establishedItemID, fence: fence)
      }
    }
    return NativeEpisodeServerSaveBatchResult(
      outcomes: outcomes,
      stop: stop,
      notAttempted: notAttempted,
      serverItemID: establishedItemID)
  }

  private func batchPreconditionFailure(
    request: NativeEpisodeServerSaveBatchRequest,
    episodeID: Int64,
    category: NativeEpisodeServerSaveErrorCategory
  ) -> NativeEpisodeServerSaveBatchResult {
    let outcome = NativeEpisodeServerSaveOutcome.failed(
      attemptID: nil, state: .failed, category: category)
    return NativeEpisodeServerSaveBatchResult(
      outcomes: [
        NativeEpisodeServerSaveBatchEpisodeOutcome(episodeId: episodeID, outcome: outcome)
      ],
      stop: .failed(episodeId: episodeID, category: category),
      notAttempted: Array(request.episodeIds.dropFirst()),
      serverItemID: nil)
  }

  /// `fence` is the account the batch's saves were fenced on. Each attempt's own fence runs only
  /// after the shared read, and the coordinator's client stays bound to the server the batch was
  /// saved on, so the read itself must be fenced or a replacement account's credentials reach that
  /// server. Rows can also go while the account stays, so the read is made only for the attempts
  /// still stored, and not at all once none are.
  func reconcileGroup(
    attemptIDs: [Int64],
    serverItemID: String,
    fence: NativeEpisodeServerSaveAccountFence
  ) async -> [NativeEpisodeServerSaveReconciliationOutcome] {
    guard attemptIDs.isEmpty == false else { return [] }
    var stored = attemptIDs
    let outcomes: [NativeEpisodeServerSaveReconciliationOutcome]
    do {
      let account = try await fencer.verifiedAccount(fence: fence, on: self)
      let present = await storedAttemptIDs(attemptIDs)
      stored = present
      guard present.isEmpty == false else { return attemptIDs.map(Self.missingAttemptOutcome) }
      let sharedDetail = try await readItemDetail(account: account.tokenAccount, itemID: serverItemID)
      outcomes = await withTaskGroup(of: NativeEpisodeServerSaveReconciliationOutcome.self) { group in
        for attemptID in present {
          group.addTask { await self.reconcile(attemptID: attemptID, sharedDetail: sharedDetail) }
        }
        var results = [NativeEpisodeServerSaveReconciliationOutcome]()
        for await result in group { results.append(result) }
        return results
      }
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      outcomes = await groupFetchFailure(
        attemptIDs: stored, category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as APIError {
      outcomes = await groupFetchFailure(
        attemptIDs: stored, category: NativeEpisodeServerSaveSupport.apiCategory(error))
    } catch is CancellationError {
      outcomes = await groupFetchFailure(attemptIDs: stored, category: .cancelled)
    } catch {
      outcomes = await groupFetchFailure(attemptIDs: stored, category: .transport)
    }
    return attemptIDs.map { id in
      outcomes.first { $0.attemptID == id } ?? Self.missingAttemptOutcome(id)
    }
  }

  /// The attempts whose rows are still stored. Only a row proven absent is dropped: one that cannot
  /// be read stays, so its own `reconcile` reports the store failure.
  private func storedAttemptIDs(_ attemptIDs: [Int64]) async -> [Int64] {
    var stored = [Int64]()
    for attemptID in attemptIDs {
      do {
        guard try await attemptStore.fetchAttemptAsync(id: attemptID) != nil else { continue }
      } catch {
        // Not proven gone, so it stays.
      }
      stored.append(attemptID)
    }
    return stored
  }

  /// What `reconcile` reports for a row that is gone. `.failed` ends convergence for it.
  private static func missingAttemptOutcome(_ attemptID: Int64) -> NativeEpisodeServerSaveReconciliationOutcome {
    .inconclusive(attemptID: attemptID, state: .failed, category: .unknown)
  }

  private func groupFetchFailure(
    attemptIDs: [Int64],
    category: NativeEpisodeServerSaveErrorCategory
  ) async -> [NativeEpisodeServerSaveReconciliationOutcome] {
    var outcomes = [NativeEpisodeServerSaveReconciliationOutcome]()
    for attemptID in attemptIDs {
      // A missing attempt reads as `.failed`, as in `reconcile`, so convergence ends for a row
      // that account removal cascaded away.
      let state =
        (try? await self.attemptStore.fetchAttemptAsync(id: attemptID))??.state ?? .failed
      outcomes.append(.inconclusive(attemptID: attemptID, state: state, category: category))
    }
    return outcomes
  }

  func convergeBatch(
    attemptIDs: [Int64],
    serverItemID: String,
    fence: NativeEpisodeServerSaveAccountFence
  ) async {
    var pending = attemptIDs
    var delays = foregroundConvergenceDelays[...]
    while pending.isEmpty == false {
      let results = await reconcileGroup(attemptIDs: pending, serverItemID: serverItemID, fence: fence)
      pending = results.filter(Self.foregroundConvergenceContinues(after:)).map(\.attemptID)
      guard pending.isEmpty == false, let delay = delays.popFirst() else { return }
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
    }
  }
}
