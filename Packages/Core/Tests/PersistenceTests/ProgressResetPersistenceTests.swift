import Foundation
import GRDB
import Testing

@testable import Persistence

/// Persistence half of cross-device reset sync (ADR 0011) and the reset operation's persisted
/// phases: the v71 columns, row-identity recording, the stale-conflict sweep, the ebook
/// conflict slot, and the `progressReset` acknowledgement.
@Suite struct ProgressResetPersistenceTests {

  // MARK: - Migration

  @Test func v71AddsNullableColumnsThatExistingRowsReadAsNull() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v70")
    try queue.write { db in
      // Raw SQL: at v70 the account table predates later columns `AccountRecord` writes.
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES ('client', 'https://example.com', 'user', '2.36.1')
          """)
      let accountId = db.lastInsertedRowID
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "lib", mediaType: "book", name: "Library")
      try library.insert(db)
      try db.execute(
        sql: """
          INSERT INTO item (accountId, libraryId, serverItemId, mediaKind, title, sortTitle)
          VALUES (?, ?, 'item', 'book', 'Title', 'title')
          """,
        arguments: [accountId, library.id!])
      let itemId = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO mediaProgress
            (accountId, itemId, currentTime, isFinished, hideFromContinueListening, localSequence,
             origin, originKey)
          VALUES (?, ?, 1200, 0, 0, 3, 'server', 'server')
          """,
        arguments: [accountId, itemId])
      try db.execute(
        sql: """
          INSERT INTO progressConflict
            (accountId, itemId, serverCurrentTime, serverIsFinished, detectedAt)
          VALUES (?, ?, 0, 0, ?)
          """,
        arguments: [accountId, itemId, Date(timeIntervalSince1970: 1_000)])
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let progress = try #require(try MediaProgressRecord.fetchOne(db))
      #expect(progress.serverProgressId == nil)
      #expect(progress.currentTime == 1_200)
      let conflict = try #require(try ProgressConflictRecord.fetchOne(db))
      #expect(conflict.serverEbookProgress == nil)
      let outboxColumns = Set(try db.columns(in: "outboxOperation").map(\.name))
      #expect(
        outboxColumns.isSuperset(of: [
          "payloadResetMedium", "payloadResetPhase", "payloadRestoreProgress",
        ]))
    }
  }

  // MARK: - Row identity and the stale sweep

  @Test func aPulledRowRecordsItsServerIdEvenWhenLocalKeepsItsPosition() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, serverProgressId: nil)

    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [
        fixture.resolution(
          currentTime: 30, serverProgressId: "row-x",
          resolution: .init(
            audioPosition: .keepLocal, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    let stored = try #require(try await fixture.progress())
    #expect(stored.serverProgressId == "row-x")
    #expect(stored.currentTime == 1_200)
  }

  @Test func anEvidencedResetZeroesOnlyTheResetMediumAndKeepsTheLocalSequence() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(
      currentTime: 1_200, ebookProgress: 0.4, serverProgressId: "row-x", localSequence: 9)
    try await fixture.seedConflict()

    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [
        fixture.resolution(
          currentTime: 0, serverUpdatedAt: nil, serverProgressId: nil,
          resolution: .init(
            audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .applyServer,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    let stored = try #require(try await fixture.progress())
    #expect(stored.currentTime == 0)
    #expect(stored.ebookProgress == 0.4)
    #expect(stored.isFinished == false)
    #expect(stored.localSequence == 9)
    #expect(stored.serverProgressId == nil)
    #expect(stored.serverUpdatedAt == nil)
    #expect(try await fixture.conflicts().isEmpty)
  }

  @Test func aLaterPullThatAppliesAFieldSweepsTheStaleConflict() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, serverProgressId: "row-x")
    try await fixture.seedConflict()

    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [
        fixture.resolution(
          currentTime: 900, serverProgressId: "row-x",
          resolution: .init(
            audioPosition: .applyServer, ebookPosition: .keepLocal, sharedFinish: .applyServer,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    #expect(try await fixture.conflicts().isEmpty)
    #expect(try await fixture.progress()?.currentTime == 900)
  }

  @Test func aVisibilityOnlyApplyLeavesTheConflictOpen() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, serverProgressId: "row-x")
    try await fixture.seedConflict()

    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [
        fixture.resolution(
          currentTime: 0, serverProgressId: "row-x",
          resolution: .init(
            audioPosition: .keepLocal, ebookPosition: .keepLocal, sharedFinish: .keepLocal,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])

    #expect(try await fixture.conflicts().count == 1)
  }

  @Test func aConflictReRecordedByTheSamePullSurvivesTheSweep() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, serverProgressId: "row-x")
    try await fixture.seedConflict()

    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [
        fixture.resolution(
          currentTime: 0, serverProgressId: "row-x",
          resolution: .init(
            audioPosition: .needsResolution, ebookPosition: .keepLocal, sharedFinish: .applyServer,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [
        MediaProgressDAO.PulledCompositeConflict(
          identity: fixture.identity, serverCurrentTime: 0, serverIsFinished: false,
          serverUpdatedAt: Date(timeIntervalSince1970: 3_000),
          detectedAt: Date(timeIntervalSince1970: 3_100))
      ])

    let conflicts = try await fixture.conflicts()
    #expect(conflicts.count == 1)
    #expect(conflicts.first?.detectedAt == Date(timeIntervalSince1970: 3_100))
  }

  // MARK: - Ebook take-server

  @Test func takingTheServerSideOfAnEbookConflictWritesTheEbookPosition() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 300, ebookProgress: 0.6, serverProgressId: "row-x")
    try await fixture.dao.applyPulledCompositeProgressAsync(
      accountId: fixture.accountId,
      resolutions: [],
      conflicts: [
        MediaProgressDAO.PulledCompositeConflict(
          identity: fixture.identity, serverCurrentTime: 300, serverIsFinished: false,
          serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
          detectedAt: Date(timeIntervalSince1970: 2_100), serverEbookProgress: 0,
          serverEbookLocation: "epubcfi(/6/2!/4/2/1:0)")
      ])
    let conflict = try #require(try await fixture.conflicts().first)
    #expect(conflict.serverEbookProgress == 0)

    try await fixture.dao.resolveConflictTakingServerAsync(conflictId: try #require(conflict.id))

    let stored = try #require(try await fixture.progress())
    #expect(stored.ebookProgress == 0)
    #expect(stored.ebookLocation == "epubcfi(/6/2!/4/2/1:0)")
    #expect(stored.readingPositionJSON == nil)
    #expect(stored.currentTime == 300)
    #expect(try await fixture.conflicts().isEmpty)
  }

  @Test func takingTheServerSideOfAnAudioConflictLeavesTheEbookPosition() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, ebookProgress: 0.6, serverProgressId: "row-x")
    try await fixture.seedConflict()
    let conflict = try #require(try await fixture.conflicts().first)

    try await fixture.dao.resolveConflictTakingServerAsync(conflictId: try #require(conflict.id))

    let stored = try #require(try await fixture.progress())
    #expect(stored.currentTime == 0)
    #expect(stored.ebookProgress == 0.6)
  }

  // MARK: - The reset operation's phases and acknowledgement

  @Test func theFirstCaptureIsKeptAndThePhasesAdvance() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 0, serverProgressId: "row-x")
    let intents = try ItemProgressIntentStore(database: fixture.database)
    try await intents.resetProgressAsync(itemID: fixture.serverItemId, originKey: "device")
    let outbox = try OutboxStore(database: fixture.database)
    let operationId = try #require(try await fixture.resetOperation()?.id)

    try await outbox.recordProgressResetCaptureAsync(
      operationId: operationId,
      capture: ProgressResetCapture(ebookProgress: 0.4, ebookLocation: "epubcfi(/6/2)"))
    try await outbox.recordProgressResetCaptureAsync(
      operationId: operationId, capture: ProgressResetCapture(ebookProgress: 0.9))
    var operation = try #require(try await fixture.resetOperation())
    #expect(operation.progressResetPhase == .delete)
    #expect(
      operation.progressResetCapture
        == ProgressResetCapture(
          ebookProgress: 0.4, ebookLocation: "epubcfi(/6/2)"))

    try await outbox.advanceProgressResetToRestoreAsync(operationId: operationId)
    operation = try #require(try await fixture.resetOperation())
    #expect(operation.progressResetPhase == .restore)
    #expect(operation.progressResetCapture.ebookProgress == 0.4)
  }

  @Test func acknowledgingAResetClearsTheObservedServerRow() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(
      currentTime: 1_200, ebookProgress: 0.4, serverProgressId: "row-x", localSequence: 4)
    let intents = try ItemProgressIntentStore(database: fixture.database)
    try await intents.resetProgressAsync(itemID: fixture.serverItemId, originKey: "device")
    let operationId = try #require(try await fixture.resetOperation()?.id)

    try await fixture.dao.acknowledgeProgressResetAsync(operationId: operationId)

    let stored = try #require(try await fixture.progress())
    #expect(stored.serverProgressId == nil)
    #expect(stored.serverUpdatedAt == nil)
    #expect(stored.currentTime == 0)
    #expect(stored.ebookProgress == 0.4)
    #expect(stored.isFinished == false)
    #expect(try await fixture.resetOperation() == nil)
  }

  @Test func aLocalWriteDuringTheResetSurvivesItsAcknowledgement() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(currentTime: 1_200, serverProgressId: "row-x", localSequence: 4)
    let intents = try ItemProgressIntentStore(database: fixture.database)
    try await intents.resetProgressAsync(itemID: fixture.serverItemId, originKey: "device")
    let operationId = try #require(try await fixture.resetOperation()?.id)
    _ = try await fixture.dao.writeLocalAsync(
      accountId: fixture.accountId, identity: fixture.identity,
      field: .audio(currentTime: 45, isFinished: false), originKey: "device")

    try await fixture.dao.acknowledgeProgressResetAsync(operationId: operationId)

    let stored = try #require(try await fixture.progress())
    #expect(stored.currentTime == 45)
    #expect(stored.serverProgressId == nil)
  }

  @Test func anEbookResetAcknowledgementClearsOnlyTheEbookMedium() async throws {
    let fixture = try await Fixture()
    try await fixture.seedProgress(
      currentTime: 1_200, ebookProgress: 0.4, serverProgressId: "row-x", localSequence: 4)
    let intents = try ItemProgressIntentStore(database: fixture.database)
    try await intents.resetEbookProgressAsync(itemID: fixture.serverItemId, originKey: "device")
    let operationId = try #require(try await fixture.resetOperation()?.id)

    try await fixture.dao.acknowledgeProgressResetAsync(operationId: operationId)

    let stored = try #require(try await fixture.progress())
    #expect(stored.currentTime == 1_200)
    #expect(stored.ebookProgress == 0)
    #expect(stored.serverProgressId == nil)
  }
}

