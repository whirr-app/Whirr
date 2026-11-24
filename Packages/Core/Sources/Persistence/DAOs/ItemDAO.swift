import Foundation
import GRDB

/// Minimal read/write access to `ItemRecord` rows, keyed by the schema's identity
/// `(libraryId, serverItemId)`. DTO mapping and deletion inference live in SyncEngine; this DAO
/// exposes only the fetch/upsert/browse primitives.
public struct ItemDAO: Sendable {
  public struct ServerItemKind: Sendable, Equatable {
    public let serverItemId: String
    public let mediaKind: String
    public let hasServerArtwork: Bool?
    /// The item's server `updatedAt`: the revision of its ABS cover (see `ItemSummary`).
    public let serverUpdatedAt: Date?

    public init(
      serverItemId: String, mediaKind: String, hasServerArtwork: Bool? = nil,
      serverUpdatedAt: Date? = nil
    ) {
      self.serverItemId = serverItemId
      self.mediaKind = mediaKind
      self.hasServerArtwork = hasServerArtwork
      self.serverUpdatedAt = serverUpdatedAt
    }
  }

  public struct MetadataCensus: Sendable, Equatable {
    public let covered: Int
    public let total: Int

    public init(covered: Int, total: Int) {
      self.covered = covered
      self.total = total
    }
  }

  public struct PreservedMetadata: Sendable {
    public let addedAt: Date?
    public let seriesName: String?
    public let narratorName: String?
    public let expandedMetadataFetchedAt: Date?
    public let itemDescription: String?
    public let ebookFileIno: String?
    public let ebookFileExt: String?
    public let audioDownloadExpectedBytes: Int64?
    public let ebookDownloadExpectedBytes: Int64?
    /// The last authoritative podcast episode count. A minified library summary may omit this
    /// field (or carry an invalid negative value), in which case SyncEngine must retain it.
    public let podcastServerEpisodeCount: Int?
    /// The last valid server podcast feed identity. A minified summary may omit this field, in
    /// which case SyncEngine preserves it; malformed persisted values fail open as nil.
    public let podcastFeedFingerprint: String?
    /// The last known show language. A minified summary may omit this field, in which case
    /// SyncEngine preserves it.
    public let podcastLanguage: String?
    public let hasServerArtwork: Bool?
    /// The read-only podcast diagnostics, written only by the expanded show refresh. A minified
    /// summary never carries them, so SyncEngine must retain them across a traversal.
    public let podcastAutoDownloadEpisodes: Bool?
    public let podcastAutoDownloadSchedule: String?
    public let podcastLastEpisodeCheck: Date?
    public let podcastMaxEpisodesToKeep: Int?
    public let podcastMaxNewEpisodesToDownload: Int?

    public init(
      addedAt: Date?, seriesName: String?, narratorName: String?, expandedMetadataFetchedAt: Date?,
      itemDescription: String?, ebookFileIno: String?, ebookFileExt: String?,
      audioDownloadExpectedBytes: Int64?, ebookDownloadExpectedBytes: Int64?,
      hasServerArtwork: Bool?, podcastServerEpisodeCount: Int? = nil,
      podcastFeedFingerprint: String? = nil, podcastLanguage: String? = nil,
      podcastAutoDownloadEpisodes: Bool? = nil, podcastAutoDownloadSchedule: String? = nil,
      podcastLastEpisodeCheck: Date? = nil, podcastMaxEpisodesToKeep: Int? = nil,
      podcastMaxNewEpisodesToDownload: Int? = nil
    ) {
      self.addedAt = addedAt
      self.seriesName = seriesName
      self.narratorName = narratorName
      self.expandedMetadataFetchedAt = expandedMetadataFetchedAt
      self.itemDescription = itemDescription
      self.ebookFileIno = ebookFileIno
      self.ebookFileExt = ebookFileExt
      self.audioDownloadExpectedBytes = audioDownloadExpectedBytes
      self.ebookDownloadExpectedBytes = ebookDownloadExpectedBytes
      self.podcastServerEpisodeCount = podcastServerEpisodeCount
      self.podcastFeedFingerprint = podcastFeedFingerprint
      self.podcastLanguage = podcastLanguage
      self.hasServerArtwork = hasServerArtwork
      self.podcastAutoDownloadEpisodes = podcastAutoDownloadEpisodes
      self.podcastAutoDownloadSchedule = podcastAutoDownloadSchedule
      self.podcastLastEpisodeCheck = podcastLastEpisodeCheck
      self.podcastMaxEpisodesToKeep = podcastMaxEpisodesToKeep
      self.podcastMaxNewEpisodesToDownload = podcastMaxNewEpisodesToDownload
    }
  }

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchOne(libraryId: Int64, serverItemId: String) throws -> ItemRecord? {
    try database.read { db in
      try ItemRecord
        .filter(Column("libraryId") == libraryId)
        .filter(Column("serverItemId") == serverItemId)
        .fetchOne(db)
    }
  }

