import Foundation
import GRDB

/// Which server list a stored collection row mirrors. Persistence owns its own value so it does not
/// depend on `ABSApi`; `SyncEngine` maps between the two.
public enum LibraryCollectionListKind: String, Sendable, Equatable, CaseIterable {
  case collection
  case playlist
}

public struct LibraryCollectionSnapshotMember: Sendable, Equatable {
  public let serverItemID: String
  public let serverEpisodeID: String?
  public let fallbackTitle: String?

  public init(serverItemID: String, serverEpisodeID: String? = nil, fallbackTitle: String? = nil) {
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
    self.fallbackTitle = fallbackTitle
  }
}

/// One list from a complete, non-lossy pass, members in the server's order.
public struct LibraryCollectionSnapshotList: Sendable, Equatable {
  public let serverID: String
  public let name: String?
  public let description: String?
  public let lastUpdate: Date?
  public let members: [LibraryCollectionSnapshotMember]

  public init(
    serverID: String,
    name: String?,
    description: String?,
    lastUpdate: Date?,
    members: [LibraryCollectionSnapshotMember]
  ) {
    self.serverID = serverID
    self.name = name
    self.description = description
    self.lastUpdate = lastUpdate
    self.members = members
  }
}

/// A stored list, keyed by server identity because each replace gives its rows new local ids.
public struct LibraryCollectionKey: Sendable, Hashable {
  public let serverLibraryID: String
  public let kind: LibraryCollectionListKind
  public let serverID: String

  public init(serverLibraryID: String, kind: LibraryCollectionListKind, serverID: String) {
    self.serverLibraryID = serverLibraryID
    self.kind = kind
    self.serverID = serverID
  }
}

/// A list as the browse screen shows it. `heldMemberCount` counts only members the local catalogue
/// holds (a live item, and for an episode a live episode of that item), which is also what hides
/// restricted books the collections listing leaks. A member repeated in the list counts once.
/// `heldCategories` are the media categories of those held members, an episode counting as a
/// podcast, so the Library's category filter can decide whether the list shows.
public struct LibraryCollectionListing: Sendable, Equatable, Identifiable {
  public let key: LibraryCollectionKey
  public let libraryName: String
  public let name: String?
  public let description: String?
  public let lastUpdate: Date?
  public let heldMemberCount: Int
  public let heldCategories: Set<ItemMediaCategory>

  public var id: LibraryCollectionKey { key }

  public init(
    key: LibraryCollectionKey,
    libraryName: String,
    name: String?,
    description: String?,
    lastUpdate: Date?,
    heldMemberCount: Int,
    heldCategories: Set<ItemMediaCategory> = []
  ) {
    self.key = key
    self.libraryName = libraryName
    self.name = name
    self.description = description
    self.lastUpdate = lastUpdate
    self.heldMemberCount = heldMemberCount
    self.heldCategories = heldCategories
  }
}

/// One stored member with its local catalogue match, if any. `itemID` / `episodeID` are nil when
/// the catalogue does not hold the member.
public struct LibraryCollectionMemberMatch: Sendable, Equatable {
  public let position: Int
  public let serverItemID: String
  public let serverEpisodeID: String?
  public let fallbackTitle: String?
  public let itemID: Int64?
  public let episodeID: Int64?

  public init(
    position: Int,
    serverItemID: String,
    serverEpisodeID: String?,
    fallbackTitle: String?,
    itemID: Int64?,
    episodeID: Int64?
  ) {
    self.position = position
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
    self.fallbackTitle = fallbackTitle
    self.itemID = itemID
    self.episodeID = episodeID
  }

  public var isHeld: Bool { itemID != nil && (serverEpisodeID == nil || episodeID != nil) }
}

