import Foundation
import GRDB

/// One entry of a collection or playlist as its detail screen shows it: a title from the local
/// catalogue, or a podcast episode reached through its show item.
public enum LibraryCollectionEntry: Sendable, Equatable, Identifiable {
  case title(ItemSummary, isFinished: Bool)
  case episode(HomePodcastEpisode)

  /// Unique within one list: the store keeps only the first of a repeated member.
  public var id: String {
    switch self {
    case .title(let summary, _): summary.serverItemId
    case .episode(let episode): episode.id
    }
  }

  public var itemID: String {
    switch self {
    case .title(let summary, _): summary.serverItemId
    case .episode(let episode): episode.itemID
    }
  }

  public var episodeID: String? {
    switch self {
    case .title: nil
    case .episode(let episode): episode.episodeID
    }
  }

  public var category: ItemMediaCategory {
    switch self {
    case .title(let summary, _): summary.category
    case .episode: .podcast
    }
  }

  public var durationSeconds: Double? {
    switch self {
    case .title(let summary, _): summary.durationSeconds
    case .episode(let episode): episode.durationSeconds
    }
  }

  public var isFinished: Bool {
    switch self {
    case .title(_, let isFinished): isFinished
    case .episode(let episode): episode.isFinished
    }
  }
}

/// A stored list with its held entries in the server's order. Members the local catalogue does
/// not hold are left out, which is also what hides restricted books the listing leaks.
public struct LibraryCollectionContents: Sendable, Equatable {
  public let listing: LibraryCollectionListing
  public let entries: [LibraryCollectionEntry]

  public init(listing: LibraryCollectionListing, entries: [LibraryCollectionEntry]) {
    self.listing = listing
    self.entries = entries
  }
}

extension LibraryCollectionStore {
  /// The list and its held entries, or nil when the list is not stored (never fetched, removed by
  /// the last refresh, or its library is no longer included). Keyed by server identity, so it
  /// keeps following the list across a refresh that replaces its rows.
  public func observeContents(
    accountID: Int64, key: LibraryCollectionKey
  ) -> AsyncStream<LibraryCollectionContents?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try Self.contents(db: db, accountID: accountID, key: key) }
        // Progress rows are written on every playback tick; positions are quantized below, so
        // only a visible change re-emits.
        .removeDuplicates())
  }

  public func contents(
    accountID: Int64, key: LibraryCollectionKey
  ) async -> LibraryCollectionContents? {
    try? await database.readAsync { db in
      try Self.contents(db: db, accountID: accountID, key: key)
    }
  }

  static func contents(
    db: Database, accountID: Int64, key: LibraryCollectionKey
  ) throws -> LibraryCollectionContents? {
    guard
      let listing = try listings(db: db, accountID: accountID).first(where: { $0.key == key }),
      let listID = try Int64.fetchOne(
        db,
        sql: """
          SELECT list.id FROM libraryCollection AS list
          JOIN library ON library.id = list.libraryId
          WHERE library.accountId = ? AND library.serverLibraryId = ?
            AND list.kind = ? AND list.serverId = ?
          """,
        arguments: [accountID, key.serverLibraryID, key.kind.rawValue, key.serverID])
    else { return nil }

    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT member.serverItemId, member.serverEpisodeId,
          item.id AS itemRowId,
          itemProgress.currentTime AS itemProgressSeconds,
          itemProgress.isFinished AS itemIsFinished,
          episode.title AS episodeTitle, episode.subtitle AS episodeSubtitle,
          episode.publishedAt AS episodePublishedAt,
          episode.durationSeconds AS episodeDurationSeconds,
          episodeProgress.currentTime AS episodeProgressSeconds,
          episodeProgress.isFinished AS episodeIsFinished
        FROM libraryCollectionMember AS member
        JOIN libraryCollection AS list ON list.id = member.collectionId
        \(heldMemberJoin)
        LEFT JOIN mediaProgress AS itemProgress
          ON itemProgress.itemId = item.id AND itemProgress.accountId = item.accountId
          AND itemProgress.podcastEpisodeId IS NULL
        LEFT JOIN mediaProgress AS episodeProgress
          ON episodeProgress.itemId = item.id AND episodeProgress.accountId = item.accountId
          AND episodeProgress.podcastEpisodeId = episode.id
        WHERE member.collectionId = ? AND \(heldCondition)
        ORDER BY member.position
        """,
      arguments: [listID])

    let itemRowIDs = Set(rows.map { $0["itemRowId"] as Int64 })
    let records = try ItemRecord.filter(itemRowIDs.contains(Column("id"))).fetchAll(db)
    let recordsByRowID = Dictionary(
      records.compactMap { record in record.id.map { ($0, record) } },
      uniquingKeysWith: { first, _ in first })

    var seen: Set<String> = []
    var entries: [LibraryCollectionEntry] = []
    for row in rows {
      let serverEpisodeID: String? = row["serverEpisodeId"]
      let identity = memberIdentity(
        serverItemID: row["serverItemId"], serverEpisodeID: serverEpisodeID)
      guard seen.insert(identity).inserted,
        let record = recordsByRowID[row["itemRowId"] as Int64]
      else { continue }
      entries.append(entry(row: row, record: record, serverEpisodeID: serverEpisodeID))
    }
    return LibraryCollectionContents(listing: listing, entries: entries)
  }

  private static func entry(
    row: Row, record: ItemRecord, serverEpisodeID: String?
  ) -> LibraryCollectionEntry {
    guard let serverEpisodeID else {
      let progress = PlaybackPositionListProjection.quantizedSeconds(
        (row["itemProgressSeconds"] as Double?) ?? 0)
      return .title(
        DefaultLibraryReading.makeSummary(record, progressSeconds: progress),
        isFinished: (row["itemIsFinished"] as Bool?) ?? false)
    }
    return .episode(
      HomePodcastEpisode(
        itemID: record.serverItemId,
        showTitle: record.title,
        showAuthor: record.author,
        episodeID: serverEpisodeID,
        title: row["episodeTitle"],
        subtitle: row["episodeSubtitle"],
        publishedAt: (row["episodePublishedAt"] as Date?) ?? .distantPast,
        durationSeconds: row["episodeDurationSeconds"],
        progressSeconds: PlaybackPositionListProjection.quantizedSeconds(
          (row["episodeProgressSeconds"] as Double?) ?? 0),
        isFinished: (row["episodeIsFinished"] as Bool?) ?? false,
        showServerUpdatedAt: record.serverUpdatedAt))
  }
}
