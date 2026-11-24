import Foundation
import GRDB

/// Rejections `SavedShelfStore.save` enforces while resolving a server-facing identity. Removal
/// uses a tombstone-tolerant lookup and does not apply these insertion-time checks.
public enum SavedShelfStoreError: Error, Equatable, Sendable {
  /// The supplied item belongs to another account, or no account-owned item has that server ID.
  /// For an episode identity, this also covers a missing or wrong-account parent item.
  case itemNotFound
  /// The item identity is a tombstone at insertion time. A validly saved row remains removable
  /// if the item is soft-deleted later; this rejection applies only to a new save.
  case itemSoftDeleted
  /// The episode identity is a tombstone at insertion time. A validly saved row remains removable
  /// if the episode is soft-deleted later; this rejection applies only to a new save.
  case episodeSoftDeleted
  /// An `.item` identity resolved to a podcast show. Podcast shows are not saveable as a whole;
  /// the podcast episode is the saved identity.
  case episodeIdentityRequired
  /// A `.podcastEpisode` identity resolved to an item whose established category is not podcast.
  /// eBooks remain saveable as `.item` identities; they are not episode identities.
  case episodeIdentityNotAllowed
  /// No episode in this account belongs to the supplied item with the supplied server episode ID.
  case episodeNotFound
}

/// What `SavedShelfStore.save` actually did. Saving an existing identity is an idempotent no-op
/// and does not refresh its `savedAt` timestamp.
public enum SavedShelfSaveOutcome: Sendable, Equatable {
  case saved
  case alreadySaved
}

public protocol SavedShelfStoring: Sendable {
  @discardableResult
  func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome
  func remove(_ identity: SavedShelfIdentity) async throws
}

/// One download a newly saved identity implies. An explicit list rather than a media capability
/// because SyncEngine may not import AppModel's `ItemMediaCapability` (ARCHITECTURE.md). The
/// medium resolution is a Persistence read over the same `mediaKind` / `numAudioFiles` /
/// `ebookFormat` signals every other category derivation uses.
public enum SavedShelfDownloadTarget: Sendable, Equatable, Hashable {
  case audio(itemID: String)
  case ebook(itemID: String)
  case episode(itemID: String, episodeID: String)
}

/// The one query the Saved for Later auto-download decorator needs, kept narrow like
/// `ListeningQueueDownloadCandidateReading`.
public protocol SavedShelfDownloadTargetReading: Sendable {
  /// The downloads `identity` implies, in request order. Empty when there is nothing to fetch (a
  /// document Whirr cannot open, or an identity this account has no row for).
  func downloadTargets(for identity: SavedShelfIdentity) async throws -> [SavedShelfDownloadTarget]
}

public struct NoOpSavedShelfStore: SavedShelfStoring, SavedShelfDownloadTargetReading, Sendable {
  public init() {}

  @discardableResult
  public func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    .saved
  }

  public func remove(_ identity: SavedShelfIdentity) async throws {}

  public func downloadTargets(for identity: SavedShelfIdentity) async throws
    -> [SavedShelfDownloadTarget]
  { [] }
}

