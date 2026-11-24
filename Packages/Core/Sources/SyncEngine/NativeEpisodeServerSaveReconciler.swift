import ABSApi
import Foundation
import Persistence

/// The result of one foreground observation of a known server item. Absence is an
/// explicit result, not a lifecycle transition: packet B owns the later explicit retry decision.
public enum NativeEpisodeServerSaveReconciliationOutcome: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  case confirmed(attemptID: Int64, state: NativeEpisodeServerSaveAttemptState, serverEpisodeID: String)
  case absent(attemptID: Int64, state: NativeEpisodeServerSaveAttemptState)
  case inconclusive(
    attemptID: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory)

  public var attemptID: Int64 {
    switch self {
    case .confirmed(let id, _, _), .absent(let id, _), .inconclusive(let id, _, _): return id
    }
  }

  public var state: NativeEpisodeServerSaveAttemptState {
    switch self {
    case .confirmed(_, let state, _), .absent(_, let state), .inconclusive(_, let state, _):
      return state
    }
  }

  public var errorCategory: NativeEpisodeServerSaveErrorCategory? {
    if case .inconclusive(_, _, let category) = self { return category }
    return nil
  }

  public var serverEpisodeID: String? {
    if case .confirmed(_, _, let id) = self { return id }
    return nil
  }

  public var description: String {
    switch self {
    case .confirmed:
      return "NativeEpisodeServerSaveReconciliationOutcome(confirmed)"
    case .absent(_, let state):
      return "NativeEpisodeServerSaveReconciliationOutcome(absent, state: \(state.rawValue))"
    case .inconclusive(_, let state, let category):
      return
        "NativeEpisodeServerSaveReconciliationOutcome(inconclusive, state: \(state.rawValue), category: \(category.rawValue))"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

extension NativeEpisodeServerSaveCoordinator {
  /// Performs exactly one item-detail observation for an accepted or uncertain attempt. The
  /// caller receives the save result independently; this method is also callable by
  /// ordinary catalogue-refresh integration in a later slice.
  func reconcile(
    attemptID: Int64,
    sharedDetail: ItemDetailRead? = nil
  ) async -> NativeEpisodeServerSaveReconciliationOutcome {
    let initialState: NativeEpisodeServerSaveAttemptState =
      (try? await attemptStore.fetchAttemptAsync(id: attemptID))??.state ?? .failed

    if initialState == .deleting || initialState == .deleteUncertain || initialState == .deleteFailed {
      return await reconcileRemoval(attemptID: attemptID)
    }

    let flight: NativeEpisodeServerSaveFlight
    do {
      guard let attempt = try await attemptStore.fetchAttemptAsync(id: attemptID),
        let storedID = attempt.id,
        storedID == attemptID,
        attempt.state == .accepted || attempt.state == .uncertain || attempt.state == .confirmed
      else {
        return .inconclusive(attemptID: attemptID, state: initialState, category: .unknown)
      }
      guard
        let rebuilt = try await fencer.rebuildFlight(
          for: attempt, command: .durableIdentity, scope: .account, on: self)
      else {
        return .inconclusive(attemptID: attemptID, state: attempt.state, category: .accountReplaced)
      }
      flight = rebuilt
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(
        attemptID: attemptID, state: initialState, category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      return .inconclusive(
        attemptID: attemptID, state: initialState,
        category: NativeEpisodeServerSaveSupport.readerCategory(error))
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .inconclusive(
        attemptID: attemptID, state: initialState,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence)
    } catch is CancellationError {
      return .inconclusive(attemptID: attemptID, state: initialState, category: .cancelled)
    } catch {
      return .inconclusive(attemptID: attemptID, state: initialState, category: .accountReplaced)
    }

    let currentRecord: NativeEpisodeServerSaveAttemptRecord
    do {
      currentRecord = try await fencer.verifyFence(flight, scope: .account, on: self)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(
        attemptID: attemptID, state: flight.attempt.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return .inconclusive(attemptID: attemptID, state: flight.attempt.state, category: .cancelled)
    } catch {
      return .inconclusive(attemptID: attemptID, state: flight.attempt.state, category: .localPersistence)
    }

    // Confirmation is already durable. Do not fetch the item again or attempt an illegal
    // `.confirmed -> .confirmed` transition; only the fence check above is repeated for this
    // presentation value.
    if currentRecord.state == .confirmed {
      guard let serverEpisodeID = currentRecord.serverEpisodeId else {
        return .inconclusive(attemptID: attemptID, state: .confirmed, category: .localPersistence)
      }
      return await fenced(
        .confirmed(attemptID: attemptID, state: .confirmed, serverEpisodeID: serverEpisodeID),
        flight: flight)
    }

    let read: ItemDetailRead
    if let sharedDetail, sharedDetail.detail.id == flight.attempt.serverItemId {
      read = sharedDetail
    } else {
      do {
        let account = try await fencer.verifiedAccount(flight, scope: .account, on: self)
        read = try await readItemDetail(
          account: account.tokenAccount, itemID: flight.attempt.serverItemId ?? "")
      } catch let error as APIError {
        return await fenced(
          .inconclusive(
            attemptID: attemptID, state: currentRecord.state,
            category: NativeEpisodeServerSaveSupport.apiCategory(error)),
          flight: flight)
      } catch is CancellationError {
        return await fenced(
          .inconclusive(attemptID: attemptID, state: currentRecord.state, category: .cancelled),
          flight: flight)
      } catch let failure as NativeEpisodeServerSaveFenceFailure {
        return .inconclusive(
          attemptID: attemptID, state: currentRecord.state,
          category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
      } catch {
        return await fenced(
          .inconclusive(attemptID: attemptID, state: currentRecord.state, category: .transport),
          flight: flight)
      }
    }

    guard read.detail.id == flight.attempt.serverItemId else {
      return await fenced(
        .inconclusive(
          attemptID: attemptID, state: currentRecord.state, category: .staleIdentity),
        flight: flight)
    }

    guard case .podcast(let media)? = read.detail.media,
      media.isEpisodeListStructurallyComplete
    else {
      return await fenced(
        .inconclusive(
          attemptID: attemptID, state: currentRecord.state, category: .incompleteEpisodeList),
        flight: flight)
    }

    let matchedEpisodeID: String?
    if NativeEpisodeServerSaveSupport.isGUIDIdentityKey(currentRecord.episodeIdentityKey) {
      matchedEpisodeID = NativeEpisodeServerSaveSupport.matchingEpisodeID(
        guidIdentityKey: currentRecord.episodeIdentityKey, media: media)
    } else {
      // A hashed enclosure identity cannot be expanded from the server list alone; only the RSS
      // row still holds the enclosure URL. Without it the episode is indistinguishable from
      // absence, and absence is what authorises a resend, so the answer must stay inconclusive.
      let source: NativeEpisodeServerSaveCommand
      do {
        source = try await commandReader.read(
          feedId: flight.attempt.feedId, episodeId: flight.attempt.episodeId)
      } catch let error as NativeEpisodeServerSaveCommandReaderError {
        return await fenced(
          .inconclusive(
            attemptID: attemptID, state: currentRecord.state,
            category: NativeEpisodeServerSaveSupport.readerCategory(error)),
          flight: flight)
      } catch is CancellationError {
        return await fenced(
          .inconclusive(attemptID: attemptID, state: currentRecord.state, category: .cancelled),
          flight: flight)
      } catch {
        return await fenced(
          .inconclusive(
            attemptID: attemptID, state: currentRecord.state, category: .missingEpisode),
          flight: flight)
      }
      matchedEpisodeID = NativeEpisodeServerSaveSupport.matchingEpisodeID(
        enclosureURL: source.enclosureURL, media: media)
    }
    guard let serverEpisodeID = matchedEpisodeID else {
      // A match proves presence even in a lossy list; absence authorises a resend, so it needs
      // the stricter evidence.
      guard media.episodeListProvesAbsence(detailDiagnostics: read.diagnostics) else {
        return await fenced(
          .inconclusive(
            attemptID: attemptID, state: currentRecord.state, category: .incompleteEpisodeList),
          flight: flight)
      }
      return await fenced(
        .absent(attemptID: attemptID, state: currentRecord.state), flight: flight)
    }

    do {
      try await fencer.persistServerEpisodeID(
        serverEpisodeID, flight: flight, attemptID: attemptID, scope: .account, on: self)
      try await fencer.persistTransition(
        .confirmed,
        flight: flight,
        attemptID: attemptID,
        itemID: flight.attempt.serverItemId,
        category: nil,
        scope: .account,
        on: self)
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(
        attemptID: attemptID, state: currentRecord.state, category: NativeEpisodeServerSaveFencer.fenceCategory(failure)
      )
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      return .inconclusive(
        attemptID: attemptID, state: currentRecord.state,
        category: NativeEpisodeServerSaveFencer.isAccountFenceError(error) ? .accountReplaced : .localPersistence)
    } catch is CancellationError {
      return .inconclusive(attemptID: attemptID, state: currentRecord.state, category: .cancelled)
    } catch {
      return .inconclusive(attemptID: attemptID, state: currentRecord.state, category: .localPersistence)
    }

    return await fenced(
      .confirmed(attemptID: attemptID, state: .confirmed, serverEpisodeID: serverEpisodeID),
      flight: flight)
  }

  private func fenced(
    _ outcome: NativeEpisodeServerSaveReconciliationOutcome,
    flight: NativeEpisodeServerSaveFlight
  ) async -> NativeEpisodeServerSaveReconciliationOutcome {
    do {
      _ = try await fencer.verifyFence(flight, scope: .account, on: self)
      return outcome
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      return .inconclusive(
        attemptID: flight.attempt.id!, state: outcome.state,
        category: NativeEpisodeServerSaveFencer.fenceCategory(failure))
    } catch is CancellationError {
      return .inconclusive(
        attemptID: flight.attempt.id!, state: outcome.state, category: .cancelled)
    } catch {
      return .inconclusive(
        attemptID: flight.attempt.id!, state: outcome.state, category: .localPersistence)
    }
  }
}
