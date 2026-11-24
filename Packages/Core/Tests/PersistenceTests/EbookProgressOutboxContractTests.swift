import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The durable half of ebook progress sync. The reader's local row and its server mutation must
/// be one durable transaction, and the two ebook operation kinds must never be mistaken for
/// audio progress.
@Suite("Ebook progress outbox contract")
struct EbookProgressOutboxContractTests {

  @Test("ebook position write and outbox row commit atomically")
  func ebookPositionWriteAndOutboxRowCommitAtomically() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId, serverItemId) = try await makeItem(in: database)
    let dao = MediaProgressDAO(database: database)

    let result = try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: accountId,
      identity: .item(itemId: itemId),
      entityKey: serverItemId,
      readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
      ebookProgress: 0.42,
      ebookLocation: nil,
      originKey: "fixture-client")

    let storedProgress = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    let rows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("accountId") == accountId)
        .fetchAll(db)
    }

    #expect(storedProgress.readingPositionJSON == "{\"href\":\"Text/chapter.xhtml\"}")
    #expect(storedProgress.ebookProgress == 0.42)
    #expect(storedProgress.currentTime == 0)
    #expect(rows.count == 1)
    #expect(rows[0].id == result.operation.id)
    #expect(rows[0].operationKind == OutboxOperationKind.ebookPosition.rawValue)
    #expect(rows[0].payloadVersion == 1)
    #expect(rows[0].payloadEbookProgress == 0.42)
    #expect(rows[0].payloadEbookLocation == nil)
    #expect(rows[0].payloadCurrentTime == nil)
    #expect(rows[0].payloadIsFinished == nil)
    #expect(rows[0].coalescingKey == "ebook-position:\(accountId):\(serverItemId)")

    // Reusing the position's client id for a different operation kind forces the outbox insert to
    // fail after the local finish mutation has been staged. The transaction must roll both back.
    await #expect(throws: (any Error).self) {
      _ = try await dao.markEbookAsFinishedAndEnqueueAsync(
        accountId: accountId,
        identity: .item(itemId: itemId),
        entityKey: serverItemId,
        originKey: "fixture-client",
        clientOperationId: result.operation.clientOperationId)
    }
    let rolledBackProgress = try #require(
      await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId)))
    #expect(rolledBackProgress.isFinished == false)
    #expect(try database.read { db in try OutboxOperationRecord.fetchAll(db).count } == 1)
  }

  @Test("ebook position bursts coalesce by account and item with newest position")
  func ebookPositionBurstsCoalesceByAccountAndItemWithNewestPosition() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId, serverItemId) = try await makeItem(in: database)
    let dao = MediaProgressDAO(database: database)

    let first = try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
      readingPositionJSON: "{\"href\":\"one.xhtml\"}", ebookProgress: 0.1,
      ebookLocation: nil, originKey: "fixture-client")
    let second = try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
      readingPositionJSON: "{\"href\":\"two.xhtml\"}", ebookProgress: 0.8,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)", originKey: "fixture-client")

    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(first.operation.id == second.operation.id)
    #expect(rows.count == 1)
    #expect(rows[0].payloadEbookProgress == 0.8)
    #expect(rows[0].payloadEbookLocation == "epubcfi(/6/4!/4/2/1:0)")
    #expect(rows[0].localSequence == second.progress.localSequence)
    #expect(
      try await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemId))?.readingPositionJSON
        == "{\"href\":\"two.xhtml\"}")
  }

  @Test("ebook position, audio progress, and shared finish never coalesce with one another")
  func ebookPositionAudioProgressAndSharedFinishNeverCoalesceWithOneAnother() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId, serverItemId) = try await makeItem(in: database)
    let dao = MediaProgressDAO(database: database)
    let outbox = try OutboxStore(database: database)

    let ebook = try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
      readingPositionJSON: "{\"href\":\"one.xhtml\"}", ebookProgress: 0.1,
      ebookLocation: nil, originKey: "fixture-client")
    let audio = try outbox.enqueueProgress(
      accountId: accountId, entityKey: serverItemId, podcastEpisodeId: nil,
      coalescingKey: "audio-segment", localSequence: ebook.progress.localSequence + 1,
      payload: OutboxProgressPayload(currentTime: 12, isFinished: false, accumulatedDeltaSeconds: 0))
    let finish = try await dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
      originKey: "fixture-client")
    let secondFinish = try await dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
      originKey: "fixture-client")

    let rows = try outbox.fetchQueued(accountId: accountId, entityKey: serverItemId)
    #expect(
      Set(rows.map(\.operationKind)) == [
        OutboxOperationKind.ebookPosition.rawValue,
        OutboxOperationKind.progress.rawValue,
        OutboxOperationKind.sharedFinish.rawValue,
      ])
    #expect(ebook.operation.id != audio.id)
    #expect(finish.operation.id != secondFinish.operation.id)
    #expect(rows.filter { $0.operationKind == OutboxOperationKind.sharedFinish.rawValue }.count == 2)
    #expect(rows.first { $0.id == finish.operation.id }?.payloadEbookProgress == nil)
    #expect(rows.first { $0.id == finish.operation.id }?.payloadCurrentTime == nil)
    #expect(rows.first { $0.id == finish.operation.id }?.payloadIsFinished == nil)

    let positionSequence = try #require(
      rows.first { $0.operationKind == OutboxOperationKind.ebookPosition.rawValue }?.localSequence)
    #expect(
      rows.filter { $0.operationKind == OutboxOperationKind.sharedFinish.rawValue }.allSatisfy {
        $0.localSequence > positionSequence
      })
  }

  @Test("queued ebook position survives a fresh store over the same database")
  func queuedEbookPositionSurvivesFreshStoreOverSameDatabase() async throws {
    try await withOnDiskDatabases { scope in
      let database = try scope.open()
      let (accountId, itemId, serverItemId) = try await makeItem(in: database)
      _ = try await MediaProgressDAO(database: database).writeEbookPositionAndEnqueueAsync(
        accountId: accountId, identity: .item(itemId: itemId), entityKey: serverItemId,
        readingPositionJSON: "{\"href\":\"relaunch.xhtml\"}", ebookProgress: 0.55,
        ebookLocation: nil, originKey: "fixture-client")

      scope.close(database)
      let reopenedDatabase = try scope.open(at: scope.url())
      let reopenedStore = try OutboxStore(database: reopenedDatabase)
      let rows = try reopenedStore.fetchQueued(accountId: accountId, entityKey: serverItemId)
      #expect(rows.count == 1)
      #expect(rows[0].operationKind == OutboxOperationKind.ebookPosition.rawValue)
      #expect(rows[0].payloadEbookProgress == 0.55)
    }
  }

  private func makeItem(in database: AppDatabase) async throws -> (Int64, Int64, String) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "fixture-client", serverBaseURL: "https://books.example.test",
        serverUserId: "fixture-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-fixture", mediaType: "book", name: "Books")
      try library.insert(db)
      let serverItemId = "item-ebook-fixture"
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemId,
        mediaKind: "book", title: "Fixture", sortTitle: "fixture")
      try item.insert(db)
      return (account.id!, item.id!, serverItemId)
    }
  }
}
