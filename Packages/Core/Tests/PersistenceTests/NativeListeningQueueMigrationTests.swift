import GRDB
import Testing

@testable import Persistence

@Suite struct NativeListeningQueueMigrationTests {
  @Test func populatedSplitPreservesSourceIDsAndOneDenseOrder() throws {
    let queue = try Self.seed()
    try SchemaV1.migrator().migrate(queue)
    try queue.read { db throws -> Void in
      let native = try Row.fetchOne(db, sql: "SELECT * FROM rssListeningQueueEntry")!
      let abs = try Row.fetchOne(db, sql: "SELECT * FROM listeningQueueEntry")!
      #expect(native["id"] as Int64 == 10)
      #expect(native["position"] as Int == 0)
      #expect(abs["id"] as Int64 == 20)
      #expect(abs["position"] as Int == 1)
      #expect(try db.foreignKeys(on: "rssListeningQueueEntry").contains { $0.destinationTable == "account" } == false)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test(arguments: [
    SchemaV1.NativeListeningQueueMigrationCheckpoint.afterCopy,
    SchemaV1.NativeListeningQueueMigrationCheckpoint.afterDrop,
    SchemaV1.NativeListeningQueueMigrationCheckpoint.afterSwap,
  ])
  func everyDestructiveCheckpointRollsBack(_ failure: SchemaV1.NativeListeningQueueMigrationCheckpoint) throws {
    enum Failure: Error { case injected }
    let queue = try Self.seed()
    #expect(throws: Failure.injected) {
      try SchemaV1.migrator(nativeListeningQueueMigrationCheckpoint: { point in
        if point == failure { throw Failure.injected }
      }).migrate(queue)
    }
    try queue.read { db throws -> Void in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") == 2)
      #expect(try db.columns(in: "listeningQueueEntry").map(\.name).contains("rssEpisodeId"))
      #expect(try db.tableExists("rssListeningQueueEntry") == false)
      #expect(try db.tableExists("listeningQueueEntry_v59") == false)
    }
  }

  private static func seed() throws -> DatabaseQueue {
    let queue = try NativeSavedShelfMigrationTests.seededDatabase()
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry (id, accountId, rssEpisodeId, position) VALUES (10, 1, 1, 0);
          INSERT INTO listeningQueueEntry (id, accountId, itemId, position) VALUES (20, 1, 1, 1);
          """)
    }
    return queue
  }
}
