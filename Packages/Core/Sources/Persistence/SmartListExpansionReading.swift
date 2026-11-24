import Foundation
import GRDB

/// An Audiobookshelf podcast show a smart list needs fully expanded.
public struct SmartListNamedShow: Sendable, Equatable {
  public let localItemID: Int64
  public let serverItemID: String
  /// The server's episode count as the library pull stored it; nil when not known. Chunking by
  /// episode count depends on it.
  public let knownEpisodeCount: Int?

  public init(localItemID: Int64, serverItemID: String, knownEpisodeCount: Int?) {
    self.localItemID = localItemID
    self.serverItemID = serverItemID
    self.knownEpisodeCount = knownEpisodeCount
  }
}

/// Which server shows smart lists name, and whether a list's shows are all fully expanded.
///
/// A list names a show by `"<account.serverUserId>|<item.serverItemId>"`. `all` needs every
/// podcast show in the included libraries, `allExcept` the same minus its `excluded` rows, and
/// `only` its `included` and `priority` rows. A show that is not on the device (another account,
/// soft-deleted, library not included) is never returned.
public struct SmartListExpansionReading: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// The shows named by `listID`, or by every list when nil, for `accountID`, in item id order.
  public func namedShows(accountID: Int64, listID: Int64? = nil) async throws
    -> [SmartListNamedShow]
  {
    try await database.readAsync { db in
      try Self.namedShows(db, accountID: accountID, listID: listID, incompleteOnly: false)
    }
  }

  /// True while any show `listID` names has no complete episode list yet ("Updating shows…").
  public func isUpdating(listID: Int64, accountID: Int64) async throws -> Bool {
    try await database.readAsync { db in
      try Self.namedShows(db, accountID: accountID, listID: listID, incompleteOnly: true)
        .isEmpty == false
    }
  }

  /// Yields the current value first, then every change.
  public func observeIsUpdating(listID: Int64, accountID: Int64) -> AsyncStream<Bool> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          try Self.namedShows(db, accountID: accountID, listID: listID, incompleteOnly: true)
            .isEmpty == false
        }
        .removeDuplicates())
  }

  private static func namedShows(
    _ db: Database, accountID: Int64, listID: Int64?, incompleteOnly: Bool
  ) throws -> [SmartListNamedShow] {
    let incomplete =
      incompleteOnly
      ? """
      AND NOT EXISTS (
        SELECT 1 FROM podcastRefreshState s
        WHERE s.itemId = i.id AND s.lastCompleteEpisodeListAt IS NOT NULL)
      """
      : ""
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT i.id AS itemId, i.serverItemId, i.podcastServerEpisodeCount
        FROM item i
        JOIN library l ON l.id = i.libraryId AND l.accountId = i.accountId
        JOIN account a ON a.id = i.accountId
        WHERE i.accountId = ? AND i.mediaKind = 'podcast' AND i.softDeleted = 0
          AND l.softDeleted = 0 AND l.isIncluded = 1
          \(incomplete)
          AND EXISTS (
            SELECT 1 FROM smartList sl
            WHERE (? IS NULL OR sl.id = ?)
              AND (
                sl.showScope = 'all'
                OR (sl.showScope = 'allExcept' AND NOT EXISTS (
                  SELECT 1 FROM smartListShow ss
                  WHERE ss.listId = sl.id AND ss.source = 'server' AND ss.role = 'excluded'
                    AND ss.showKey = a.serverUserId || '|' || i.serverItemId))
                OR (sl.showScope = 'only' AND EXISTS (
                  SELECT 1 FROM smartListShow ss
                  WHERE ss.listId = sl.id AND ss.source = 'server'
                    AND ss.role IN ('included', 'priority')
                    AND ss.showKey = a.serverUserId || '|' || i.serverItemId))))
        ORDER BY i.id
        """,
      arguments: [accountID, listID, listID])
    return rows.map {
      SmartListNamedShow(
        localItemID: $0["itemId"], serverItemID: $0["serverItemId"],
        knownEpisodeCount: $0["podcastServerEpisodeCount"])
    }
  }
}
