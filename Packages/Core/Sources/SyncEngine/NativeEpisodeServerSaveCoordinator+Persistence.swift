import ABSApi
import Foundation
import Persistence

extension NativeEpisodeServerSaveCoordinator {
  func persistUncertainAfterSend(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    phase: NativeEpisodeServerSaveRequestPhase,
    category: NativeEpisodeServerSaveErrorCategory
  ) async -> NativeEpisodeServerSaveOutcome {
    let state: NativeEpisodeServerSaveAttemptState =
      phase == .create ? .createUncertain : .uncertain
    do {
      // Source changes cannot erase the fact that a request may have reached the server. The
      // account fence is still checked before this durable uncertainty checkpoint.
      _ = try await fencer.verifyFence(flight, scope: .account, on: self)
      let record = try await attemptStore.transitionAsync(
        attemptId: attemptID, to: state, serverItemId: nil, errorCategory: category)
      return await present(
        .uncertain(
          attemptID: attemptID,
          state: record.state,
          category: record.errorCategory ?? category),
        flight: flight,
        sentPhase: phase)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .uncertain(
        attemptID: attemptID, state: state, category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .uncertain(
        attemptID: attemptID,
        state: state,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : category)
    } catch {
      return .uncertain(attemptID: attemptID, state: state, category: category)
    }
  }

  /// A complete preflight found the episode already on the server. Nothing was sent, so the
  /// attempt is finished: record the matched server ids and confirm through the store's
  /// provenance-checked edge. The `.preExisting` provenance the row keeps is what hides removal.
  func confirmPreExisting(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    media: PodcastMedia
  ) async -> NativeEpisodeServerSaveOutcome {
    guard
      let episodeID = NativeEpisodeServerSaveSupport.matchingEpisodeID(
        command: flight.command, media: media),
      NativeEpisodeServerSaveSupport.usableServerIdentity(episodeID)
    else {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
    }
    do {
      _ = try await fencer.verifyFence(flight, scope: .source, on: self)
      _ = try await attemptStore.confirmPreExistingAsync(
        attemptId: attemptID, serverItemId: itemID, serverEpisodeId: episodeID)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return await handleFenceBeforeSend(failure, flight: flight, attemptID: attemptID)
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      if NativeEpisodeServerSaveFencer.isAccountFenceError(error) {
        return .failed(attemptID: attemptID, state: .preparing, category: .accountReplaced)
      }
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
    } catch {
      return await finishFailure(
        flight, attemptID: attemptID, state: .preparing, category: .localPersistence)
    }
    return .alreadyPresent(attemptID: attemptID, serverItemID: itemID)
  }

  func finishFailure(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory,
    scope: NativeEpisodeServerSaveFenceScope = .source
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      // The row was just written under `scope`; re-reading it under the source fence would let
      // a pruned RSS row rewrite a failure that a sent request has already earned.
      let record = try await persistFailure(
        flight,
        attemptID: attemptID,
        category: category,
        scope: scope)
      return .failed(
        attemptID: attemptID,
        state: record.state,
        category: record.errorCategory ?? category)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .failed(attemptID: attemptID, state: state, category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return .failed(attemptID: attemptID, state: state, category: .cancelled)
    } catch {
      return .failed(attemptID: attemptID, state: state, category: .localPersistence)
    }
  }

  func persistFailure(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    category: NativeEpisodeServerSaveErrorCategory,
    scope: NativeEpisodeServerSaveFenceScope
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await fencer.persistTransition(
      .failed, flight: flight, attemptID: attemptID, itemID: nil, category: category,
      scope: scope, on: self)
  }

  func finishMutatingFailure(
    _ flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    phase: NativeEpisodeServerSaveRequestPhase,
    requestEntered: Bool,
    category: NativeEpisodeServerSaveErrorCategory
  ) async -> NativeEpisodeServerSaveOutcome {
    if requestEntered && Self.isUncertain(category) {
      return await persistUncertainAfterSend(
        flight, attemptID: attemptID, phase: phase, category: category)
    }
    do {
      _ = try await fencer.verifyFence(flight, scope: .source, on: self)
      let record = try await attemptStore.transitionAsync(
        attemptId: attemptID, to: .failed, serverItemId: nil, errorCategory: category)
      return await present(
        .failed(
          attemptID: attemptID,
          state: record.state,
          category: record.errorCategory ?? category),
        flight: flight,
        sentPhase: nil)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      if requestEntered {
        return await handleFenceAfterSend(
          failure, flight: flight, attemptID: attemptID, phase: phase)
      }
      return .failed(
        attemptID: attemptID,
        state: phase == .create ? .creatingShow : .requestingDownload,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      if NativeEpisodeServerSaveFencer.isAccountFenceError(error) {
        if requestEntered {
          return await handleFenceAfterSend(
            .accountReplaced, flight: flight, attemptID: attemptID, phase: phase)
        }
        return .failed(
          attemptID: attemptID,
          state: phase == .create ? .creatingShow : .requestingDownload,
          category: .accountReplaced)
      }
      return .failed(
        attemptID: attemptID,
        state: phase == .create ? .creatingShow : .requestingDownload,
        category: .localPersistence)
    } catch is CancellationError {
      return .failed(
        attemptID: attemptID,
        state: phase == .create ? .creatingShow : .requestingDownload,
        category: .cancelled)
    } catch {
      return .failed(
        attemptID: attemptID,
        state: phase == .create ? .creatingShow : .requestingDownload,
        category: .localPersistence)
    }
  }

  func handleFenceBeforeSend(
    _ failure: NativeEpisodeServerSaveFenceFailure,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState = .preparing
  ) async -> NativeEpisodeServerSaveOutcome {
    guard case .accountReplaced = failure else {
      return await finishFailure(
        flight,
        attemptID: attemptID,
        state: state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure),
        scope: .account)
    }
    return .failed(attemptID: attemptID, state: state, category: .accountReplaced)
  }

  func handleFenceBeforeEnqueue(
    _ failure: NativeEpisodeServerSaveFenceFailure,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState
  ) async -> NativeEpisodeServerSaveOutcome {
    await handleFenceBeforeSend(
      failure, flight: flight, attemptID: attemptID, state: state)
  }

  func handleFenceAfterSend(
    _ failure: NativeEpisodeServerSaveFenceFailure,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    phase: NativeEpisodeServerSaveRequestPhase
  ) async -> NativeEpisodeServerSaveOutcome {
    if case .accountReplaced = failure {
      return .uncertain(
        attemptID: attemptID,
        state: phase == .create ? .createUncertain : .uncertain,
        category: .accountReplaced)
    }
    return await persistUncertainAfterSend(
      flight,
      attemptID: attemptID,
      phase: phase,
      category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
  }

  func present(
    _ fallback: NativeEpisodeServerSaveOutcome,
    flight: NativeEpisodeServerSaveFlight,
    sentPhase: NativeEpisodeServerSaveRequestPhase?
  ) async -> NativeEpisodeServerSaveOutcome {
    do {
      let record = try await fencer.verifyFence(
        flight, scope: sentPhase == nil ? .source : .account, on: self)
      return NativeEpisodeServerSaveSupport.outcome(from: record, fallback: fallback)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      if let sentPhase {
        if case .accountReplaced = failure {
          return .uncertain(
            attemptID: flight.attempt.id!,
            state: sentPhase == .create ? .createUncertain : .uncertain,
            category: .accountReplaced)
        }
        return await persistUncertainAfterSend(
          flight,
          attemptID: flight.attempt.id!,
          phase: sentPhase,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
      }
      return .failed(
        attemptID: flight.attempt.id,
        state: fallback.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      if let sentPhase {
        return .uncertain(
          attemptID: flight.attempt.id!,
          state: sentPhase == .create ? .createUncertain : .uncertain,
          category: .cancelled)
      }
      return .failed(
        attemptID: flight.attempt.id, state: fallback.state, category: .cancelled)
    } catch {
      if let sentPhase {
        return .uncertain(
          attemptID: flight.attempt.id!,
          state: sentPhase == .create ? .createUncertain : .uncertain,
          category: .localPersistence)
      }
      return .failed(
        attemptID: flight.attempt.id,
        state: fallback.state,
        category: .localPersistence)
    }
  }

  static func isUncertain(_ category: NativeEpisodeServerSaveErrorCategory) -> Bool {
    switch category {
    case .transport, .serverFailure, .malformedResponse, .cancelled, .unknown, .localPersistence,
      .accountReplaced, .unsubscribed, .missingEpisode, .credentialedFeed:
      return true
    case .invalidDestination, .permissionChanged, .staleIdentity, .incompleteEpisodeList:
      return false
    }
  }

}
