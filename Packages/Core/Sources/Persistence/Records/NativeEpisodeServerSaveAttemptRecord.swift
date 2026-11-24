import Foundation
import GRDB

/// Durable lifecycle for one explicit copy of a device-owned RSS episode to Audiobookshelf.
/// `accepted` means only that the server accepted an enqueue request; `confirmed` requires a
/// later complete catalogue observation. The state names mirror the recovery
/// contract rather than pretending the server queue is durable.
public enum NativeEpisodeServerSaveAttemptState: String, Codable, Sendable, Equatable,
  CaseIterable, DatabaseValueConvertible
{
  case preparing
  case creatingShow
  case createUncertain
  case requestingDownload
  case accepted
  case confirmed
  case deleting
  case removed
  case deleteUncertain
  case deleteFailed
  case uncertain
  case failed
}

/// Evidence captured before an enqueue request. Only a complete preflight response can establish
/// either value; nil means the operation has not yet passed that gate.
public enum NativeEpisodeServerSavePreflightPresence: String, Codable, Sendable, Equatable,
  DatabaseValueConvertible
{
  case preExisting
  case absentBeforeRequest
}

/// Closed, privacy-safe categories for an attempt's user-facing/recovery state. Raw transport
/// messages, URLs, credentials, paths, and server response bodies are never stored.
public enum NativeEpisodeServerSaveErrorCategory: String, Codable, Sendable, Equatable,
  CaseIterable, DatabaseValueConvertible
{
  case invalidDestination
  case permissionChanged
  case staleIdentity
  case transport
  case serverFailure
  case malformedResponse
  case cancelled
  case credentialedFeed
  case unsubscribed
  case missingEpisode
  case incompleteEpisodeList
  case localPersistence
  case accountReplaced
  case unknown

  // Descriptive aliases keep mapping code readable without adding another persisted value.
  public static var permission: Self { .permissionChanged }
  public static var validation: Self { .invalidDestination }
  public static var privateFeed: Self { .credentialedFeed }
}

/// One account-owned NP12 operation. `feedId`, `episodeId`, and `episodeIdentityKey` are copied
/// identity values, not relationships to RSS tables. In particular, deleting/pruning an RSS row
/// cannot delete the operation or make its state machine unreadable during reconciliation.
public struct NativeEpisodeServerSaveAttemptRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "nativeEpisodeServerSaveAttempt"

  public var id: Int64?
  public var accountId: Int64
  public var accountClientUUID: String
  public var accountServerIdentityFingerprint: String
  public var feedId: Int64
  public var episodeId: Int64
  public var episodeIdentityKey: String
  public var serverItemId: String?
  public var serverEpisodeId: String?
  public var preflightPresence: NativeEpisodeServerSavePreflightPresence?
  public var state: NativeEpisodeServerSaveAttemptState
  public var errorCategory: NativeEpisodeServerSaveErrorCategory?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: Int64? = nil,
    accountId: Int64,
    accountClientUUID: String,
    accountServerIdentityFingerprint: String,
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    serverItemId: String? = nil,
    serverEpisodeId: String? = nil,
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil,
    state: NativeEpisodeServerSaveAttemptState = .preparing,
    errorCategory: NativeEpisodeServerSaveErrorCategory? = nil,
    createdAt: Date,
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.accountClientUUID = accountClientUUID
    self.accountServerIdentityFingerprint = accountServerIdentityFingerprint
    self.feedId = feedId
    self.episodeId = episodeId
    self.episodeIdentityKey = episodeIdentityKey
    self.serverItemId = serverItemId
    self.serverEpisodeId = serverEpisodeId
    self.preflightPresence = preflightPresence
    self.state = state
    self.errorCategory = errorCategory
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  /// Whether this attempt is an older change than `other` for the same episode. This is the one
  /// latest-attempt order: the store's live observation and the projection's pull path both use
  /// it, so they cannot disagree about which attempt is current. A later `updatedAt` wins, and a
  /// coincident one falls to the later row id, never to fetch order.
  public func isOlder(than other: NativeEpisodeServerSaveAttemptRecord) -> Bool {
    if updatedAt != other.updatedAt { return updatedAt < other.updatedAt }
    return (id ?? Int64.min) < (other.id ?? Int64.min)
  }
}
