import Foundation
import GRDB

public enum AudioBookmarkStoreError: Error, Equatable, Sendable {
  /// The server rejects an empty title, so one made only of whitespace is refused here.
  case emptyTitle
  /// A bookmark time must be a finite number of seconds, zero or more.
  case invalidTime
  /// The item id is empty or names a device-owned RSS item, which the server cannot address.
  case invalidItem
}

/// The outcome of a create.
public enum AudioBookmarkCreation: Sendable, Equatable {
  case created(AudioBookmark)
  /// An existing bookmark on the same item lies less than `AudioBookmarkStore.minimumSpacing`
  /// away, so nothing was written. This matches the web client's rule and keeps two taps from
  /// making two bookmarks.
  case tooCloseToExisting(AudioBookmark)
}

/// The account's Audiobookshelf audio bookmarks.
///
/// Each listener intent writes the `audioBookmark` change and its outbox row in one transaction.
/// A pull applies the server's list around every bookmark with an unacknowledged intent, so a
/// snapshot taken before the intent reached the server cannot undo it.
public struct AudioBookmarkStore: Sendable {
  /// Seconds within which a new bookmark is refused on an item that already has one.
  public static let minimumSpacing: Double = 1

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Reads

  /// One item's bookmarks, earliest first.
  public func bookmarks(accountId: Int64, serverItemId: String) throws -> [AudioBookmark] {
    try database.read { db in
      try Self.fetchBookmarks(db, accountId: accountId, serverItemId: serverItemId)
    }
  }

