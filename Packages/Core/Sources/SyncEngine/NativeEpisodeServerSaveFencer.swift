import ABSApi
import Foundation
import Persistence

/// The fence/durable-write layer a save, removal, recovery and reconciliation all share: every
/// attempt-store write re-verifies the fence at the scope the flight requires immediately before
/// the write it authorises, and a write the store refuses because the account changed underneath
/// it is reported as the fence failure it is.
///
/// Every async member takes the coordinator as an `isolated` parameter, so the work runs on the
/// coordinator's executor and save and removal only interleave at `await`s, exactly as when these
/// methods were actor members. The type reads no coordinator state through that
/// parameter: it touches only the four dependencies stored here.
struct NativeEpisodeServerSaveFencer: Sendable {
  let attemptStore: any NativeEpisodeServerSaveAttemptStoring
  let accountReader: any NativeEpisodeServerSaveAccountReading
  let commandReader: any NativeEpisodeServerSaveCommandReading
  let nativeSubscriptions: any NativePodcastSubscriptionsReading

  /// Every attempt-store write a flight makes: the fence is re-verified at `scope` first, and a
  /// write the store refuses because the account changed underneath it is reported as the fence
  /// failure it is. Any other store error is rethrown unchanged for the caller to classify.
  func fencedWrite<Written>(
    _ flight: NativeEpisodeServerSaveFlight,
    scope: NativeEpisodeServerSaveFenceScope,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator,
    _ write: () async throws -> Written
  ) async throws -> Written {
    _ = try await verifyFence(flight, scope: scope, on: coordinator)
    do {
      return try await write()
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      if Self.isAccountFenceError(error) { throw NativeEpisodeServerSaveFenceFailure.accountReplaced }
      throw error
    }
  }

  @discardableResult
  func persistTransition(
    _ state: NativeEpisodeServerSaveAttemptState,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    itemID: String?,
    category: NativeEpisodeServerSaveErrorCategory?,
    scope: NativeEpisodeServerSaveFenceScope = .source,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await fencedWrite(flight, scope: scope, on: coordinator) {
      try await attemptStore.transitionAsync(
        attemptId: attemptID, to: state, serverItemId: itemID, errorCategory: category)
    }
  }

