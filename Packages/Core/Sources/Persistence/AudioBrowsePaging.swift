import Foundation
import GRDB

/// One bounded page of a list a small screen pages through, plus where the next page starts.
/// `next` is nil on the last page.
public struct AudioBrowsePage<Row: Sendable & Equatable, Cursor: Sendable & Hashable>: Sendable, Equatable {
  public let rows: [Row]
  public let next: Cursor?

  public init(rows: [Row], next: Cursor?) {
    self.rows = rows
    self.next = next
  }
}

/// An audiobook as a paged list shows it: enough to title a row and to play exactly that book.
public struct AudiobookPageRow: Sendable, Equatable {
  public let identity: ListeningIdentity
  public let title: String
  public let author: String?
  /// Revisions the item's cover.
  public let serverUpdatedAt: Date?
  /// The book's place in the series it was listed under, as the server writes it; nil in any
  /// other list and for a book the series does not number.
  public let seriesSequence: String?

  public init(
    identity: ListeningIdentity, title: String, author: String?, serverUpdatedAt: Date?,
    seriesSequence: String? = nil
  ) {
    self.identity = identity
    self.title = title
    self.author = author
    self.serverUpdatedAt = serverUpdatedAt
    self.seriesSequence = seriesSequence
  }
}

/// The last row of an audiobook page. Opaque outside Persistence: the pair is the ordering key,
/// so two books that share a sort title still page without a repeat or a gap.
public struct AudiobookPageCursor: Sendable, Hashable {
  let sortTitle: String
  let rowID: Int64
}

/// Bounded reads for surfaces that must never load a whole library to show a few rows
/// Every membership rule runs in SQL before the limit, so a page is short only when the list is
/// ending.
public protocol AudioBrowsePaging: Sendable {
  /// Audiobooks in title order across the included libraries, starting after `cursor`.
  func audiobookPage(
    after cursor: AudiobookPageCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudiobookPageCursor>
}

/// Audio that is fully on the device, as a paged list shows it: one audiobook or one episode.
public struct DownloadedAudioPageRow: Sendable, Equatable {
  public let identity: ListeningIdentity
  public let title: String
  /// The author of a book, or the show an episode belongs to.
  public let subtitle: String?
  /// Revisions a server item's cover; nil for a followed feed, whose artwork is addressed by URL.
  public let serverUpdatedAt: Date?
  public let artworkURL: URL?
  public let artworkFeedURL: URL?

  public init(
    identity: ListeningIdentity, title: String, subtitle: String?, serverUpdatedAt: Date? = nil,
    artworkURL: URL? = nil, artworkFeedURL: URL? = nil
  ) {
    self.identity = identity
    self.title = title
    self.subtitle = subtitle
    self.serverUpdatedAt = serverUpdatedAt
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
  }
}

/// One source's completed audio downloads, a page at a time. A row is here only when that book's
/// or that episode's own audio is complete: a downloaded EPUB, a show's aggregate state and a
/// transfer still in flight never qualify. Files are validated again when playback resolves them.
public protocol DownloadedAudioPaging: Sendable {
  func downloadedAudioPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<DownloadedAudioPageRow, AudioBrowseCursor>
}

public struct DefaultAudioBrowsePaging: AudioBrowsePaging, DownloadedAudioPaging {
  /// No caller needs more in one read, and a larger request is a caller bug rather than a reason
  /// to scan further.
  public static let maximumPageSize = 100

  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  static func clamped(_ limit: Int) -> Int {
    min(max(1, limit), maximumPageSize)
  }