  /// One item's bookmarks, earliest first, re-emitted on every change.
  public func observeBookmarks(
    accountId: Int64, serverItemId: String
  ) -> AsyncStream<[AudioBookmark]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          try Self.fetchBookmarks(db, accountId: accountId, serverItemId: serverItemId)
        }
        .removeDuplicates())
  }

  private static func fetchBookmarks(
    _ db: Database, accountId: Int64, serverItemId: String
  ) throws -> [AudioBookmark] {
    try AudioBookmarkRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("serverItemId") == serverItemId)
      .order(Column("time"))
      .fetchAll(db)
      .map(AudioBookmark.init(record:))
  }

  // MARK: - Listener intents

  /// Adds a bookmark at `time` and queues its create, unless one already lies within
  /// `minimumSpacing` on the same item.
  public func create(
    accountId: Int64,
    serverItemId: String,
    time: Double,
    title: String,
    createdAt: Date,
    clientOperationId: @autoclosure () -> String = UUID().uuidString
  ) async throws -> AudioBookmarkCreation {
    let time = try Self.validated(time: time, serverItemId: serverItemId)
    let title = try Self.validated(title: title)
    let operationId = clientOperationId()
    return try await database.writeAsync { db in
      let nearby =
        try AudioBookmarkRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("serverItemId") == serverItemId)
        .filter(Column("time") > time - Self.minimumSpacing)
        .filter(Column("time") < time + Self.minimumSpacing)
        .order(Column("time"))
        .fetchOne(db)
      if let nearby {
        return .tooCloseToExisting(AudioBookmark(record: nearby))
      }
      let record = AudioBookmarkRecord(
        accountId: accountId, serverItemId: serverItemId, time: time, title: title,
        createdAt: createdAt)
      try record.insert(db)
      try OutboxStore.enqueueAudioBookmarkIntent(
        db, accountId: accountId, serverItemId: serverItemId, time: time,
        intent: .create(title: title), clientOperationId: operationId)
      return .created(AudioBookmark(record: record))
    }
  }

  /// Retitles a bookmark and queues the rename. Returns `false`, writing nothing, when the
  /// bookmark is not stored or already has this title.
  @discardableResult
  public func rename(
    accountId: Int64,
    serverItemId: String,
    time: Double,
    title: String,
    clientOperationId: @autoclosure () -> String = UUID().uuidString
  ) async throws -> Bool {
    let time = try Self.validated(time: time, serverItemId: serverItemId)
    let title = try Self.validated(title: title)
    let operationId = clientOperationId()
    return try await database.writeAsync { db in
      guard
        var record = try Self.fetchRecord(
          db, accountId: accountId, serverItemId: serverItemId, time: time),
        record.title != title
      else { return false }
      record.title = title
      try record.update(db)
      try OutboxStore.enqueueAudioBookmarkIntent(
        db, accountId: accountId, serverItemId: serverItemId, time: time,
        intent: .rename(title: title), clientOperationId: operationId)
      return true
    }
  }

  /// Removes a bookmark and queues the delete. Returns `false`, writing nothing, when the bookmark
  /// is not stored.
  @discardableResult
  public func delete(
    accountId: Int64,
    serverItemId: String,
    time: Double,
    clientOperationId: @autoclosure () -> String = UUID().uuidString
  ) async throws -> Bool {
    let time = try Self.validated(time: time, serverItemId: serverItemId)
    let operationId = clientOperationId()
    return try await database.writeAsync { db in
      guard
        let record = try Self.fetchRecord(
          db, accountId: accountId, serverItemId: serverItemId, time: time)
      else { return false }
      try record.delete(db)
      try OutboxStore.enqueueAudioBookmarkIntent(
        db, accountId: accountId, serverItemId: serverItemId, time: time,
        intent: .delete, clientOperationId: operationId)
      return true
    }
  }

  // MARK: - Pull

  /// Every bookmark whose listener intent the server has not yet acknowledged. A pull reads this
  /// before its fetch and passes it to `applyServerBookmarks`, which reads it again inside its
  /// transaction: an intent acknowledged while the fetch was in flight has left the second read
  /// but may be missing from the older snapshot, and only the first read still protects it.
  public func unacknowledgedKeys(accountId: Int64) async throws -> Set<AudioBookmarkKey> {
    try await database.readAsync { db in
      try OutboxStore.unacknowledgedAudioBookmarkKeys(db, accountId: accountId)
    }
  }

  /// Applies the server's bookmark list for the account.
  ///
  /// A complete list is authoritative: a stored bookmark the server no longer lists is removed. An
  /// incomplete one (an element failed to decode, or the key was missing) only adds and retitles,
  /// as a lossy read is no evidence of deletion. Either way, a bookmark in `protecting` or with an
  /// unacknowledged intent keeps its local state.
  public func applyServerBookmarks(
    accountId: Int64,
    _ serverBookmarks: [AudioBookmark],
    isComplete: Bool,
    protecting alsoProtected: Set<AudioBookmarkKey> = []
  ) async throws {
    try await database.writeAsync { db in
      let protected = try OutboxStore.unacknowledgedAudioBookmarkKeys(db, accountId: accountId)
        .union(alsoProtected)
      var serverByKey: [AudioBookmarkKey: AudioBookmark] = [:]
      for bookmark in serverBookmarks where bookmark.serverItemID.isEmpty == false {
        serverByKey[bookmark.id] = bookmark
      }

      if isComplete {
        let stored = try AudioBookmarkRecord.filter(Column("accountId") == accountId).fetchAll(db)
        for record in stored {
          let key = AudioBookmarkKey(serverItemID: record.serverItemId, time: record.time)
          guard serverByKey[key] == nil, protected.contains(key) == false else { continue }
          try record.delete(db)
        }
      }

      for (key, bookmark) in serverByKey where protected.contains(key) == false {
        if var existing = try Self.fetchRecord(
          db, accountId: accountId, serverItemId: key.serverItemID, time: key.time)
        {
          // The server never changes a bookmark's `createdAt`, and a stored date read back from
          // SQLite is not bit-identical to a freshly decoded one, so only the title (or a missing
          // date) decides whether this pull writes the row.
          guard
            existing.title != bookmark.title
              || (existing.createdAt == nil && bookmark.createdAt != nil)
          else { continue }
          existing.title = bookmark.title
          existing.createdAt = existing.createdAt ?? bookmark.createdAt
          try existing.update(db)
        } else {
          try AudioBookmarkRecord(
            accountId: accountId, serverItemId: key.serverItemID, time: key.time,
            title: bookmark.title, createdAt: bookmark.createdAt
          ).insert(db)
        }
      }
    }
  }

  // MARK: - Helpers

  private static func fetchRecord(
    _ db: Database, accountId: Int64, serverItemId: String, time: Double
  ) throws -> AudioBookmarkRecord? {
    try AudioBookmarkRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("serverItemId") == serverItemId)
      .filter(Column("time") == time)
      .fetchOne(db)
  }

  private static func validated(time: Double, serverItemId: String) throws -> Double {
    guard serverItemId.isEmpty == false,
      PodcastSourceIdentity.hasReservedPrefix(serverItemId) == false
    else { throw AudioBookmarkStoreError.invalidItem }
    guard time.isFinite, time >= 0 else { throw AudioBookmarkStoreError.invalidTime }
    return AudioBookmark.normalizedTime(time)
  }

  private static func validated(title: String) throws -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { throw AudioBookmarkStoreError.emptyTitle }
    return trimmed
  }
}
