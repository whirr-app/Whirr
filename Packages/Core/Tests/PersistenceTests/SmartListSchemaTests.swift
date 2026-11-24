import Foundation
import GRDB
import Testing

@testable import Persistence

/// The v95 tables: what the database itself refuses, and what cascades.
@Suite struct SmartListSchemaTests {
  private func insertList(
    _ db: Database, position: Int = 0, overriding overrides: [String: String] = [:]
  ) throws {
    var values: [(String, String)] = [
      ("name", "'L'"), ("position", "\(position)"), ("showScope", "'all'"),
      ("includeUnplayed", "1"), ("includeInProgress", "1"), ("includePlayed", "0"),
      ("includeDownloaded", "1"), ("includeNotDownloaded", "1"), ("longerThanMinutes", "20"),
      ("shorterThanMinutes", "40"), ("sortOrder", "'newest'"), ("createdAt", "0"),
      ("updatedAt", "0"),
    ]
    for (key, value) in overrides {
      if let index = values.firstIndex(where: { $0.0 == key }) {
        values[index].1 = value
      } else {
        values.append((key, value))
      }
    }
    try db.execute(
      sql: """
        INSERT INTO smartList (\(values.map(\.0).joined(separator: ", ")))
        VALUES (\(values.map(\.1).joined(separator: ", ")))
        """)
  }

  private func refuses(_ overrides: [String: String]) throws -> Bool {
    let database = try AppDatabase.inMemory()
    do {
      try database.write { db in try insertList(db, overriding: overrides) }
      return false
    } catch let error as DatabaseError {
      return error.resultCode == .SQLITE_CONSTRAINT
    }
  }

  @Test func listChecksRejectBadValues() throws {
    #expect(try refuses([:]) == false)
    #expect(try refuses(["showScope": "'some'"]))
    #expect(try refuses(["sortOrder": "'random'"]))
    #expect(try refuses(["publishedWithinHours": "48"]))
    #expect(try refuses(["publishedWithinHours": "0"]))
    #expect(try refuses(["autoDownloadLimit": "7"]))
    #expect(try refuses(["includeUnplayed": "0", "includeInProgress": "0", "includePlayed": "0"]))
    #expect(try refuses(["includeDownloaded": "0", "includeNotDownloaded": "0"]))
    for hours in [24, 72, 168, 336, 744] {
      #expect(try refuses(["publishedWithinHours": "\(hours)"]) == false)
    }
    for limit in [5, 10, 20, 40, 100] {
      #expect(try refuses(["autoDownloadLimit": "\(limit)"]) == false)
    }
    #expect(try refuses(["includeUnplayed": "0", "includePlayed": "1"]) == false)
  }

  @Test func positionIsUnique() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in try insertList(db, position: 0) }
    #expect(throws: DatabaseError.self) {
      try database.write { db in try insertList(db, position: 0) }
    }
  }

  @Test func showRowsRejectBadSourceAndRoleAndKeepOneRowPerShow() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      try insertList(db)
      for (source, role) in [("other", "included"), ("native", "other")] {
        #expect(throws: DatabaseError.self) {
          try db.execute(
            sql: """
              INSERT INTO smartListShow (listId, source, showKey, role, titleSnapshot)
              VALUES (1, ?, 'k', ?, 't')
              """, arguments: [source, role])
        }
      }
      try db.execute(
        sql: """
          INSERT INTO smartListShow (listId, source, showKey, role, titleSnapshot)
          VALUES (1, 'native', 'k', 'included', 't')
          """)
      // The same key under the other source is a different show.
      try db.execute(
        sql: """
          INSERT INTO smartListShow (listId, source, showKey, role, titleSnapshot)
          VALUES (1, 'server', 'k', 'included', 't')
          """)
    }
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO smartListShow (listId, source, showKey, role, titleSnapshot)
            VALUES (1, 'native', 'k', 'excluded', 't')
            """)
      }
    }
  }

  @Test func theRunTableHoldsAtMostOneRowWithIDOne() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      try insertList(db, position: 0)
      try insertList(db, position: 1)
      try db.execute(sql: "INSERT INTO smartListRun (id, listId, startedAt) VALUES (1, 1, 0)")
    }
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(sql: "INSERT INTO smartListRun (id, listId, startedAt) VALUES (2, 2, 0)")
      }
    }
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(sql: "INSERT INTO smartListRun (id, listId, startedAt) VALUES (1, 2, 0)")
      }
    }
  }

  @Test func deletingAListCascadesToEveryChildTable() async throws {
    let database = try AppDatabase.inMemory()
    let store = SmartListStore(database: database)
    let list = try await store.create(
      name: "L",
      shows: [
        SmartListShowSelection(
          ref: .native(feedURL: "https://a.example/feed"), role: .included, titleSnapshot: "A")
      ])
    let other = try await store.create(name: "Other")
    try await SmartListRunStore(database: database).begin(listID: list.id)
    try await SmartListHiddenEpisodeStore(database: database).hide(
      listID: list.id, itemID: "rss:1", episodeID: "e")
    try await SmartListHiddenEpisodeStore(database: database).hide(
      listID: other.id, itemID: "rss:1", episodeID: "e")
    try await SmartListDownloadClaimStore(database: database).add(
      listID: list.id, itemID: "rss:1", episodeID: "e", accountID: nil)

    try await store.delete(id: list.id)

    let counts = try await database.readAsync { db in
      try ["smartListShow", "smartListRun", "smartListDownloadClaim"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
      } + [try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM smartListHiddenEpisode") ?? -1]
    }
    #expect(counts == [0, 0, 0, 1])
  }

  @Test func v95AddsTheNullableCompleteListColumn() throws {
    let database = try AppDatabase.inMemory()
    let column = try database.read { db in
      try db.columns(in: "podcastRefreshState").first { $0.name == "lastCompleteEpisodeListAt" }
    }
    #expect(column?.isNotNull == false)
  }
}