  public func audiobookPage(
    after cursor: AudiobookPageCursor?, limit: Int
  ) async throws -> AudioBrowsePage<AudiobookPageRow, AudiobookPageCursor> {
    let limit = Self.clamped(limit)
    return try await database.readAsync { db in
      // The same membership as the phone's Audiobooks filter, mixed audio-and-EPUB books
      // included. One row past the page says whether another page exists.
      var arguments: StatementArguments = []
      var after = ""
      if let cursor {
        after = "AND (item.sortTitle > ? OR (item.sortTitle = ? AND item.id > ?))"
        arguments += [cursor.sortTitle, cursor.sortTitle, cursor.rowID]
      }
      arguments += [limit + 1]
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT item.id, item.serverItemId, item.title, item.sortTitle, item.author,
            item.serverUpdatedAt
          FROM item
          JOIN library
            ON library.id = item.libraryId
            AND library.accountId = item.accountId
          WHERE \(ItemVisibilityPredicate.sql)
            AND (\(ItemCategoryPredicate.sql(.audiobook)))
            \(after)
          ORDER BY item.sortTitle, item.id
          LIMIT ?
          """,
        arguments: arguments)

      let page = fetched.prefix(limit)
      let next: AudiobookPageCursor? =
        fetched.count > limit
        ? page.last.map { AudiobookPageCursor(sortTitle: $0["sortTitle"], rowID: $0["id"]) }
        : nil
      let rows = page.compactMap { row -> AudiobookPageRow? in
        guard let identity = ListeningIdentity.audiobook(itemID: row["serverItemId"]) else { return nil }
        return AudiobookPageRow(
          identity: identity, title: row["title"], author: row["author"],
          serverUpdatedAt: row["serverUpdatedAt"])
      }
      return AudioBrowsePage(rows: rows, next: next)
    }
  }

  /// Server audiobooks and podcast episodes together, by item title; a show's episodes run
  /// newest first.
  public func downloadedAudioPage(
    after cursor: AudioBrowseCursor?, limit: Int
  ) async throws -> AudioBrowsePage<DownloadedAudioPageRow, AudioBrowseCursor> {
    let limit = Self.clamped(limit)
    let keyset = Keyset(
      scope: "server-downloads",
      terms: [
        KeysetTerm(expression: "entry.sortTitle"),
        KeysetTerm(expression: "entry.itemRowID"),
        KeysetTerm(expression: "entry.isUndated"),
        KeysetTerm(expression: "entry.publishedKey", descending: true),
        KeysetTerm(expression: "entry.episodeRowID"),
      ])
    let after = try keyset.predicate(after: cursor)
    return try await database.readAsync { db in
      let fetched = try Row.fetchAll(
        db,
        sql: """
          SELECT entry.*, \(keyset.selection)
          FROM (
            SELECT
              item.sortTitle AS sortTitle, item.id AS itemRowID, 0 AS isUndated,
              '' AS publishedKey, 0 AS episodeRowID,
              item.serverItemId AS serverItemId, NULL AS serverEpisodeId,
              item.title AS title, item.author AS subtitle, item.serverUpdatedAt AS serverUpdatedAt
            FROM item
            JOIN library
              ON library.id = item.libraryId
              AND library.accountId = item.accountId
            WHERE \(ItemVisibilityPredicate.sql)
              AND (\(ItemCategoryPredicate.sql(.audiobook)))
              AND \(Self.completedAudioSQL(episode: "IS NULL"))
            UNION ALL
            SELECT
              item.sortTitle, item.id, episode.publishedAt IS NULL,
              COALESCE(episode.publishedAt, ''), episode.id,
              item.serverItemId, episode.serverEpisodeId,
              episode.title, item.title, item.serverUpdatedAt
            FROM podcastEpisode AS episode
            JOIN item
              ON item.id = episode.itemId
              AND item.accountId = episode.accountId
            JOIN library
              ON library.id = item.libraryId
              AND library.accountId = item.accountId
            WHERE episode.softDeleted = 0 AND \(ItemVisibilityPredicate.sql)
              AND \(Self.completedAudioSQL(episode: "= episode.id"))
          ) AS entry
          WHERE 1 = 1
            \(after.sql)
          \(keyset.ordering)
          LIMIT ?
          """,
        arguments: after.arguments + [limit + 1])
      let page = keyset.page(fetched, limit: limit)
      let rows = page.rows.compactMap { row -> DownloadedAudioPageRow? in
        guard
          let identity = ListeningIdentity.resolving(
            itemID: row["serverItemId"], episodeID: row["serverEpisodeId"])
        else { return nil }
        return DownloadedAudioPageRow(
          identity: identity, title: row["title"], subtitle: row["subtitle"],
          serverUpdatedAt: row["serverUpdatedAt"])
      }
      return AudioBrowsePage(rows: rows, next: page.next)
    }
  }

  /// The item-level audio rule of `DefaultHomeReading.downloadRollupCTE`, for one book
  /// (`episode: "IS NULL"`) or one episode: at least one audio file that is not being deleted,
  /// and every such file completed.
  private static func completedAudioSQL(episode: String) -> String {
    let files = """
      SELECT 1 FROM download
      WHERE download.accountId = item.accountId AND download.itemId = item.id
        AND download.podcastEpisodeId \(episode) AND download.mediaKind = 'audio'
      """
    return """
      EXISTS (\(files) AND download.state <> 'deleting')
      AND NOT EXISTS (\(files) AND download.state NOT IN ('completed', 'deleting'))
      """
  }
}