  public func fetchOneAsync(libraryId: Int64, serverItemId: String) async throws -> ItemRecord? {
    try await database.readAsync { db in
      try ItemRecord
        .filter(Column("libraryId") == libraryId)
        .filter(Column("serverItemId") == serverItemId)
        .fetchOne(db)
    }
  }

  public func preservedMetadataByServerItemIdAsync(
    libraryId: Int64, serverItemIds: [String]
  ) async throws -> [String: PreservedMetadata] {
    guard serverItemIds.isEmpty == false else { return [:] }
    return try await database.readAsync { db in
      let records =
        try ItemRecord
        .filter(Column("libraryId") == libraryId)
        .filter(serverItemIds.contains(Column("serverItemId")))
        .fetchAll(db)
      return Dictionary(
        uniqueKeysWithValues: records.map { record in
          (
            record.serverItemId,
            PreservedMetadata(
              addedAt: record.addedAt,
              seriesName: record.seriesName,
              narratorName: record.narratorName,
              expandedMetadataFetchedAt: record.expandedMetadataFetchedAt,
              itemDescription: record.itemDescription,
              ebookFileIno: record.ebookFileIno,
              ebookFileExt: record.ebookFileExt,
              audioDownloadExpectedBytes: record.audioDownloadExpectedBytes,
              ebookDownloadExpectedBytes: record.ebookDownloadExpectedBytes,
              hasServerArtwork: record.hasServerArtwork,
              podcastServerEpisodeCount: record.podcastServerEpisodeCount,
              podcastFeedFingerprint: PodcastFeedIdentity.validatedFingerprint(
                record.podcastFeedFingerprint),
              podcastLanguage: record.podcastLanguage,
              podcastAutoDownloadEpisodes: record.podcastAutoDownloadEpisodes,
              podcastAutoDownloadSchedule: record.podcastAutoDownloadSchedule,
              podcastLastEpisodeCheck: record.podcastLastEpisodeCheck,
              podcastMaxEpisodesToKeep: record.podcastMaxEpisodesToKeep,
              podcastMaxNewEpisodesToDownload: record.podcastMaxNewEpisodesToDownload)
          )
        })
    }
  }