/// Durable owner of the collection and playlist snapshots. Callers replace a library's rows of
/// one kind only after a complete, non-lossy pass; a failed or lossy pass does not call
/// `replaceSnapshot`, so the old rows stay.
public struct LibraryCollectionStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func hasSnapshot(
    accountID: Int64, libraryID: String, kind: LibraryCollectionListKind
  ) async -> Bool {
    (try? await database.readAsync { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM libraryCollectionSnapshot AS snapshot
            JOIN library ON library.id = snapshot.libraryId
            WHERE library.accountId = ? AND library.serverLibraryId = ? AND snapshot.kind = ?
              AND library.softDeleted = 0 AND library.isIncluded = 1
          )
          """,
        arguments: [accountID, libraryID, kind.rawValue]) ?? false
    }) ?? false
  }

  /// Replaces every list of `kind` in the library in one transaction. Returns false, changing
  /// nothing, when the library is not an included, live library of the account. A repeated server
  /// id keeps its first occurrence.
  @discardableResult
  public func replaceSnapshot(
    accountID: Int64,
    libraryID: String,
    kind: LibraryCollectionListKind,
    lists: [LibraryCollectionSnapshotList],
    fetchedAt: Date = Date()
  ) async throws -> Bool {
    try await database.writeAsync { db in
      guard
        let libraryRowID = try Int64.fetchOne(
          db,
          sql: """
            SELECT id FROM library
            WHERE accountId = ? AND serverLibraryId = ?
              AND softDeleted = 0 AND isIncluded = 1
            """,
          arguments: [accountID, libraryID])
      else { return false }

      try db.execute(
        sql: "DELETE FROM libraryCollection WHERE libraryId = ? AND kind = ?",
        arguments: [libraryRowID, kind.rawValue])
      var seen: Set<String> = []
      for list in lists where seen.insert(list.serverID).inserted {
        try Self.insertList(db: db, libraryRowID: libraryRowID, kind: kind, list: list)
      }
      try db.execute(
        sql: """
          INSERT INTO libraryCollectionSnapshot (libraryId, kind, fetchedAt) VALUES (?, ?, ?)
          ON CONFLICT(libraryId, kind) DO UPDATE SET fetchedAt = excluded.fetchedAt
          """,
        arguments: [libraryRowID, kind.rawValue, fetchedAt])
      return true
    }
  }

  private static func insertList(
    db: Database, libraryRowID: Int64, kind: LibraryCollectionListKind,
    list: LibraryCollectionSnapshotList
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO libraryCollection
          (libraryId, kind, serverId, name, description, lastUpdate)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        libraryRowID, kind.rawValue, list.serverID, list.name, list.description,
        list.lastUpdate,
      ])
    let collectionID = db.lastInsertedRowID
    for (position, member) in list.members.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO libraryCollectionMember
            (collectionId, position, serverItemId, serverEpisodeId, fallbackTitle)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [
          collectionID, position, member.serverItemID, member.serverEpisodeID,
          member.fallbackTitle,
        ])
    }
  }

  /// Every stored list in the account's included libraries, collections before playlists, then by
  /// name. Lists with no held member are returned too; hiding them is the model's rule.
  public func listings(accountID: Int64) async -> [LibraryCollectionListing] {
    (try? await database.readAsync { db in try Self.listings(db: db, accountID: accountID) }) ?? []
  }

  public func observeListings(accountID: Int64) -> AsyncStream<[LibraryCollectionListing]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.listings(db: db, accountID: accountID)
    }
  }

  /// The list's members in order with their catalogue matches, or nil when the list is not stored
  /// (never fetched, or removed by the last refresh).
  public func members(
    accountID: Int64, key: LibraryCollectionKey
  ) async -> [LibraryCollectionMemberMatch]? {
    try? await database.readAsync { db in try Self.members(db: db, accountID: accountID, key: key) }
  }

  // MARK: - Queries

  /// A member is held when its item is a live row of the list's own library and, for an episode,
  /// that item has the live episode.
  static let heldMemberJoin = """
    -- Not a catalogue projection: membership reads the list's own library, included or not.
    LEFT JOIN item ON item.libraryId = list.libraryId
      AND item.serverItemId = member.serverItemId AND item.softDeleted = 0
    LEFT JOIN podcastEpisode AS episode ON member.serverEpisodeId IS NOT NULL
      AND episode.itemId = item.id AND episode.serverEpisodeId = member.serverEpisodeId
      AND episode.softDeleted = 0
    """

  static let heldCondition =
    "item.id IS NOT NULL AND (member.serverEpisodeId IS NULL OR episode.id IS NOT NULL)"

  static func listings(db: Database, accountID: Int64) throws -> [LibraryCollectionListing] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT list.id, list.kind, list.serverId, list.name, list.description, list.lastUpdate,
          library.serverLibraryId, library.name AS libraryName
        FROM libraryCollection AS list
        JOIN library ON library.id = list.libraryId
        WHERE library.accountId = ? AND library.softDeleted = 0 AND library.isIncluded = 1
        ORDER BY CASE list.kind WHEN 'collection' THEN 0 ELSE 1 END,
          COALESCE(list.name, '') COLLATE NOCASE, library.name COLLATE NOCASE, list.serverId
        """,
      arguments: [accountID])
    let held = try heldMembers(db: db, accountID: accountID)
    return rows.compactMap { row in
      guard let kind = LibraryCollectionListKind(rawValue: row["kind"]) else { return nil }
      let listID: Int64 = row["id"]
      let members = held[listID] ?? [:]
      return LibraryCollectionListing(
        key: LibraryCollectionKey(
          serverLibraryID: row["serverLibraryId"], kind: kind, serverID: row["serverId"]),
        libraryName: row["libraryName"],
        name: row["name"],
        description: row["description"],
        lastUpdate: row["lastUpdate"],
        heldMemberCount: members.count,
        heldCategories: Set(members.values))
    }
  }

  /// Every held member of the account's included lists, keyed by list row id, then by member
  /// identity (so a repeated member counts once) to its media category.
  private static func heldMembers(
    db: Database, accountID: Int64
  ) throws -> [Int64: [String: ItemMediaCategory]] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT member.collectionId, member.serverItemId, member.serverEpisodeId,
          item.mediaKind, item.numAudioFiles, item.ebookFormat
        FROM libraryCollectionMember AS member
        JOIN libraryCollection AS list ON list.id = member.collectionId
        JOIN library ON library.id = list.libraryId
        \(heldMemberJoin)
        WHERE library.accountId = ? AND library.softDeleted = 0 AND library.isIncluded = 1
          AND \(heldCondition)
        """,
      arguments: [accountID])
    var held: [Int64: [String: ItemMediaCategory]] = [:]
    for row in rows {
      let serverItemID: String = row["serverItemId"]
      let serverEpisodeID: String? = row["serverEpisodeId"]
      let category: ItemMediaCategory =
        serverEpisodeID == nil
        ? ItemMediaCategory.derive(
          mediaKind: row["mediaKind"], numAudioFiles: row["numAudioFiles"],
          ebookFormat: row["ebookFormat"])
        : .podcast
      held[row["collectionId"], default: [:]][
        memberIdentity(serverItemID: serverItemID, serverEpisodeID: serverEpisodeID)] = category
    }
    return held
  }

  static func memberIdentity(serverItemID: String, serverEpisodeID: String?) -> String {
    serverEpisodeID.map { "\(serverItemID)/\($0)" } ?? serverItemID
  }

  private static func members(
    db: Database, accountID: Int64, key: LibraryCollectionKey
  ) throws -> [LibraryCollectionMemberMatch]? {
    guard
      let listID = try Int64.fetchOne(
        db,
        sql: """
          SELECT list.id FROM libraryCollection AS list
          JOIN library ON library.id = list.libraryId
          WHERE library.accountId = ? AND library.serverLibraryId = ?
            AND library.softDeleted = 0 AND library.isIncluded = 1
            AND list.kind = ? AND list.serverId = ?
          """,
        arguments: [accountID, key.serverLibraryID, key.kind.rawValue, key.serverID])
    else { return nil }
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT member.position, member.serverItemId, member.serverEpisodeId, member.fallbackTitle,
          item.id AS itemId, episode.id AS episodeId
        FROM libraryCollectionMember AS member
        JOIN libraryCollection AS list ON list.id = member.collectionId
        \(heldMemberJoin)
        WHERE member.collectionId = ?
        ORDER BY member.position
        """,
      arguments: [listID])
    return rows.map { row in
      LibraryCollectionMemberMatch(
        position: row["position"],
        serverItemID: row["serverItemId"],
        serverEpisodeID: row["serverEpisodeId"],
        fallbackTitle: row["fallbackTitle"],
        itemID: row["itemId"],
        episodeID: row["episodeId"])
    }
  }
}