private struct Fixture {
  let database: AppDatabase
  let dao: MediaProgressDAO
  let accountId: Int64
  let itemId: Int64
  let serverItemId = "server-item"

  var identity: MediaProgressIdentity { .item(itemId: itemId) }

  init() async throws {
    database = try AppDatabase.inMemory()
    dao = MediaProgressDAO(database: database)
    let serverItemId = serverItemId
    (accountId, itemId) = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "device", serverBaseURL: "https://example.com", serverUserId: "user",
        serverVersion: "2.36.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemId,
        mediaKind: "book", title: "Title", sortTitle: "title")
      try item.insert(db)
      return (account.id!, item.id!)
    }
  }

  func seedProgress(
    currentTime: Double, ebookProgress: Double? = nil, serverProgressId: String?,
    localSequence: Int64 = 3
  ) async throws {
    let accountId = accountId
    let itemId = itemId
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: currentTime, isFinished: false,
        serverUpdatedAt: Date(timeIntervalSince1970: 1_000), localSequence: localSequence,
        origin: .server, originKey: ProgressOrigin.serverOriginKey,
        readingPositionJSON: ebookProgress == nil ? nil : "{\"href\":\"c.xhtml\"}",
        ebookProgress: ebookProgress, serverProgressId: serverProgressId)
      try record.insert(db)
    }
  }

  func seedConflict() async throws {
    _ = try await dao.recordConflictAsync(
      accountId: accountId, identity: identity, serverCurrentTime: 0, serverIsFinished: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      detectedAt: Date(timeIntervalSince1970: 2_100))
  }

  func resolution(
    currentTime: Double,
    serverUpdatedAt: Date? = Date(timeIntervalSince1970: 3_000),
    serverProgressId: String?,
    resolution: MediaProgressCompositeResolution
  ) -> MediaProgressDAO.PulledCompositeResolution {
    MediaProgressDAO.PulledCompositeResolution(
      identity: identity, currentTime: currentTime, isFinished: false, ebookProgress: nil,
      ebookLocation: nil, hideFromContinueListening: false, serverUpdatedAt: serverUpdatedAt,
      serverProgressId: serverProgressId, resolution: resolution)
  }

  func progress() async throws -> MediaProgressRecord? {
    try await dao.fetchCurrentAsync(accountId: accountId, identity: identity)
  }

  func conflicts() async throws -> [ProgressConflictRecord] {
    try await dao.fetchOpenConflictsAsync(accountId: accountId)
  }

  func resetOperation() async throws -> OutboxOperationRecord? {
    try await database.readAsync { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.progressReset.rawValue)
        .fetchOne(db)
    }
  }
}
