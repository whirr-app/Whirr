import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct NativePodcastSettingsStoreTests {
  @Test func defaultsAndActivationFloorSurviveAccountDeletion() async throws {
    let database = try AppDatabase.inMemory()
    #expect(await NativePodcastSettingsStore(database: database).fetchGlobalSettings() == .defaults)
    try await database.writeAsync { db in
      _ = try AccountRecord(
        clientUUID: "native-survival", serverBaseURL: "https://abs.invalid",
        serverUserId: "u", serverVersion: "1"
      ).inserted(db)
    }
    let stamp = Date(timeIntervalSince1970: 100)
    let store = NativePodcastSettingsStore(database: database, now: { stamp })
    try await store.setGlobalAutoDownloadEnabled(true)
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM account") }
    let value = await store.fetchGlobalSettings()
    #expect(value.autoDownloadEnabled && value.enabledAt == stamp)
  }

  @Test func migrationBackfillsOnlyOneAccountValue() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v57")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES ('c', 'https://e', 'u', '1')
          """)
      let accountID = db.lastInsertedRowID
      try PodcastSettingsRecord(accountId: accountID, autoDownloadEnabled: true, keepLatestCount: 9)
        .insert(db)
      try SchemaV1.migrateNativePodcastSettings(db)
    }
    let value = try queue.read { db in try NativePodcastSettingsRecord.fetchOne(db, key: 1)?.settings }
    #expect(value?.autoDownloadEnabled == true && value?.keepLatestCount == 9)
  }

  @Test func ambiguousValuesUseDefaults() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v57")
    try queue.write { db in
      for i in 0..<2 {
        try db.execute(
          sql: """
            INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
            VALUES (?, ?, ?, '1')
            """,
          arguments: ["c\(i)", "https://e\(i)", "u\(i)"])
        let accountID = db.lastInsertedRowID
        try PodcastSettingsRecord(accountId: accountID, autoDownloadEnabled: true).insert(db)
      }
      try SchemaV1.migrateNativePodcastSettings(db)
    }
    let value = try queue.read { db in try NativePodcastSettingsRecord.fetchOne(db, key: 1)?.settings }
    #expect(value == .defaults)
  }
}
