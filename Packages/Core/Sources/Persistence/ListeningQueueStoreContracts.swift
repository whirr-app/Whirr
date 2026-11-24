import Foundation

/// Rejections `ListeningQueueStore.append`/`insertNext` enforce at resolve time, plus the
/// restore-only failures `restore(token:)` can throw.
public enum ListeningQueueStoreError: Error, Equatable, Sendable {
  /// The supplied `itemID` belongs to another account, or no account owns it at all. The store
  /// does not distinguish the two.
  case itemNotFound
  /// The item exists but is currently a tombstone. Soft deletion is reversible, so an identity
  /// that was valid when queued stays queued as a tombstone. This rejection fires only on
  /// insertion.
  case itemSoftDeleted
  /// `ItemMediaCategory.derive` resolved `.ebook`. Chapters/ebooks are never queueable.
  case ebookNotQueueable
  /// A `.podcastEpisode` identity where `derive` resolved `.audiobook` for that item.
  case episodeIdentityNotAllowed
  /// A `.audiobook` identity where `derive` resolved `.podcast` for that item.
  case episodeIdentityRequired
  /// No episode matches `episodeID` under the supplied item, or it belongs to a different item.
  case episodeNotFound
  /// `restore(token:)`: the token was minted for a different account.
  case restoreTokenWrongAccount
  /// `restore(token:)`: the live revision has moved past the token's. Some mutation (an edit, a
  /// second `clear()`, or an earlier use of this token) has happened since the `clear()` that
  /// minted it.
  case restoreTokenStale
  /// `restore(token:)`: one of the token's identities no longer resolves at all (its item or
  /// episode row is gone), so nothing is restored. All or nothing.
  case restoreIdentityUnavailable
  /// A chapter was supplied for an identity that is not an audiobook.
  case chapterNotAllowed
  /// A chapter whose bounds are not finite, start below zero, or do not end after they start.
  case chapterInvalid
}

/// A test-only seam inside the temporary-negative-position renumber, so a failure there can be
/// proven to roll back atomically (the pattern `PodcastShowOrdering` uses for its reorder).
enum ListeningQueueMutationCheckpoint: Sendable, Equatable {
  case afterTemporaryRenumber
  case afterFinalRenumber
}

/// An opaque snapshot `clear()` returns: the ordered rows it removed (each identity and the
/// chapter it carried), plus the account revision as of that clear. Not `Codable` and never persisted, so a force-quit after `clear()`
/// commits the clear and the restore option is gone next launch. Every stored property is
/// non-public so nothing above Persistence can inspect or construct one; only `restore(token:)`
/// consumes it.
public struct ListeningQueueRestoreToken: Sendable, Equatable {
  let accountId: Int64?
  let revision: Int64
  let entries: [Entry]

  struct Entry: Sendable, Equatable {
    let identity: ListeningIdentity
    let chapter: ListeningQueueChapter?
    /// Kept so Undo restores a hand removal's decline with the entry.
    let downloadDeclinedAt: Date?
  }
}

/// What `append` did. Appending an identity already queued is an idempotent no-op, and a caller
/// that assumed success would tell the listener it had added something the queue already held,
/// so the outcomes are reported rather than collapsed into `Void`.
public enum ListeningQueueAppendOutcome: Sendable, Equatable {
  case appended
  case alreadyQueued
  /// The book was already queued with a different extent (another chapter, or the whole book
  /// against a chapter); its row now carries the requested one, where it sat.
  case replaced
}

public protocol ListeningQueueReading: Sendable {
  func observeQueue() -> AsyncStream<[ListeningQueueItem]>
}

/// The start of Up Next for a surface that shows a few rows and never edits the order. Tombstones
/// are left out in SQL, before the limit, so a removed item at the head cannot empty the list;
/// each row keeps its durable `position`.
public protocol ListeningQueuePrefixReading: Sendable {
  func observeLiveQueue(limit: Int) -> AsyncStream<[ListeningQueueItem]>
}

/// The one query the Up Next auto-download reconciler needs. Persistence performs the identity
/// and download-row join so SyncEngine never fetches the whole queue and every download file into
/// memory just to find missing identities.
public protocol ListeningQueueDownloadCandidateReading: Sendable {
  /// Leaves out entries whose download the listener removed by hand.
  func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity]
}

