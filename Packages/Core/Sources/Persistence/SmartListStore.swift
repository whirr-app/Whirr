import Foundation
import GRDB

public struct SmartList: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let name: String
  /// Dense `0..<count` across all lists.
  public let position: Int
  public let rules: SmartListRules
  public let createdAt: Date
  public let updatedAt: Date
}

public enum SmartListStoreError: Error, Equatable, Sendable {
  case listLimitReached
  /// Empty after trimming, or longer than `SmartListRules.maximumNameLength`.
  case invalidName
  case invalidRules(SmartListRulesError)
  case listNotFound
  /// The ids given to `reorder` are not exactly the stored lists.
  case invalidOrder
}

/// A show as a list names it. The key is portable: it survives unfollow and re-follow (native) and
/// logout and re-login (server), and matches nothing while the show is not on the device.
public struct SmartListShowRef: Sendable, Hashable {
  public let source: SmartListShowSource
  public let showKey: String

  public init(source: SmartListShowSource, showKey: String) {
    self.source = source
    self.showKey = showKey
  }

  /// `feedURL` exactly as `rssFeed.feedURL` stores it.
  public static func native(feedURL: String) -> SmartListShowRef {
    SmartListShowRef(source: .native, showKey: feedURL)
  }

  /// `"<account.serverUserId>|<item.serverItemId>"`. The account's own row id and client UUID are
  /// new on every login, so neither can be part of the key.
  public static func server(serverUserID: String, serverItemID: String) -> SmartListShowRef {
    SmartListShowRef(source: .server, showKey: "\(serverUserID)|\(serverItemID)")
  }
}

public struct SmartListShowSelection: Sendable, Equatable {
  public let ref: SmartListShowRef
  public let role: SmartListShowRole
  public let titleSnapshot: String

  public init(ref: SmartListShowRef, role: SmartListShowRole, titleSnapshot: String) {
    self.ref = ref
    self.role = role
    self.titleSnapshot = titleSnapshot
  }
}

/// Durable owner of smart lists, their rules, order and show rows. Run, hidden-episode and
/// download-claim state have their own stores.
public struct SmartListStore: Sendable {
  public static let maximumListCount = 50

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Reading

  /// Every list in display order.
  public func lists() async throws -> [SmartList] {
    try await database.readAsync { db in try Self.records(db).map(Self.value(from:)) }
  }

