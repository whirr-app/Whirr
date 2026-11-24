import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct ItemQuarantineMigrationTests {
  @Test("v49 terminalizes only reserved-identity work and records an audit marker")
  func populatedV48StoreMigratesWithoutWithholdingLegitimateWork() throws {
    let queue = try Self.v48Database()
    let fixture = try Self.insertFixture(into: queue)

    try SchemaV1.migrator().migrate(queue, upTo: "v49")

    try queue.read { db in
      let fetchedMarker = try Row.fetchOne(
        db, sql: "SELECT * FROM itemQuarantine WHERE itemId = ?",
        arguments: [fixture.quarantinedItemID])
      let marker = try #require(fetchedMarker)
      #expect(marker["accountId"] as Int64 == fixture.accountID)
      #expect(marker["serverItemId"] as String == "rss:7")
      #expect(marker["reason"] as String == "reservedPodcastSourceIdentity")
      #expect(marker["terminalizedOperationCount"] as Int == 2)

      let states = try Row.fetchAll(
        db,
        sql: "SELECT entityKey, state, deadLetterReason FROM outboxOperation ORDER BY entityKey"
      )
      #expect(states.count == 3)
      #expect(states[0]["entityKey"] as String == "ordinary-item")
      #expect(states[0]["state"] as String == OutboxOperationState.pending.rawValue)
      #expect(states[0]["deadLetterReason"] as String? == nil)
      for row in states.dropFirst() {
        #expect(row["state"] as String == OutboxOperationState.deadLetter.rawValue)
        #expect(row["deadLetterReason"] as String == OutboxStore.quarantinedItemDeadLetterReason)
      }

      #expect(try ItemRecord.fetchOne(db, key: fixture.quarantinedItemID) != nil)
      #expect(
        try MediaProgressRecord
          .filter(Column("itemId") == fixture.quarantinedItemID)
          .fetchCount(db) == 1,
        "migration preserves legitimate local state while making outbound work terminal")
    }
  }

  @Test("a quarantine terminal is not surfaced or made runnable again")
  func quarantinedWorkCannotBeRequeued() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.insertCurrentFixture(into: database)
    let store = try OutboxStore(database: database)

    let terminal = try #require(
      try database.read { db in
        try OutboxOperationRecord
          .filter(Column("entityKey") == "rss:7")
          .fetchOne(db)
      })
    let operationID = try #require(terminal.id)
    #expect(throws: OutboxStoreError.self) {
      _ = try store.transition(operationId: operationID, to: .pending)
    }
    #expect(try store.fetchDeadLetters(accountId: fixture.accountID).isEmpty)
    #expect(try store.fetchQueued(accountId: fixture.accountID, entityKey: "rss:7").isEmpty)
    #expect(
      try store.fetchQueued(accountId: fixture.accountID, entityKey: "ordinary-item").count == 1,
      "ordinary soft deletion is reversible and must not silently withhold runnable work")
  }

  @Test("every supported outbox enqueue path immediately terminalizes quarantined work")
  func postMigrationEnqueuesCannotRecreateRunnableWork() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.insertCurrentFixture(into: database)
    let store = try OutboxStore(database: database)
    let payload = OutboxSessionPayload(
      currentTime: 30, accumulatedDeltaSeconds: 5, durationSeconds: 120)

    let operations = try [
      store.enqueueProgress(
        accountId: fixture.accountID, entityKey: "rss:7", podcastEpisodeId: nil,
        coalescingKey: "post-migration-progress", localSequence: 2,
        payload: OutboxProgressPayload(
          currentTime: 30, isFinished: false, accumulatedDeltaSeconds: 0)),
      store.enqueueSessionSync(
        accountId: fixture.accountID, playbackSessionId: fixture.sessionID,
        entityKey: "session:quarantined", coalescingKey: "session:quarantined:sync",
        localSequence: 3, payload: payload),
      store.enqueueSessionClose(
        accountId: fixture.accountID, playbackSessionId: fixture.sessionID,
        entityKey: "session:quarantined", coalescingKey: "session:quarantined:close",
        localSequence: 4, payload: payload),
      store.enqueueLocalSessionUpload(
        accountId: fixture.accountID, playbackSessionId: fixture.sessionID,
        entityKey: "session:quarantined", coalescingKey: "session:quarantined:local",
        localSequence: 5, payload: payload),
    ]

    #expect(operations.allSatisfy { $0.state == .deadLetter })
    #expect(
      operations.allSatisfy {
        $0.deadLetterReason == OutboxStore.quarantinedItemDeadLetterReason
      })
    #expect(try store.distinctQueuedEntityKeys(accountId: fixture.accountID).isEmpty == false)
    #expect(try store.fetchQueued(accountId: fixture.accountID, entityKey: "rss:7").isEmpty)
    #expect(
      try store.fetchQueued(accountId: fixture.accountID, entityKey: "session:quarantined")
        .isEmpty)
    #expect(try store.fetchDeadLetters(accountId: fixture.accountID).isEmpty)
    let markerCount = try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT terminalizedOperationCount FROM itemQuarantine WHERE itemId = ?",
        arguments: [fixture.quarantinedItemID])
    }
    #expect(markerCount == 5)
    #expect(
      try store.fetchQueued(accountId: fixture.accountID, entityKey: "ordinary-item").count == 1,
      "ordinary soft-deleted work remains runnable")
  }

  @Test("marking a quarantined session gone cannot strand new pending work or block reaping")
  func markSessionGoneTerminalizesItsReplacementProgress() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.insertCurrentFixture(into: database)
    let store = try OutboxStore(database: database)
    _ = try store.enqueueSessionSync(
      accountId: fixture.accountID, playbackSessionId: fixture.sessionID,
      entityKey: "session:quarantined", coalescingKey: "session:quarantined:before-gone",
      localSequence: 2,
      payload: OutboxSessionPayload(
        currentTime: 42, accumulatedDeltaSeconds: 5, durationSeconds: 120))

    let outcome = try PlaybackSessionStore(database: database, outbox: store).markSessionGone(
      sessionId: fixture.sessionID, now: Date(timeIntervalSince1970: 1_700_000_100))
    #expect(outcome?.itemServerId == "rss:7")
    try database.read { db in
      #expect(
        try OutboxOperationRecord
          .filter(Column("playbackSessionId") == fixture.sessionID)
          .fetchCount(db) == 0)
      let replacements =
        try OutboxOperationRecord
        .filter(Column("coalescingKey") == "session-gone:quarantined-session")
        .fetchAll(db)
      #expect(replacements.count == 1)
      #expect(replacements.first?.state == .deadLetter)
      #expect(
        replacements.first?.deadLetterReason == OutboxStore.quarantinedItemDeadLetterReason)
    }

    try await database.writeAsync { db in
      _ = try PlaybackSessionRecord.deleteOne(db, key: fixture.sessionID)
    }
    let summary = try SyncRunDAO(database: database).inferDeletions(
      libraryId: fixture.libraryID, generation: 2)
    #expect(summary.hardDeletedCount == 1)
    #expect(
      try database.read { db in
        try ItemRecord.fetchOne(db, key: fixture.quarantinedItemID)
      } == nil)
  }

  private struct Fixture {
    let accountID: Int64
    let libraryID: Int64
    let quarantinedItemID: Int64
    let sessionID: Int64
  }

  private static func v48Database() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v48")
    return queue
  }

  private static func insertFixture(into queue: DatabaseQueue) throws -> Fixture {
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES ('quarantine-migration-client', 'https://example.test', 'user', '2.26.0')
          """)
      let accountID = db.lastInsertedRowID
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      let libraryID = try #require(library.id)

      try db.execute(
        sql: """
          INSERT INTO item
            (accountId, libraryId, serverItemId, mediaKind, title, sortTitle, lastSeenGeneration,
             softDeleted)
          VALUES (?, ?, 'rss:7', 'podcast', 'Invalid collision', 'invalid collision', 1, 1)
          """,
        arguments: [accountID, libraryID])
      let quarantinedItemID = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO item
            (accountId, libraryId, serverItemId, mediaKind, title, sortTitle, lastSeenGeneration,
             softDeleted)
          VALUES (?, ?, 'ordinary-item', 'book', 'Ordinary', 'ordinary', 1, 1)
          """,
        arguments: [accountID, libraryID])

      // Rows go in as v48 columns, not through today's records, which carry later columns.
      try db.execute(
        sql: """
          INSERT INTO mediaProgress
            (accountId, itemId, podcastEpisodeId, currentTime, isFinished,
             hideFromContinueListening, localSequence, origin, originKey)
          VALUES (?, ?, NULL, 42, 0, 0, 1, 'local', 'quarantine-migration-client')
          """,
        arguments: [accountID, quarantinedItemID])

      var session = PlaybackSessionRecord(
        accountId: accountID, clientSessionId: "quarantined-session", serverSessionId: nil,
        itemId: quarantinedItemID, podcastEpisodeId: nil,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001), listenedDeltaSeconds: 10,
        isOffline: true, globalPosition: 42, state: .closedAwaitingUpload, lastLocalSequence: 1)
      try session.insert(db)

      let operations:
        [(
          id: String, entity: String, kind: OutboxOperationKind, sequence: Int,
          time: Double, delta: Double, sessionID: Int64?
        )] = [
          ("reserved-progress", "rss:7", .progress, 1, 42, 10, nil),
          ("reserved-session", "session:quarantined-session", .localSessionUpload, 2, 42, 10, session.id),
          ("ordinary-progress", "ordinary-item", .progress, 3, 12, 3, nil),
        ]
      for operation in operations {
        let isFinished: Bool? = operation.kind == .progress ? false : nil
        try db.execute(
          sql: """
            INSERT INTO outboxOperation
              (accountId, clientOperationId, entityKey, podcastEpisodeId, operationKind,
               coalescingKey, payloadVersion, localSequence, payloadCurrentTime,
               payloadIsFinished, payloadAccumulatedDeltaSeconds, playbackSessionId, state)
            VALUES (?, ?, ?, NULL, ?, ?, 1, ?, ?, ?, ?, ?, 'pending')
            """,
          arguments: [
            accountID, operation.id, operation.entity, operation.kind.rawValue, operation.id,
            operation.sequence, operation.time, isFinished, operation.delta, operation.sessionID,
          ])
      }
      return Fixture(
        accountID: accountID, libraryID: libraryID, quarantinedItemID: quarantinedItemID,
        sessionID: try #require(session.id))
    }
  }

  private static func insertCurrentFixture(into database: AppDatabase) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "quarantine-current-client", serverBaseURL: "https://example.test",
        serverUserId: "user", serverVersion: "2.26.0")
      try account.insert(db)
      let accountID = try #require(account.id)
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      let libraryID = try #require(library.id)
      var quarantined = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: "rss:7",
        mediaKind: "podcast", title: "Invalid", sortTitle: "invalid", softDeleted: true)
      try quarantined.insert(db)
      let quarantinedItemID = try #require(quarantined.id)
      var ordinary = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: "ordinary-item",
        mediaKind: "book", title: "Ordinary", sortTitle: "ordinary", softDeleted: true)
      try ordinary.insert(db)

      try db.execute(
        sql: """
          INSERT INTO itemQuarantine (
            itemId, accountId, serverItemId, reason, quarantinedAt, terminalizedOperationCount
          ) VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          quarantinedItemID, accountID, "rss:7", "reservedPodcastSourceIdentity",
          Date(timeIntervalSince1970: 1_700_000_000), 1,
        ])
      var session = PlaybackSessionRecord(
        accountId: accountID, clientSessionId: "quarantined-session", serverSessionId: "server-session",
        itemId: quarantinedItemID, podcastEpisodeId: nil,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001), listenedDeltaSeconds: 10,
        isOffline: false, globalPosition: 42, duration: 120, state: .active,
        lastLocalSequence: 1)
      try session.insert(db)
      let sessionID = try #require(session.id)
      var terminal = OutboxOperationRecord(
        accountId: accountID, clientOperationId: "terminal", entityKey: "rss:7",
        podcastEpisodeId: nil, operationKind: OutboxOperationKind.progress.rawValue,
        coalescingKey: "terminal", payloadVersion: 1, localSequence: 1, state: .deadLetter,
        deadLetterReason: OutboxStore.quarantinedItemDeadLetterReason)
      try terminal.insert(db)
      var ordinaryOperation = OutboxOperationRecord(
        accountId: accountID, clientOperationId: "ordinary", entityKey: "ordinary-item",
        podcastEpisodeId: nil, operationKind: OutboxOperationKind.progress.rawValue,
        coalescingKey: "ordinary", payloadVersion: 1, localSequence: 2)
      try ordinaryOperation.insert(db)
      return Fixture(
        accountID: accountID, libraryID: libraryID, quarantinedItemID: quarantinedItemID,
        sessionID: sessionID)
    }
  }
}