/// Whether the listener removed a queued entry's download by hand. Download Up Next asks just
/// before each request, because its candidates may be read before a hand removal lands.
public protocol ListeningQueueDownloadDeclineReading: Sendable {
  func isDownloadDeclined(_ identity: ListeningIdentity) async throws -> Bool
}

public protocol ListeningQueueStoring: Sendable {
  /// `chapter` limits an audiobook row to one chapter; `nil` queues the whole title. A book is
  /// queued whole or as chapters, never both: the whole book replaces its chapter rows
  /// and a chapter a whole-book row (`.replaced`); another chapter is a row of its own.
  @discardableResult
  func append(
    identity: ListeningIdentity, chapter: ListeningQueueChapter?
  ) async throws -> ListeningQueueAppendOutcome
  /// Moves the extent's row to the front, or inserts it there, under the same rule as `append`.
  func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws
  /// Puts `identities` at the front of Up Next in the given order, in one transaction. A queued
  /// identity is moved into its place as `insertNext(identity:)` would; a repeat inside the batch
  /// keeps its first position. An identity the store would reject with a
  /// `ListeningQueueStoreError` is skipped and returned (input order) while the rest commit;
  /// any other error rolls everything back and throws.
  @discardableResult
  func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity]
  /// Every row of the title, whole-book and chapter alike: the title was marked finished.
  func remove(identity: ListeningIdentity) async throws
  /// The one row `ListeningQueueItem.id` names, a no-op when absent.
  func remove(rowID: Int64) async throws
  func move(rowID: Int64, to position: Int) async throws
  func clear() async throws -> ListeningQueueRestoreToken
  func restore(token: ListeningQueueRestoreToken) async throws
  /// The first non-tombstoned row, left in place. A tombstone is a reversible soft deletion and
  /// still explicit user intent, so completion skips it rather than consuming a row the user
  /// never withdrew. Sync may revive the item later.
  func peekNextLive() async -> ListeningQueueItem?
  /// Idempotent removal, from wherever they sit, of the title's whole-book or episode row and,
  /// when `rowID` names one, the started chapter row. The book's other chapter rows stay. Every
  /// successful playback start, manual or automatic, routes through this call.
  func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws
  /// `acknowledgeStarted(identity:rowID:)` for a swap, returning `displaced` (the title the start
  /// replaced) to the front of Up Next in the same transaction. True when it is now first; a
  /// title the queue refuses, or a book whose chapter rows are queued, is not returned.
  @discardableResult
  func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool
}

extension ListeningQueueStoring {
  @discardableResult
  public func append(identity: ListeningIdentity) async throws -> ListeningQueueAppendOutcome {
    try await append(identity: identity, chapter: nil)
  }

  public func insertNext(identity: ListeningIdentity) async throws {
    try await insertNext(identity: identity, chapter: nil)
  }
}

public struct NoOpListeningQueueStore: ListeningQueueReading, ListeningQueuePrefixReading,
  ListeningQueueDownloadCandidateReading, ListeningQueueStoring, Sendable
{
  public init() {}
  public func observeQueue() -> AsyncStream<[ListeningQueueItem]> { AsyncStream { $0.finish() } }
  public func observeLiveQueue(limit: Int) -> AsyncStream<[ListeningQueueItem]> {
    AsyncStream { $0.finish() }
  }
  public func fetchQueueIdentitiesWithoutDownloads() async throws -> [ListeningIdentity] { [] }
  @discardableResult
  public func append(
    identity: ListeningIdentity, chapter: ListeningQueueChapter?
  ) async throws -> ListeningQueueAppendOutcome {
    .appended
  }
  public func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {}
  @discardableResult
  public func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] { [] }
  public func remove(identity: ListeningIdentity) async throws {}
  public func remove(rowID: Int64) async throws {}
  public func move(rowID: Int64, to position: Int) async throws {}
  public func clear() async throws -> ListeningQueueRestoreToken {
    ListeningQueueRestoreToken(accountId: 0, revision: 0, entries: [])
  }
  public func restore(token: ListeningQueueRestoreToken) async throws {}
  public func peekNextLive() async -> ListeningQueueItem? { nil }
  public func acknowledgeStarted(identity: ListeningIdentity, rowID: Int64?) async throws {}
  public func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool { false }
}