/// The account-scoped Saved for Later write store. It resolves server-facing identities
/// to local item/episode row IDs inside each transaction and writes only `savedShelfEntry`.
public struct SavedShelfStore: SavedShelfStoring, SavedShelfDownloadTargetReading, Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase,
    accountId: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.accountId = accountId
    self.now = now
  }

  @discardableResult
  public func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    if case .rssEpisode = identity {
      return try await NativeSavedShelfStore(database: database, now: now).save(identity)
    }
    return try await database.writeAsync { db in
      let resolved = try Self.resolveForInsertion(db, accountId: accountId, identity: identity)
      guard
        try Self.entry(
          db, accountId: accountId, itemId: resolved.itemId,
          podcastEpisodeId: resolved.podcastEpisodeId) == nil
      else {
        return .alreadySaved
      }

      var row = SavedShelfEntryRecord(
        accountId: accountId, itemId: resolved.itemId,
        podcastEpisodeId: resolved.podcastEpisodeId,
        savedAt: now(), subjectTitle: resolved.subjectTitle, contextTitle: resolved.contextTitle
      )
      try row.insert(db)
      return .saved
    }
  }

  public func remove(_ identity: SavedShelfIdentity) async throws {
    if case .rssEpisode = identity {
      try await NativeSavedShelfStore(database: database, now: now).remove(identity)
      return
    }
    try await database.writeAsync { db in
      guard
        let resolved = try Self.resolveTolerantOfTombstone(
          db, accountId: accountId, identity: identity),
        let row = try Self.entry(
          db, accountId: accountId, itemId: resolved.itemId,
          podcastEpisodeId: resolved.podcastEpisodeId)
      else {
        return
      }
      _ = try row.delete(db)
    }
  }

  // MARK: - Download targets

  /// Mirrors `ItemMediaCapability.downloadFormats`' audio-first order for a mixed item, and its
  /// empty answer for a document Whirr cannot open. A `.podcast` item reached through an `.item`
  /// identity is not a saveable shape (`save` rejects it), so it resolves to nothing rather than
  /// requesting a whole show.
  public func downloadTargets(for identity: SavedShelfIdentity) async throws
    -> [SavedShelfDownloadTarget]
  {
    try await database.readAsync { db in
      switch identity {
      case .item(let itemID):
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT mediaKind, numAudioFiles, ebookFormat
              FROM item
              WHERE accountId = ? AND serverItemId = ?
              """,
            arguments: [accountId, itemID])
        else {
          return []
        }
        let ebookFormat: String? = row["ebookFormat"]
        let category = ItemMediaCategory.derive(
          mediaKind: row["mediaKind"], numAudioFiles: row["numAudioFiles"],
          ebookFormat: ebookFormat)
        let hasReadableEbook = ItemMediaCategory.hasReadableEbook(ebookFormat: ebookFormat)
        switch category {
        case .podcast:
          return []
        case .audiobook:
          var targets: [SavedShelfDownloadTarget] = [.audio(itemID: itemID)]
          if hasReadableEbook {
            targets.append(.ebook(itemID: itemID))
          }
          return targets
        case .ebook:
          return hasReadableEbook ? [.ebook(itemID: itemID)] : []
        }

      case .podcastEpisode(let itemID, let episodeID):
        let exists =
          try Int64.fetchOne(
            db,
            sql: """
              SELECT episode.id
              FROM item
              JOIN podcastEpisode AS episode
                ON episode.itemId = item.id AND episode.accountId = item.accountId
              WHERE item.accountId = ?
                AND item.serverItemId = ?
                AND episode.serverEpisodeId = ?
              LIMIT 1
              """,
            arguments: [accountId, itemID, episodeID]) != nil
        return exists ? [.episode(itemID: itemID, episodeID: episodeID)] : []

      case .rssEpisode(let itemID, let episodeID):
        // The serialized RSS item id is the same identity `requestEpisodeDownload` dispatches
        // on, so an `.episode` target reaches the device-owned RSS planner unchanged. The
        // `rssEpisode` table is feed-scoped, not account-scoped, so the lookup omits `accountId`.
        guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return [] }
        let exists =
          try Int64.fetchOne(
            db,
            sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ? LIMIT 1",
            arguments: [feedID, episodeID]) != nil
        return exists ? [.episode(itemID: itemID, episodeID: episodeID)] : []
      }
    }
  }

  // MARK: - Resolution

  /// Applies every insertion-time rejection rule. eBooks fall through as valid
  /// whole-item identities; unlike the queue, Saved for Later has no ebook rejection.
  private static func resolveForInsertion(
    _ db: Database, accountId: Int64, identity: SavedShelfIdentity
  ) throws -> (
    itemId: Int64?, podcastEpisodeId: Int64?, rssEpisodeId: Int64?, subjectTitle: String,
    contextTitle: String?
  ) {
    if case .rssEpisode(let itemID, let episodeID) = identity {
      guard
        let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId,
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT episode.id, episode.title, feed.title AS feedTitle
            FROM rssEpisode AS episode
            JOIN rssFeed AS feed ON feed.id = episode.feedId
            WHERE episode.feedId = ? AND episode.identityKey = ?
            LIMIT 1
            """,
          arguments: [feedID, episodeID])
      else {
        throw SavedShelfStoreError.episodeNotFound
      }
      let rssEpisodeId: Int64 = row["id"]
      return (
        nil, nil, rssEpisodeId, (row["title"] as String?) ?? "", row["feedTitle"] as String?
      )
    }

    let itemID: String
    switch identity {
    case .item(let value), .podcastEpisode(let value, _): itemID = value
    case .rssEpisode: preconditionFailure("RSS identities resolve before ABS item lookup")
    }
    let itemRow = try Self.fetchItemRow(db, accountId: accountId, itemID: itemID)
    let itemId: Int64 = itemRow["id"]
    let category = ItemMediaCategory.derive(
      mediaKind: itemRow["mediaKind"], numAudioFiles: itemRow["numAudioFiles"],
      ebookFormat: itemRow["ebookFormat"])

    switch identity {
    case .item:
      guard category != .podcast else {
        throw SavedShelfStoreError.episodeIdentityRequired
      }
      return (itemId, nil, nil, itemRow["title"], nil)

    case .podcastEpisode(_, let episodeID):
      guard category == .podcast else {
        throw SavedShelfStoreError.episodeIdentityNotAllowed
      }
      guard
        let episodeRow = try Row.fetchOne(
          db,
          sql: """
            SELECT id, title, softDeleted
            FROM podcastEpisode
            WHERE accountId = ? AND itemId = ? AND serverEpisodeId = ?
            """,
          arguments: [accountId, itemId, episodeID])
      else {
        throw SavedShelfStoreError.episodeNotFound
      }
      if episodeRow["softDeleted"] as Bool {
        throw SavedShelfStoreError.episodeSoftDeleted
      }
      let episodeId: Int64 = episodeRow["id"]
      return (itemId, episodeId, nil, episodeRow["title"], itemRow["title"])

    case .rssEpisode:
      preconditionFailure("RSS identities resolve before ABS item lookup")
    }
  }

  /// Resolves the parent item while rejecting only unknown/wrong-account and insertion-time item
  /// tombstones. Category validation is performed by `resolveForInsertion` after this lookup.
  private static func fetchItemRow(_ db: Database, accountId: Int64, itemID: String) throws -> Row {
    guard
      let itemRow = try Row.fetchOne(
        db,
        sql: """
          SELECT id, title, mediaKind, numAudioFiles, ebookFormat, softDeleted
          FROM item
          WHERE accountId = ? AND serverItemId = ?
          """,
        arguments: [accountId, itemID])
    else {
      throw SavedShelfStoreError.itemNotFound
    }
    if itemRow["softDeleted"] as Bool {
      throw SavedShelfStoreError.itemSoftDeleted
    }
    return itemRow
  }

  /// Resolves an identity without inspecting category or tombstone state. A missing row returns
  /// nil so removal remains idempotent even after hard deletion or for an unknown identity.
  private static func resolveTolerantOfTombstone(
    _ db: Database, accountId: Int64, identity: SavedShelfIdentity
  ) throws -> (itemId: Int64?, podcastEpisodeId: Int64?, rssEpisodeId: Int64?)? {
    switch identity {
    case .item(let itemID):
      guard
        let itemId = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM item WHERE accountId = ? AND serverItemId = ?",
          arguments: [accountId, itemID])
      else {
        return nil
      }
      return (itemId, nil, nil)

    case .podcastEpisode(let itemID, let episodeID):
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT item.id AS itemId, episode.id AS episodeId
            FROM item
            JOIN podcastEpisode AS episode
              ON episode.itemId = item.id AND episode.accountId = item.accountId
            WHERE item.accountId = ?
              AND item.serverItemId = ?
              AND episode.serverEpisodeId = ?
            LIMIT 1
            """,
          arguments: [accountId, itemID, episodeID]),
        let itemId = row["itemId"] as Int64?,
        let episodeId = row["episodeId"] as Int64?
      else {
        return nil
      }
      return (itemId, episodeId, nil)

    case .rssEpisode(let itemID, let episodeID):
      guard
        let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId,
        let rssEpisodeId = try Int64.fetchOne(
          db,
          sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedID, episodeID])
      else {
        return nil
      }
      return (nil, nil, rssEpisodeId)
    }
  }

  /// Finds one saved row by local identity. This query has no soft-delete joins so
  /// a row remains removable after either referenced identity becomes a tombstone.
  private static func entry(
    _ db: Database,
    accountId: Int64,
    itemId: Int64?,
    podcastEpisodeId: Int64?
  ) throws -> SavedShelfEntryRecord? {
    var request =
      SavedShelfEntryRecord
      .filter(SavedShelfEntryRecord.Columns.accountId == accountId)
    request = request.filter(SavedShelfEntryRecord.Columns.itemId == itemId)
    if let podcastEpisodeId {
      request = request.filter(SavedShelfEntryRecord.Columns.podcastEpisodeId == podcastEpisodeId)
    } else {
      request = request.filter(SavedShelfEntryRecord.Columns.podcastEpisodeId == nil)
    }
    return try request.fetchOne(db)
  }
}
