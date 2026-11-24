import Foundation
import GRDB

/// One show a list can name, from either source, as the editor's picker reads it.
public struct SmartListCatalogShow: Sendable, Equatable {
  public let ref: SmartListShowRef
  public let title: String
  /// Opaque feed fingerprint, used to pair a native show with its Audiobookshelf twin.
  public let fingerprint: String?

  public init(ref: SmartListShowRef, title: String, fingerprint: String? = nil) {
    self.ref = ref
    self.title = title
    self.fingerprint = fingerprint
  }
}

/// Every followed native feed (keyed by `feedURL`) and every podcast show of the signed-in
/// account in an included library (keyed `serverUserId|serverItemId`). Yields the current value
/// first. Callers filter by source availability themselves.
public protocol SmartListShowCatalogReading: Sendable {
  func observeShows() -> AsyncStream<[SmartListCatalogShow]>
}

/// GRDB `ValueObservation` over `rssFeed` and the account's podcast `item` rows. Native shows come
/// first, then server shows, each by title. The server half applies the same predicate and key as
/// `SmartListEpisodesReading`: not soft-deleted, library not soft-deleted and included.
public struct DefaultSmartListShowCatalogReading: SmartListShowCatalogReading {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func observeShows() -> AsyncStream<[SmartListCatalogShow]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in try Self.shows(db) }.removeDuplicates())
  }

  private static func shows(_ db: Database) throws -> [SmartListCatalogShow] {
    var result: [SmartListCatalogShow] = []
    let native = try Row.fetchAll(
      db,
      sql: """
        SELECT feedURL, title, podcastFeedFingerprint FROM rssFeed
        ORDER BY title COLLATE NOCASE, id
        """)
    for row in native {
      let url: String = row["feedURL"]
      let title: String? = row["title"]
      result.append(
        SmartListCatalogShow(
          ref: .native(feedURL: url), title: title?.isEmpty == false ? title! : url,
          fingerprint: row["podcastFeedFingerprint"]))
    }
    guard let account = try AccountRecord.fetchOne(db), let accountID = account.id else {
      return result
    }
    let server = try Row.fetchAll(
      db,
      sql: """
        SELECT account.serverUserId || '|' || item.serverItemId AS showKey,
               item.title, item.podcastFeedFingerprint
        FROM item
        JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
        JOIN account ON account.id = item.accountId
        WHERE item.accountId = ? AND item.mediaKind = 'podcast' AND \(ItemVisibilityPredicate.sql)
        ORDER BY item.title COLLATE NOCASE, item.id
        """,
      arguments: [accountID])
    for row in server {
      result.append(
        SmartListCatalogShow(
          ref: SmartListShowRef(source: .server, showKey: row["showKey"]),
          title: row["title"], fingerprint: row["podcastFeedFingerprint"]))
    }
    return result
  }
}
