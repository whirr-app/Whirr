import Foundation
import GRDB

extension DownloadStore {
  // MARK: - Item-level detailed status

  /// This item's detailed rollup status across every item-level medium that has rows.
  /// `DefaultDownloadReading` wraps this same logic in a `ValueObservation`. An explicit
  /// `mediaKind` override gives one medium's projection.
  public func itemStatus(
    itemId: Int64, mediaKind: DownloadMediaKind? = nil
  ) throws -> ItemDownloadStatus {
    try database.read { db in try Self.itemStatus(db, itemId: itemId, mediaKind: mediaKind) }
  }

  /// Priority-ordered derivation, most blocking condition first. `deleting` is checked first
  /// (always non-playable and non-schedulable). `pausedAuth` outranks an ordinary `failed` sibling
  /// because its only exit is re-authentication. Then `failed`, `paused`, `downloading`, then the
  /// durable holds not yet acted on (`waitingForWiFi`, `interrupted`). A lone `pending` row with
  /// no hold reason is `queued`. `completed` needs every live row across every requested medium
  /// to agree, as in `aggregate`; a medium is requested because it has a row, not because of the
  /// item's metadata.
  static func itemStatus(
    _ db: Database, itemId: Int64, mediaKind: DownloadMediaKind? = nil
  ) throws -> ItemDownloadStatus {
    let rows: [DownloadRecord]
    if let mediaKind {
      rows =
        try DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("mediaKind") == mediaKind.rawValue)
        .fetchAll(db)
    } else {
      rows =
        try DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(sql: DownloadMediaKind.itemMediaSQL())
        .fetchAll(db)
    }
    return status(rows: rows)
  }

  /// The detailed status of each item-level medium. A missing medium is `.notDownloaded`, while
  /// an existing row in any non-completed state keeps its detailed status. The format-aware
  /// companion to `itemStatus(itemId:)`; both reduce the same rows, so the item-level answer
  /// never uses `hasReadableEbook` as a request signal.
  public func itemFormatStatus(itemId: Int64) throws -> ItemFormatDownloadStatus {
    try database.read { db in try Self.itemFormatStatus(db, itemId: itemId) }
  }

  static func itemFormatStatus(
    _ db: Database, itemId: Int64
  ) throws -> ItemFormatDownloadStatus {
    let rows =
      try DownloadRecord
      .filter(Column("itemId") == itemId)
      .fetchAll(db)
    let rowsByMediaKind = Dictionary(grouping: rows, by: \.mediaKind)
    return ItemFormatDownloadStatus(
      audio: status(rows: rowsByMediaKind[.audio] ?? []),
      ebook: status(rows: rowsByMediaKind[.ebook] ?? []))
  }

  /// The derivation over rows already fetched, split out so single-item callers share the same
  /// priority rules. The coarse bulk `itemPresence` projection below selects only identity and
  /// state.
  static func status(rows: [DownloadRecord]) -> ItemDownloadStatus {
    DownloadStatusReducer.reduce(rows.map { DownloadStatusProjection(record: $0) })
  }

  /// Every item that has download rows, summarised, keyed by server item id (all callers hold).
  /// An item with no rows is absent rather than `.none`, so the map is the size of the downloaded
  /// set. Two queries total however many items are on screen, not one observation per row.
  ///
  /// Item-level rows only: episode-scoped rows are excluded, since this drives item-level
  /// affordances (the "Downloaded" badge, whole-item download/remove) and grouping on `itemId`
  /// alone would badge a show "Downloaded" for three episodes and offer a "Delete Download" that
  /// purged them all. The default folds every item medium's rows into one presence (a supplement
  /// PDF never makes a book "downloaded" or "partial", see `DownloadMediaKind.isItemMedia`); an
  /// explicit override gives a single medium. Episode state is `DefaultPodcastReading`'s
  /// projection; Home's Downloaded row has its own query (`DefaultHomeReading`).
  static func itemPresence(
    _ db: Database, mediaKind: DownloadMediaKind? = nil
  ) throws -> [String: ItemDownloadPresence] {
    let (mediaKindClause, arguments): (String, StatementArguments) =
      if let mediaKind {
        ("download.mediaKind = ?", [mediaKind.rawValue])
      } else {
        (DownloadMediaKind.itemMediaSQL(), [])
      }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT download.itemId AS itemId, download.state AS state
        FROM download
        JOIN item ON item.id = download.itemId
        WHERE download.podcastEpisodeId IS NULL AND \(mediaKindClause)
        """,
      arguments: arguments)
    guard rows.isEmpty == false else { return [:] }

    var statesByItemRowId: [Int64: [DownloadState]] = [:]
    for row in rows {
      let itemId: Int64 = row["itemId"]
      let state: DownloadState = row["state"]
      statesByItemRowId[itemId, default: []].append(state)
    }
    let items = try ItemRecord.filter(Set(statesByItemRowId.keys).contains(Column("id"))).fetchAll(db)

    return items.reduce(into: [:]) { result, item in
      guard let rowId = item.id, let states = statesByItemRowId[rowId] else { return }
      let liveStates = states.filter { $0 != .deleting }
      if liveStates.isEmpty {
        result[item.serverItemId] = .deleting
      } else if liveStates.allSatisfy({ $0 == .completed }) {
        result[item.serverItemId] = .completed
      } else {
        result[item.serverItemId] = .partial
      }
    }
  }

  /// The episode-scoped counterpart of `itemPresence`, keyed by the full `(show, episode)` server
  /// identity. Covers the rows `itemPresence` excludes, with the same priority rule, so a surface
  /// acting on one episode (the player's overflow menu) reads its own download state. An episode
  /// with no rows is absent, so the map tracks the downloaded set, not the catalogue.
  static func episodePresence(_ db: Database) throws -> [EpisodeDownloadKey: ItemDownloadPresence] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId AS serverItemId,
               podcastEpisode.serverEpisodeId AS serverEpisodeId,
               download.state AS state
        FROM download
        JOIN podcastEpisode ON podcastEpisode.id = download.podcastEpisodeId
        JOIN item ON item.id = download.itemId
        WHERE download.podcastEpisodeId IS NOT NULL
        """)
    guard rows.isEmpty == false else { return [:] }

    var statesByKey: [EpisodeDownloadKey: [DownloadState]] = [:]
    for row in rows {
      let key = EpisodeDownloadKey(
        itemID: row["serverItemId"], episodeID: row["serverEpisodeId"])
      let state: DownloadState = row["state"]
      statesByKey[key, default: []].append(state)
    }

    return statesByKey.reduce(into: [:]) { result, entry in
      let liveStates = entry.value.filter { $0 != .deleting }
      if liveStates.isEmpty {
        result[entry.key] = .deleting
      } else if liveStates.allSatisfy({ $0 == .completed }) {
        result[entry.key] = .completed
      } else {
        result[entry.key] = .partial
      }
    }
  }
}
