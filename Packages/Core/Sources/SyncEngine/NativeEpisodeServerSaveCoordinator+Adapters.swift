import ABSApi
import Foundation
import Persistence

public struct PersistenceNativeEpisodeServerSaveAccountReader:
  NativeEpisodeServerSaveAccountReading, Sendable
{
  private let accountDAO: AccountDAO

  public init(database: AppDatabase) {
    accountDAO = AccountDAO(database: database)
  }

  public func currentAccount() async throws -> NativeEpisodeServerSaveAccount {
    let record: AccountRecord?
    do {
      record = try await accountDAO.fetchAsync()
    } catch {
      throw NativeEpisodeServerSaveAccountReadingError.unavailable
    }
    guard let record else {
      throw NativeEpisodeServerSaveAccountReadingError.notAuthenticated
    }
    guard let accountID = record.id else {
      throw NativeEpisodeServerSaveAccountReadingError.notAuthenticated
    }
    guard record.clientUUID.isEmpty == false,
      record.serverBaseURL.isEmpty == false,
      record.serverUserId.isEmpty == false
    else {
      throw NativeEpisodeServerSaveAccountReadingError.malformedAccount
    }

    let tokenAccount: TokenAccount
    do {
      tokenAccount = try record.credentialTokenAccount
    } catch {
      throw NativeEpisodeServerSaveAccountReadingError.malformedAccount
    }
    return NativeEpisodeServerSaveAccount(
      accountID: accountID,
      clientUUID: record.clientUUID,
      serverIdentityFingerprint:
        record.serverIdentityFingerprint,
      tokenAccount: tokenAccount)
  }
}

extension NativeEpisodeServerSaveAttemptStore: NativeEpisodeServerSaveAttemptStoring {
  /// The concrete store declares extra defaulted parameters, so it does not itself witness the
  /// four-argument requirement. Without this shim the conformance binds to the source-compatible
  /// protocol extension, which re-enters `.deleteUncertain` as an illegal self-transition and
  /// never applies the account fence.
  public func markRemovalConvergencePendingAsync(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    errorCategory: NativeEpisodeServerSaveErrorCategory
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await markRemovalConvergencePendingAsync(
      attemptId: attemptId, serverItemId: serverItemId, accountId: accountId,
      errorCategory: errorCategory, now: Date())
  }

  public func confirmPreExistingAsync(
    attemptId: Int64,
    serverItemId: String,
    serverEpisodeId: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await confirmPreExistingAsync(
      attemptId: attemptId, serverItemId: serverItemId, serverEpisodeId: serverEpisodeId,
      now: Date())
  }

  public func beginAttemptAsync(
    accountId: Int64,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await beginAttemptAsync(
      accountId: accountId, feedId: feedId, episodeId: episodeId,
      episodeIdentityKey: episodeIdentityKey,
      alternateEpisodeIdentityKeys: [], preflightPresence: nil, now: Date())
  }

  public func transitionAsync(
    attemptId: Int64,
    to newState: NativeEpisodeServerSaveAttemptState,
    serverItemId: String?,
    errorCategory: NativeEpisodeServerSaveErrorCategory?
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await transitionAsync(
      attemptId: attemptId, to: newState, serverItemId: serverItemId,
      errorCategory: errorCategory, now: Date())
  }

  public func transitionToRemovedApplyingReconciliation(
    attemptId: Int64,
    serverItemId: String,
    accountId: Int64,
    episodes: [PodcastEpisodeRecord]?,
    refreshedAt: Date
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await transitionToRemovedApplyingReconciliation(
      attemptId: attemptId, serverItemId: serverItemId, accountId: accountId, episodes: episodes,
      refreshedAt: refreshedAt, now: Date())
  }

  public func recordServerItemIDAsync(
    _ serverItemId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await recordServerItemIDAsync(
      serverItemId, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
  }

  public func recordServerEpisodeIDAsync(
    _ serverEpisodeId: String,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await recordServerEpisodeIDAsync(
      serverEpisodeId, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
  }

  public func recordPreflightPresenceAsync(
    _ presence: NativeEpisodeServerSavePreflightPresence,
    attemptId: Int64
  ) async throws -> NativeEpisodeServerSaveAttemptRecord {
    try await recordPreflightPresenceAsync(
      presence, attemptId: attemptId, now: Date(), updatingLocalState: { _ in })
  }
}

extension ServerPodcastDestinationResolver: NativeEpisodeServerSaveDestinationResolving {}
extension ABSClient: NativeEpisodeServerSavePodcastWriting {}
extension ABSClient: NativeEpisodeServerSaveItemDetailReading {}