  /// Book rows owed an expanded fetch: never fetched, or fetched before the server's own record
  /// last changed. The second half keeps the expanded fields correctable: only
  /// `ExpandedMetadataBatchStore` writes them, so a row fetched once would hold its first answer
  /// forever, including the ebook file identity a download is planned from. `serverUpdatedAt` is
  /// the minified traversal's change signal; rows the server never dated are left alone.
  public func serverItemIdsNeedingExpandedMetadataAsync(
    accountId: Int64, limit: Int
  ) async throws -> [String] {
    guard limit > 0 else { return [] }
    return try await database.readAsync { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT item.serverItemId
          FROM item
          JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
          WHERE item.accountId = ?
            AND \(ItemVisibilityPredicate.sql)
            AND item.mediaKind != ?
            AND (
              item.expandedMetadataFetchedAt IS NULL
              OR (
                item.serverUpdatedAt IS NOT NULL
                AND item.serverUpdatedAt > item.expandedMetadataFetchedAt
              )
            )
          ORDER BY item.sortTitle, item.serverItemId
          LIMIT ?
          """,
        arguments: [accountId, ItemMediaCategory.podcast.rawValue, limit])
    }
  }

  public func expandedMetadataCensusAsync(accountId: Int64) async throws -> MetadataCensus {
    try await database.readAsync { db in
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT COUNT(item.expandedMetadataFetchedAt) AS covered, COUNT(item.id) AS total
          FROM item
          JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
          WHERE item.accountId = ?
            AND \(ItemVisibilityPredicate.sql)
            AND item.mediaKind != ?
          """,
        arguments: [accountId, ItemMediaCategory.podcast.rawValue])
      let covered: Int = row?["covered"] ?? 0
      let total: Int = row?["total"] ?? 0
      return MetadataCensus(covered: covered, total: total)
    }
  }

  public func allServerItemIdsAsync(accountId: Int64) async throws -> [String] {
    try await database.readAsync { db in
      try Self.liveItems(accountId: accountId)
        .order(Column("sortTitle"), Column("serverItemId"))
        .select(Column("serverItemId"), as: String.self)
        .fetchAll(db)
    }
  }

  /// The same account-wide live set as `allServerItemIdsAsync`, retaining only the media-kind
  /// signal needed by callers whose work differs for podcast shows. Keeping this projection in
  /// Persistence avoids making those callers fetch full item records or re-query every id.
  public func allServerItemKindsAsync(accountId: Int64) async throws -> [ServerItemKind] {
    try await database.readAsync { db in
      let rows = try Self.liveItems(accountId: accountId)
        .order(Column("sortTitle"), Column("serverItemId"))
        .select(
          Column("serverItemId"), Column("mediaKind"), Column("hasServerArtwork"),
          Column("serverUpdatedAt"), as: Row.self
        )
        .fetchAll(db)
      return rows.map {
        ServerItemKind(
          serverItemId: $0["serverItemId"], mediaKind: $0["mediaKind"],
          hasServerArtwork: $0["hasServerArtwork"], serverUpdatedAt: $0["serverUpdatedAt"])
      }
    }
  }

  /// The account-wide live set whose server artwork is present or unknown. Only an explicit false
  /// is excluded; unknown rows still get one authoritative cover probe for older server payloads.
  public func serverItemKindsEligibleForArtworkAsync(accountId: Int64) async throws
    -> [ServerItemKind]
  {
    try await database.readAsync { db in
      try Self.includedLiveServerItemKinds(db: db, accountId: accountId).filter {
        $0.hasServerArtwork != false
      }
    }
  }

  /// The Library Cache's item universe. Unlike `allServerItemKindsAsync`, this is catalogue work,
  /// so it joins the owning library and never lets retained excluded-library rows affect coverage.
  private static func includedLiveServerItemKinds(
    db: Database, accountId: Int64
  ) throws -> [ServerItemKind] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId, item.mediaKind, item.hasServerArtwork, item.serverUpdatedAt
        FROM item
        JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
        WHERE item.accountId = ?
          AND \(ItemVisibilityPredicate.sql)
        ORDER BY item.sortTitle, item.serverItemId
        """,
      arguments: [accountId]
    ).map {
      ServerItemKind(
        serverItemId: $0["serverItemId"], mediaKind: $0["mediaKind"],
        hasServerArtwork: $0["hasServerArtwork"], serverUpdatedAt: $0["serverUpdatedAt"])
    }
  }

  /// Records an authoritative cover endpoint result. A later minified pull can restore `true` if
  /// artwork is added on the server after this device observed a 404.
  public func setHasServerArtworkAsync(
    _ hasServerArtwork: Bool, accountId: Int64, serverItemId: String
  ) async throws {
    try await database.writeAsync { db in
      try Self.liveItems(accountId: accountId)
        .filter(Column("serverItemId") == serverItemId)
        .updateAll(db, Column("hasServerArtwork").set(to: hasServerArtwork))
    }
  }

  /// Resolves an item by its local row id alone. `DownloadRecord.itemId` carries only this local
  /// FK, never the server item id string a `FileDownloadRequest` needs.
  public func fetchOne(id: Int64) throws -> ItemRecord? {
    try database.read { db in try ItemRecord.fetchOne(db, key: id) }
  }

  public func fetchOneAsync(id: Int64) async throws -> ItemRecord? {
    try await database.readAsync { db in try ItemRecord.fetchOne(db, key: id) }
  }

  /// Resolves an item by account + server item id alone, without an already-known library row id.
  /// A playback-session request only carries the server item id (the identity
  /// `LibraryReading.observeItemDetail`/`NavigationModel.Route.itemDetail` expose to the UI),
  /// never a library id. ABS library item ids are server-global, so scoping by `accountId` alone
  /// is sufficient and callers need not resolve the library first.
  public func fetchOne(accountId: Int64, serverItemId: String) throws -> ItemRecord? {
    try database.read { db in
      try Self.fetchOne(db, accountId: accountId, serverItemId: serverItemId)
    }
  }

  public func fetchOneAsync(accountId: Int64, serverItemId: String) async throws -> ItemRecord? {
    try await database.readAsync { db in
      try Self.fetchOne(db, accountId: accountId, serverItemId: serverItemId)
    }
  }

  private static func fetchOne(
    _ db: Database, accountId: Int64, serverItemId: String
  ) throws -> ItemRecord? {
    try ItemRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("serverItemId") == serverItemId)
      .fetchOne(db)
  }

  /// One item row reduced to what the pull-progress policy consumes: the row id progress is
  /// keyed by, and the duration the audio zero-position guard compares against. `progressOutcome`
  /// takes nothing else about the item, so this stays narrow rather than returning whole records
  /// for what is usually a whole-account `/api/me` snapshot.
  public struct ProgressTarget: Sendable, Equatable {
    public let itemRowId: Int64
    public let serverItemId: String
    public let durationSeconds: Double?

    public init(itemRowId: Int64, serverItemId: String, durationSeconds: Double?) {
      self.itemRowId = itemRowId
      self.serverItemId = serverItemId
      self.durationSeconds = durationSeconds
    }
  }

  /// Resolves `/api/me` progress rows against item rows that already exist, so a refresh can apply
  /// server progress to a library it did not traverse this pass. Backed by the unique
  /// `(libraryId, serverItemId)` index.
  ///
  /// Soft-deleted rows are excluded: pass-one deletion inference already marked them missing, and
  /// applying progress would make them look alive without the traversal evidence that would
  /// revive them. Only a traversal may revive a row, and it applies its progress then.
  public func progressTargetsAsync(
    accountId: Int64, libraryIds: [Int64], serverItemIds: [String]
  ) async throws -> [ProgressTarget] {
    guard libraryIds.isEmpty == false, serverItemIds.isEmpty == false else { return [] }
    // SQLite's bound-variable ceiling is per statement and this list is a whole `/api/me`
    // snapshot, so it chunks the way `PodcastProgressHydrationStore` chunks its own show ids.
    let chunks = serverItemIds.chunked(maximumCount: 400)
    return try await database.readAsync { db in
      var targets: [ProgressTarget] = []
      for chunk in chunks {
        let records =
          try ItemRecord
          .filter(Column("accountId") == accountId)
          .filter(libraryIds.contains(Column("libraryId")))
          .filter(Column("softDeleted") == false)
          .filter(chunk.contains(Column("serverItemId")))
          .fetchAll(db)
        for record in records {
          guard let itemRowId = record.id else { continue }
          targets.append(
            ProgressTarget(
              itemRowId: itemRowId, serverItemId: record.serverItemId,
              durationSeconds: record.durationSeconds))
        }
      }
      return targets
    }
  }

  private static func liveItems(accountId: Int64) -> QueryInterfaceRequest<ItemRecord> {
    ItemRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("softDeleted") == false)
  }

  /// Non-soft-deleted rows in `libraryId`, ordered for browse display (the
  /// `library + softDeleted + sortTitle` index backs this query).
  public func fetchBrowseList(libraryId: Int64) throws -> [ItemRecord] {
    try database.read { db in
      try ItemRecord
        .filter(Column("libraryId") == libraryId)
        .filter(Column("softDeleted") == false)
        .order(Column("sortTitle"))
        .fetchAll(db)
    }
  }

  @discardableResult
  public func upsert(_ record: ItemRecord) throws -> ItemRecord {
    try database.write { db in
      var record = record
      if let existing =
        try ItemRecord
        .filter(Column("libraryId") == record.libraryId)
        .filter(Column("serverItemId") == record.serverItemId)
        .fetchOne(db)
      {
        record.id = existing.id
        record.preserveEbookIdentity(from: existing)
      }
      record.ebookFileExt = ItemRecord.normalizedEbookFileExtension(record.ebookFileExt)
      try record.save(db)
      return record
    }
  }

  @discardableResult
  public func upsertAsync(_ record: ItemRecord) async throws -> ItemRecord {
    try await database.writeAsync { db in
      var record = record
      if let existing =
        try ItemRecord
        .filter(Column("libraryId") == record.libraryId)
        .filter(Column("serverItemId") == record.serverItemId)
        .fetchOne(db)
      {
        record.id = existing.id
        record.preserveEbookIdentity(from: existing)
      }
      record.ebookFileExt = ItemRecord.normalizedEbookFileExtension(record.ebookFileExt)
      try record.save(db)
      return record
    }
  }
}