  /// Every list in display order, current value first, then on each change.
  public func observeLists() -> AsyncStream<[SmartList]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in try Self.records(db).map(Self.value(from:)) }
        .removeDuplicates())
  }

  public func list(id: Int64) async throws -> SmartList? {
    try await database.readAsync { db in
      try SmartListRecord.fetchOne(db, key: id).map(Self.value(from:))
    }
  }

  /// A list's show rows in the order they were chosen.
  public func shows(listID: Int64) async throws -> [SmartListShowRecord] {
    try await database.readAsync { db in
      try SmartListShowRecord.fetchAll(
        db, sql: "SELECT * FROM smartListShow WHERE listId = ? ORDER BY rowid",
        arguments: [listID])
    }
  }

  // MARK: - Writing

  /// Appends a list. Refuses the 51st with `listLimitReached`.
  @discardableResult
  public func create(
    name: String, rules: SmartListRules = .default, shows: [SmartListShowSelection] = [],
    now: Date = Date()
  ) async throws -> SmartList {
    let name = try Self.validated(name: name, rules: rules)
    return try await database.writeAsync { db in
      let count = try SmartListRecord.fetchCount(db)
      guard count < Self.maximumListCount else { throw SmartListStoreError.listLimitReached }
      var record = SmartListRecord(
        name: name, position: count, rules: rules, createdAt: now, updatedAt: now)
      try record.insert(db)
      if let id = record.id { try Self.replaceShows(db, listID: id, shows: shows) }
      return Self.value(from: record)
    }
  }

  public func update(id: Int64, name: String, rules: SmartListRules, now: Date = Date())
    async throws
  {
    let name = try Self.validated(name: name, rules: rules)
    try await database.writeAsync { db in
      let record = try Self.requireRecord(db, id: id)
      let replacement = SmartListRecord(
        id: id, name: name, position: record.position, rules: rules, createdAt: record.createdAt,
        updatedAt: now)
      try replacement.update(db)
    }
  }

  /// Updates the list's name and rules and replaces its shows in one transaction: either all of it
  /// is written or none of it.
  public func save(
    id: Int64, name: String, rules: SmartListRules, shows: [SmartListShowSelection],
    now: Date = Date()
  ) async throws {
    let name = try Self.validated(name: name, rules: rules)
    try await database.writeAsync { db in
      let record = try Self.requireRecord(db, id: id)
      try SmartListRecord(
        id: id, name: name, position: record.position, rules: rules, createdAt: record.createdAt,
        updatedAt: now
      ).update(db)
      try Self.replaceShows(db, listID: id, shows: shows)
    }
  }

  public func updateRules(id: Int64, rules: SmartListRules, now: Date = Date()) async throws {
    do { try rules.validate() } catch let error as SmartListRulesError {
      throw SmartListStoreError.invalidRules(error)
    }
    try await database.writeAsync { db in
      let record = try Self.requireRecord(db, id: id)
      let replacement = SmartListRecord(
        id: id, name: record.name, position: record.position, rules: rules,
        createdAt: record.createdAt, updatedAt: now)
      try replacement.update(db)
    }
  }

  public func rename(id: Int64, to name: String, now: Date = Date()) async throws {
    guard let name = SmartListRules.normalizedName(name) else {
      throw SmartListStoreError.invalidName
    }
    try await database.writeAsync { db in
      _ = try Self.requireRecord(db, id: id)
      try db.execute(
        sql: "UPDATE smartList SET name = ?, updatedAt = ? WHERE id = ?",
        arguments: [name, now, id])
    }
  }

  /// Replaces the list's show rows. A ref given twice keeps its last selection.
  public func setShows(listID: Int64, shows: [SmartListShowSelection], now: Date = Date())
    async throws
  {
    try await database.writeAsync { db in
      _ = try Self.requireRecord(db, id: listID)
      try Self.replaceShows(db, listID: listID, shows: shows)
      try db.execute(
        sql: "UPDATE smartList SET updatedAt = ? WHERE id = ?", arguments: [now, listID])
    }
  }

  /// Deletes the list; its shows, run, hidden episodes and claims cascade. The rest close up.
  public func delete(id: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM smartList WHERE id = ?", arguments: [id])
      try Self.renumber(db, ids: try Self.records(db).compactMap(\.id))
    }
  }

  /// Moves a list to `position`, clamped to the stored range.
  public func move(id: Int64, toPosition position: Int) async throws {
    try await database.writeAsync { db in
      var ids = try Self.records(db).compactMap(\.id)
      guard let index = ids.firstIndex(of: id) else { throw SmartListStoreError.listNotFound }
      ids.remove(at: index)
      ids.insert(id, at: min(max(position, 0), ids.count))
      try Self.renumber(db, ids: ids)
    }
  }

  /// Stores exactly this order. `ids` must be every stored list once.
  public func reorder(ids: [Int64]) async throws {
    try await database.writeAsync { db in
      let stored = try Self.records(db).compactMap(\.id)
      guard Set(ids) == Set(stored), ids.count == stored.count else {
        throw SmartListStoreError.invalidOrder
      }
      try Self.renumber(db, ids: ids)
    }
  }

  /// Rewrites each show row's `titleSnapshot` to the show's current title when the show is on the
  /// device and the title has changed. A show that is absent keeps the title it was chosen with.
  /// Returns the number of rows changed.
  @discardableResult
  public func refreshTitleSnapshots() async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE smartListShow
          SET titleSnapshot = (
            SELECT feed.title FROM rssFeed feed WHERE feed.feedURL = smartListShow.showKey)
          WHERE source = 'native' AND EXISTS (
            SELECT 1 FROM rssFeed feed
            WHERE feed.feedURL = smartListShow.showKey
              AND feed.title IS NOT NULL AND feed.title <> ''
              AND feed.title <> smartListShow.titleSnapshot)
          """)
      var changed = db.changesCount
      try db.execute(
        sql: """
          UPDATE smartListShow
          SET titleSnapshot = (
            SELECT item.title FROM item JOIN account ON account.id = item.accountId
            WHERE account.serverUserId || '|' || item.serverItemId = smartListShow.showKey
              -- Not a catalogue projection: this names the show a smart list already holds.
              AND item.mediaKind = 'podcast' AND item.softDeleted = 0 AND item.title <> ''
            LIMIT 1)
          WHERE source = 'server' AND EXISTS (
            SELECT 1 FROM item JOIN account ON account.id = item.accountId
            WHERE account.serverUserId || '|' || item.serverItemId = smartListShow.showKey
              AND item.mediaKind = 'podcast' AND item.softDeleted = 0 AND item.title <> ''
              AND item.title <> smartListShow.titleSnapshot)
          """)
      changed += db.changesCount
      return changed
    }
  }

  // MARK: - Helpers

  private static func validated(name: String, rules: SmartListRules) throws -> String {
    guard let name = SmartListRules.normalizedName(name) else {
      throw SmartListStoreError.invalidName
    }
    do { try rules.validate() } catch let error as SmartListRulesError {
      throw SmartListStoreError.invalidRules(error)
    }
    return name
  }

  private static func records(_ db: Database) throws -> [SmartListRecord] {
    try SmartListRecord.fetchAll(db, sql: "SELECT * FROM smartList ORDER BY position")
  }

  private static func requireRecord(_ db: Database, id: Int64) throws -> SmartListRecord {
    guard let record = try SmartListRecord.fetchOne(db, key: id) else {
      throw SmartListStoreError.listNotFound
    }
    return record
  }

  private static func value(from record: SmartListRecord) -> SmartList {
    SmartList(
      id: record.id ?? 0, name: record.name, position: record.position, rules: record.rules,
      createdAt: record.createdAt, updatedAt: record.updatedAt)
  }

  private static func replaceShows(
    _ db: Database, listID: Int64, shows: [SmartListShowSelection]
  ) throws {
    try db.execute(sql: "DELETE FROM smartListShow WHERE listId = ?", arguments: [listID])
    var latest: [SmartListShowRef: SmartListShowSelection] = [:]
    var order: [SmartListShowRef] = []
    for show in shows {
      if latest.updateValue(show, forKey: show.ref) == nil { order.append(show.ref) }
    }
    for ref in order {
      guard let show = latest[ref] else { continue }
      try SmartListShowRecord(
        listId: listID, source: ref.source, showKey: ref.showKey, role: show.role,
        titleSnapshot: show.titleSnapshot
      ).insert(db)
    }
  }

  /// The same two-pass move `NativeListeningQueueWriter` uses: park every row below every existing
  /// position, then write the final dense positions, so the UNIQUE index never sees a collision.
  private static func renumber(_ db: Database, ids: [Int64]) throws {
    let minimum = try Int.fetchOne(db, sql: "SELECT MIN(position) FROM smartList") ?? 0
    let offset = min(minimum, 0) - ids.count - 1
    for (index, id) in ids.enumerated() {
      try db.execute(
        sql: "UPDATE smartList SET position = ? WHERE id = ?", arguments: [offset - index, id])
    }
    for (index, id) in ids.enumerated() {
      try db.execute(
        sql: "UPDATE smartList SET position = ? WHERE id = ?", arguments: [index, id])
    }
  }
}