  func persistServerItemID(
    _ itemID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    scope: NativeEpisodeServerSaveFenceScope = .source,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws {
    _ = try await fencedWrite(flight, scope: scope, on: coordinator) {
      try await attemptStore.recordServerItemIDAsync(itemID, attemptId: attemptID)
    }
  }

  func persistServerEpisodeID(
    _ episodeID: String,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    scope: NativeEpisodeServerSaveFenceScope = .source,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws {
    _ = try await fencedWrite(flight, scope: scope, on: coordinator) {
      try await attemptStore.recordServerEpisodeIDAsync(episodeID, attemptId: attemptID)
    }
  }

  func persistPreflight(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    flight: NativeEpisodeServerSaveFlight,
    attemptID: Int64,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws {
    _ = try await fencedWrite(flight, scope: .source, on: coordinator) {
      try await attemptStore.recordPreflightPresenceAsync(presence, attemptId: attemptID)
    }
  }

  /// Returns the raw token namespace only for the immediately following endpoint call. It is
  /// never retained in `NativeEpisodeServerSaveFlight`, and the same opaque fence is checked again after the read.
  func verifiedAccount(
    _ flight: NativeEpisodeServerSaveFlight,
    scope: NativeEpisodeServerSaveFenceScope,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveAccount {
    _ = try await verifyFence(flight, scope: scope, on: coordinator)
    return try await verifiedAccount(fence: flight.fence, on: coordinator)
  }

  /// The account half of `verifiedAccount(_:scope:on:)`, for a read that serves several attempts
  /// and so has no single flight to verify. An account that cannot be read counts as replaced.
  func verifiedAccount(
    fence: NativeEpisodeServerSaveAccountFence,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveAccount {
    do {
      let account = try await accountReader.currentAccount()
      guard Self.matchesFence(account, fence: fence) else {
        throw NativeEpisodeServerSaveFenceFailure.accountReplaced
      }
      return account
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      throw failure
    } catch {
      throw NativeEpisodeServerSaveFenceFailure.accountReplaced
    }
  }

  /// Reads `attemptID` and rebuilds its flight under the current account. A missing row throws
  /// `attemptNotFound` and an attempt owned by another account throws `accountReplaced`.
  func rebuildFlight(
    attemptID: Int64,
    command source: NativeEpisodeServerSaveFlightCommandSource,
    scope: NativeEpisodeServerSaveFenceScope,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveFlight {
    guard let attempt = try await attemptStore.fetchAttemptAsync(id: attemptID),
      attempt.id == attemptID
    else {
      throw NativeEpisodeServerSaveAttemptStoreError.attemptNotFound(attemptID)
    }
    guard
      let flight = try await rebuildFlight(
        for: attempt, command: source, scope: scope, on: coordinator)
    else {
      throw NativeEpisodeServerSaveFenceFailure.accountReplaced
    }
    return flight
  }

  /// Rebuilds the flight for an attempt the caller has already read. Returns `nil` when the
  /// attempt belongs to a different account than the current one, because each caller reports
  /// that case differently; every other failure is thrown as it arises.
  func rebuildFlight(
    for attempt: NativeEpisodeServerSaveAttemptRecord,
    command source: NativeEpisodeServerSaveFlightCommandSource,
    scope: NativeEpisodeServerSaveFenceScope,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveFlight? {
    let account = try await accountReader.currentAccount()
    let fence = NativeEpisodeServerSaveAccountFence(account: account)
    guard Self.matchesFence(attempt, fence: fence) else { return nil }
    let command: NativeEpisodeServerSaveCommand
    switch source {
    case .live:
      command = try await commandReader.read(feedId: attempt.feedId, episodeId: attempt.episodeId)
    case .durableIdentity:
      command = NativeEpisodeServerSaveSupport.commandForDurableIdentity(
        feedId: attempt.feedId,
        episodeId: attempt.episodeId,
        episodeIdentityKey: attempt.episodeIdentityKey)
    }
    let flight = NativeEpisodeServerSaveFlight(fence: fence, command: command, attempt: attempt)
    _ = try await verifyFence(flight, scope: scope, on: coordinator)
    return flight
  }

  func verifyFence(
    _ flight: NativeEpisodeServerSaveFlight,
    scope: NativeEpisodeServerSaveFenceScope,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    let record: NativeEpisodeServerSaveAttemptRecord
    do {
      guard let id = flight.attempt.id,
        let current = try await attemptStore.fetchAttemptAsync(id: id)
      else { throw NativeEpisodeServerSaveFenceFailure.persistence }
      guard Self.matchesFence(current, fence: flight.fence) else {
        throw NativeEpisodeServerSaveFenceFailure.accountReplaced
      }
      record = current
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      throw failure
    } catch let error as NativeEpisodeServerSaveAttemptStoreError {
      if Self.isAccountFenceError(error) { throw NativeEpisodeServerSaveFenceFailure.accountReplaced }
      throw NativeEpisodeServerSaveFenceFailure.persistence
    } catch {
      throw NativeEpisodeServerSaveFenceFailure.persistence
    }

    do {
      let currentAccount = try await accountReader.currentAccount()
      guard Self.matchesFence(currentAccount, fence: flight.fence) else {
        throw NativeEpisodeServerSaveFenceFailure.accountReplaced
      }
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      throw failure
    } catch {
      throw NativeEpisodeServerSaveFenceFailure.accountReplaced
    }

    guard scope != .account else { return record }
    guard await nativeSubscriptions.isEnabled() else {
      throw NativeEpisodeServerSaveFenceFailure.subscriptionsDisabled
    }
    guard scope == .source else { return record }
    do {
      let currentCommand = try await commandReader.read(
        feedId: flight.command.feedId, episodeId: flight.command.episodeId)
      guard currentCommand.episodeIdentityKey == flight.command.episodeIdentityKey else {
        throw NativeEpisodeServerSaveFenceFailure.episodeMissing
      }
    } catch let failure as NativeEpisodeServerSaveFenceFailure {
      throw failure
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      switch error {
      case .nativeSubscriptionsDisabled:
        throw NativeEpisodeServerSaveFenceFailure.subscriptionsDisabled
      case .feedNotFound, .episodeNotFound, .episodeNotInFeed:
        throw NativeEpisodeServerSaveFenceFailure.episodeMissing
      default:
        throw NativeEpisodeServerSaveFenceFailure.reader(error)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw NativeEpisodeServerSaveFenceFailure.persistence
    }
    return record
  }

  func accountStillMatches(
    _ expected: NativeEpisodeServerSaveAccount,
    on coordinator: isolated NativeEpisodeServerSaveCoordinator
  ) async -> Bool {
    do {
      let current = try await accountReader.currentAccount()
      return current.accountID == expected.accountID
        && current.clientUUID == expected.clientUUID
        && current.serverIdentityFingerprint == expected.serverIdentityFingerprint
        && current.tokenAccount == expected.tokenAccount
    } catch {
      return false
    }
  }

  static func matchesFence(
    _ record: NativeEpisodeServerSaveAttemptRecord,
    fence: NativeEpisodeServerSaveAccountFence
  ) -> Bool {
    record.accountId == fence.accountID
      && record.accountClientUUID == fence.clientUUID
      && record.accountServerIdentityFingerprint == fence.serverIdentityFingerprint
  }

  static func matchesFence(
    _ account: NativeEpisodeServerSaveAccount,
    fence: NativeEpisodeServerSaveAccountFence
  ) -> Bool {
    account.accountID == fence.accountID
      && account.clientUUID == fence.clientUUID
      && account.serverIdentityFingerprint == fence.serverIdentityFingerprint
  }

  static func isAccountFenceError(_ error: NativeEpisodeServerSaveAttemptStoreError) -> Bool {
    switch error {
    case .accountFenceMismatch, .accountNotFound:
      return true
    default:
      return false
    }
  }

  static func fenceCategory(
    _ failure: NativeEpisodeServerSaveFenceFailure
  ) -> NativeEpisodeServerSaveErrorCategory {
    switch failure {
    case .accountReplaced: return .accountReplaced
    case .subscriptionsDisabled: return .unsubscribed
    case .episodeMissing: return .missingEpisode
    case .reader(let error): return NativeEpisodeServerSaveSupport.readerCategory(error)
    case .persistence: return .localPersistence
    }
  }
}
