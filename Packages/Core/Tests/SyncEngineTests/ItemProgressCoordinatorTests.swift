import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("Item progress coordinator")
struct ItemProgressCoordinatorTests {
  @Test("ebook reset clears reader state, retains audio position, and queues a progressReset")
  func resetEbookProgressClearsReaderStateButRetainsAudioPosition() async throws {
    let harness = try await Harness()
    let serverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_123)
    try await harness.seedProgress(
      itemID: Harness.bookID,
      currentTime: 900,
      isFinished: true,
      localSequence: 7,
      serverUpdatedAt: serverUpdatedAt,
      readingPositionJSON: "{\"href\":\"chapter.xhtml\"}",
      ebookProgress: 0.63,
      ebookLocation: "epubcfi(/6/4!/4/2/1:0)")

    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })

    try await coordinator.resetEbookProgress(itemID: Harness.bookID)

    #expect(await TestSupport.waitUntil { await drains.count == 1 })
    let progress = try #require(
      await harness.progress(itemID: Harness.bookID))
    #expect(progress.currentTime == 900)
    #expect(progress.ebookProgress == 0)
    #expect(progress.ebookLocation == nil)
    #expect(progress.readingPositionJSON == nil)
    #expect(progress.isFinished == false)
    #expect(progress.serverUpdatedAt == serverUpdatedAt)
    #expect(progress.origin == .local)
    #expect(progress.originKey == Harness.clientUUID)

    let operations = try await harness.outboxOperations()
    let operation = try #require(operations.first)
    #expect(operations.count == 1)
    // ADR 0011: the store queues the phased `progressReset` delete/restore leg, not the fixed
    // `ebookReset` PATCH. `ebookReset` remains only so already-queued rows still drain
    // (`OutboxOperationKind.ebookReset`'s doc comment).
    #expect(operation.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(operation.progressResetMedium == .ebook)
    #expect(operation.progressResetPhase == .resolve)
    #expect(operation.entityKey == Harness.bookID)
    #expect(operation.podcastEpisodeId == nil)
    #expect(operation.payloadCurrentTime == nil)
    #expect(operation.payloadEbookProgress == nil)
    #expect(operation.payloadIsFinished == nil)
    #expect(operation.localSequence == progress.localSequence)
  }

  @Test("ebook reset rejects an unknown item without writing or requesting a drain")
  func resetEbookProgressRejectsUnknownItemWithoutWriting() async throws {
    let harness = try await Harness()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })
    let before = try await harness.rowCounts()

    await #expect(throws: ItemProgressIntentStoreError.itemNotFound("missing")) {
      try await coordinator.resetEbookProgress(itemID: "missing")
    }

    #expect(try await harness.rowCounts() == before)
    #expect(await drains.count == 0)
  }

  @Test("single-episode reset changes only the target episode and queues a progressReset")
  func resetProgressForOneEpisodeLeavesSiblingsAndItemUntouched() async throws {
    let harness = try await Harness()
    try await harness.seedProgress(
      itemID: Harness.showID, currentTime: 120, isFinished: false, localSequence: 2)
    try await harness.seedProgress(
      itemID: Harness.showID, episodeID: "ep-1", currentTime: 2_400, isFinished: true,
      localSequence: 4)
    try await harness.seedProgress(
      itemID: Harness.showID, episodeID: "ep-2", currentTime: 777, isFinished: true,
      localSequence: 5)
    try await harness.seedProgress(
      itemID: Harness.showID, episodeID: "ep-3", currentTime: 333, isFinished: false,
      localSequence: 6)

    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })

    try await coordinator.resetProgress(itemID: Harness.showID, episodeID: "ep-1")

    #expect(await TestSupport.waitUntil { await drains.count == 1 })
    let target = try #require(
      await harness.progress(itemID: Harness.showID, episodeID: "ep-1"))
    let show = try #require(await harness.progress(itemID: Harness.showID))
    let sibling = try #require(
      await harness.progress(itemID: Harness.showID, episodeID: "ep-2"))
    let otherSibling = try #require(
      await harness.progress(itemID: Harness.showID, episodeID: "ep-3"))

    #expect(target.currentTime == 0)
    #expect(target.isFinished == false)
    #expect(target.localSequence == 5)
    #expect(target.origin == .local)
    #expect(target.originKey == Harness.clientUUID)
    #expect(show.currentTime == 120)
    #expect(show.isFinished == false)
    #expect(show.localSequence == 2)
    #expect(sibling.currentTime == 777)
    #expect(sibling.isFinished)
    #expect(sibling.localSequence == 5)
    #expect(otherSibling.currentTime == 333)
    #expect(otherSibling.isFinished == false)
    #expect(otherSibling.localSequence == 6)

    let operations = try await harness.outboxOperations()
    let operation = try #require(operations.first)
    let targetRowID = try #require(harness.episodeRowIDs["ep-1"])
    #expect(operations.count == 1)
    // ADR 0011: `ItemProgressCoordinator.resetProgress` routes through
    // `ItemProgressIntentStore.resetProgressAsync`, which queues the phased `progressReset`
    // delete/restore leg, not an ordinary `progress` PATCH. A reset must delete the server row
    // rather than PATCH it to zero, so other devices see loss of row identity as reset evidence.
    #expect(operation.operationKind == OutboxOperationKind.progressReset.rawValue)
    #expect(operation.progressResetMedium == .audio)
    #expect(operation.progressResetPhase == .resolve)
    #expect(operation.entityKey == Harness.showID)
    #expect(operation.podcastEpisodeId == targetRowID)
    #expect(operation.payloadCurrentTime == nil)
    #expect(operation.payloadIsFinished == nil)
    #expect(operation.localSequence == target.localSequence)
  }

  @Test("single-episode reset rejects a missing episode without writing or draining")
  func resetProgressRejectsMissingEpisodeWithoutWriting() async throws {
    let harness = try await Harness()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })
    let before = try await harness.rowCounts()

    await #expect(throws: ItemProgressIntentStoreError.episodeNotFound("missing")) {
      try await coordinator.resetProgress(itemID: Harness.showID, episodeID: "missing")
    }

    #expect(try await harness.rowCounts() == before)
    #expect(await drains.count == 0)
  }

  /// The single-episode path requests a drain per call, so a "mark all" built out of it would ask
  /// the drainer to run once per episode (forty rows, forty wake-ups, the same forty PATCHes).
  /// The batch is one transaction and one request.
  @Test func markAllRequestsSingleDrain() async throws {
    let harness = try await Harness()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })

    try await coordinator.setEpisodesFinished(
      itemID: Harness.showID,
      episodes: Harness.episodeIDs.map { EpisodeProgressChange(episodeID: $0, currentTime: 60) },
      isFinished: true)

    #expect(await drains.count == 1)
    #expect(try await harness.finishedEpisodeProgressCount() == Harness.episodeIDs.count)
  }

  /// Nothing to write is nothing to send: an empty batch must not wake the drainer at all.
  @Test func anEmptyBatchTouchesNothing() async throws {
    let harness = try await Harness()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })

    try await coordinator.setEpisodesFinished(
      itemID: Harness.showID, episodes: [], isFinished: true)

    #expect(await drains.count == 0)
    #expect(try await harness.finishedEpisodeProgressCount() == 0)
  }

  @Test("mark finished deletes the matching book or podcast download when enabled")
  func markFinishedDeletesTheMatchingDownloadWhenEnabled() async throws {
    let harness = try await Harness()
    let deletions = FinishedDownloadDeletionRecorder()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    try await coordinator.markAsFinished(
      itemID: Harness.bookID, episodeID: nil, duration: 3_600)
    try await coordinator.markAsFinished(
      itemID: Harness.showID, episodeID: "ep-1", duration: 600)

    #expect(
      await deletions.values == [
        FinishedDownloadIdentity(itemID: Harness.bookID, episodeID: nil),
        FinishedDownloadIdentity(itemID: Harness.showID, episodeID: "ep-1"),
      ])
  }

  @Test("mark finished retains downloads when delete when finished is disabled")
  func markFinishedRetainsDownloadsWhenDisabled() async throws {
    let harness = try await Harness()
    let deletions = FinishedDownloadDeletionRecorder()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: false),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    try await coordinator.markAsFinished(
      itemID: Harness.bookID, episodeID: nil, duration: 3_600)

    #expect(await deletions.values.isEmpty)
  }

  @Test("mark all finished deletes each matching podcast download when enabled")
  func markAllFinishedDeletesEachMatchingPodcastDownloadWhenEnabled() async throws {
    let harness = try await Harness()
    let deletions = FinishedDownloadDeletionRecorder()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    try await coordinator.setEpisodesFinished(
      itemID: Harness.showID,
      episodes: Harness.episodeIDs.prefix(2).map {
        EpisodeProgressChange(episodeID: $0, currentTime: 60)
      },
      isFinished: true)

    #expect(
      await deletions.values == [
        FinishedDownloadIdentity(itemID: Harness.showID, episodeID: "ep-1"),
        FinishedDownloadIdentity(itemID: Harness.showID, episodeID: "ep-2"),
      ])
  }

  @Test("a zero-position finish with no known duration removes only the exact saved identity")
  func zeroPositionFinishRemovesOnlyTheExactSavedIdentity() async throws {
    let harness = try await Harness()
    let savedShelf = SavedShelfStore(database: harness.database, accountId: harness.accountID)
    try await savedShelf.save(.item(itemID: Harness.bookID))
    try await savedShelf.save(.podcastEpisode(itemID: Harness.showID, episodeID: "ep-1"))
    try await savedShelf.save(.podcastEpisode(itemID: Harness.showID, episodeID: "ep-2"))
    let coordinator = try ItemProgressCoordinator(database: harness.database)

    try await coordinator.markAsFinished(itemID: Harness.bookID, episodeID: nil, duration: nil)
    try await coordinator.markAsFinished(itemID: Harness.showID, episodeID: "ep-1", duration: nil)

    #expect(try await harness.savedIdentities() == [.podcastEpisode(itemID: Harness.showID, episodeID: "ep-2")])

    // Marking it unplayed again never restores the save, and a deliberate re-save after the finish
    // survives a repeated finished write because neither the flag nor the position transitions.
    try await coordinator.resetProgress(itemID: Harness.showID, episodeID: "ep-1")
    #expect(try await harness.savedIdentities() == [.podcastEpisode(itemID: Harness.showID, episodeID: "ep-2")])
    try await coordinator.markAsFinished(itemID: Harness.showID, episodeID: "ep-1", duration: 600)
    try await savedShelf.save(.podcastEpisode(itemID: Harness.showID, episodeID: "ep-1"))
    try await coordinator.markAsFinished(itemID: Harness.showID, episodeID: "ep-1", duration: 600)
    #expect(
      try await harness.savedIdentities() == [
        .podcastEpisode(itemID: Harness.showID, episodeID: "ep-2"),
        .podcastEpisode(itemID: Harness.showID, episodeID: "ep-1"),
      ])
  }

  @Test("a finish that fails to persist leaves the save and the download alone")
  func failedFinishLeavesSaveAndDownloadAlone() async throws {
    let harness = try await Harness()
    let savedShelf = SavedShelfStore(database: harness.database, accountId: harness.accountID)
    try await savedShelf.save(.podcastEpisode(itemID: Harness.showID, episodeID: "ep-1"))
    let deletions = FinishedDownloadDeletionRecorder()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { itemID, episodeID in
        await deletions.record(itemID: itemID, episodeID: episodeID)
      })

    await #expect(throws: (any Error).self) {
      try await coordinator.markAsFinished(itemID: "missing", episodeID: "ep-1", duration: 600)
    }

    #expect(try await harness.savedIdentities() == [.podcastEpisode(itemID: Harness.showID, episodeID: "ep-1")])
    #expect(await deletions.values.isEmpty)
  }

  @Test("ebook position write commits its rows and returns while the drain it started is suspended")
  func writeEbookPositionReturnsWithoutAwaitingTheDrain() async throws {
    let harness = try await Harness()
    let drain = SuspendedDrain()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drain.run() })
    let returned = ReturnFlag()

    let write = Task {
      try await coordinator.writeEbookPosition(
        itemID: Harness.bookID,
        readingPositionJSON: "{\"href\":\"chapter.xhtml\"}",
        ebookProgress: 0.42,
        ebookLocation: nil)
      await returned.set()
    }

    #expect(await TestSupport.waitUntil("write returned") { await returned.value })
    #expect(await TestSupport.waitUntil("drain started") { await drain.started == 1 })
    let progress = try #require(await harness.progress(itemID: Harness.bookID))
    #expect(progress.ebookProgress == 0.42)
    #expect(progress.readingPositionJSON == "{\"href\":\"chapter.xhtml\"}")
    #expect(progress.originKey == Harness.clientUUID)
    let operations = try await harness.outboxOperations()
    #expect(operations.count == 1)
    #expect(operations.first?.operationKind == OutboxOperationKind.ebookPosition.rawValue)
    #expect(operations.first?.entityKey == Harness.bookID)

    await drain.release()
    try await write.value
    #expect(await drain.started == 1)
  }

  @Test("ebook finish commits its rows and returns while the drain it started is suspended")
  func markEbookAsFinishedReturnsWithoutAwaitingTheDrain() async throws {
    let harness = try await Harness()
    let drain = SuspendedDrain()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drain.run() })
    let returned = ReturnFlag()

    let finish = Task {
      try await coordinator.markEbookAsFinished(itemID: Harness.bookID)
      await returned.set()
    }

    #expect(await TestSupport.waitUntil("finish returned") { await returned.value })
    #expect(await TestSupport.waitUntil("drain started") { await drain.started == 1 })
    let progress = try #require(await harness.progress(itemID: Harness.bookID))
    #expect(progress.isFinished)
    let operations = try await harness.outboxOperations()
    #expect(operations.count == 1)
    #expect(operations.first?.entityKey == Harness.bookID)

    await drain.release()
    try await finish.value
    #expect(await drain.started == 1)
  }

  @Test("ebook writes for an unknown item are a silent no-op that requests no drain")
  func ebookWritesForUnknownItemDoNothing() async throws {
    let harness = try await Harness()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: harness.database,
      requestDrain: { await drains.record() })
    let before = try await harness.rowCounts()

    try await coordinator.writeEbookPosition(
      itemID: "missing", readingPositionJSON: "{}", ebookProgress: 0.5, ebookLocation: nil)
    try await coordinator.markEbookAsFinished(itemID: "missing")

    #expect(try await harness.rowCounts() == before)
    #expect(await drains.count == 0)
  }

  @Test("ebook writes without an account throw notAuthenticated")
  func ebookWritesWithoutAccountThrow() async throws {
    let database = try AppDatabase.inMemory()
    let drains = DrainCounter()
    let coordinator = try ItemProgressCoordinator(
      database: database,
      requestDrain: { await drains.record() })

    await #expect(throws: ItemProgressIntentError.notAuthenticated) {
      try await coordinator.writeEbookPosition(
        itemID: Harness.bookID, readingPositionJSON: "{}", ebookProgress: 0.5,
        ebookLocation: nil)
    }
    await #expect(throws: ItemProgressIntentError.notAuthenticated) {
      try await coordinator.markEbookAsFinished(itemID: Harness.bookID)
    }
    #expect(await drains.count == 0)
  }

  /// A drain that parks every caller until released, so a test can tell whether the caller
  /// awaited it.
  private actor SuspendedDrain {
    private(set) var started = 0
    // A drain runs to completion regardless of cancellation, so a cancelled one stays parked.
    private nonisolated let gate = TestGate<Void>(
      label: "SuspendedDrain run", ignoresCancellation: true)

    init() {
      gate.hold()
    }

    func run() async {
      started += 1
      await gate.pass()
    }

    func release() {
      gate.release()
    }
  }

  private actor ReturnFlag {
    private(set) var value = false
    func set() { value = true }
  }

  private actor DrainCounter {
    private(set) var count = 0
    func record() { count += 1 }
  }

  private struct Harness {
    let database: AppDatabase
    let accountID: Int64
    let bookRowID: Int64
    let showRowID: Int64
    let episodeRowIDs: [String: Int64]

    static let bookID = "book-1"
    static let showID = "show-1"
    static let episodeIDs = ["ep-1", "ep-2", "ep-3"]
    static let clientUUID = "device-origin"

    /// Saved identities in insertion order, expressed the way intents name them.
    func savedIdentities() async throws -> [SavedShelfIdentity] {
      try await database.readAsync { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT item.serverItemId AS itemID, episode.serverEpisodeId AS episodeID
            FROM savedShelfEntry AS saved
            JOIN item ON item.id = saved.itemId
            LEFT JOIN podcastEpisode AS episode ON episode.id = saved.podcastEpisodeId
            WHERE saved.accountId = ?
            ORDER BY saved.id
            """,
          arguments: [accountID]
        ).map { row in
          if let episodeID: String = row["episodeID"] {
            return .podcastEpisode(itemID: row["itemID"], episodeID: episodeID)
          }
          return .item(itemID: row["itemID"])
        }
      }
    }

    init() async throws {
      database = try AppDatabase.inMemory()
      let ids = try await database.writeAsync { db -> (Int64, Int64, Int64, [String: Int64]) in
        var account = AccountRecord(
          clientUUID: Self.clientUUID,
          serverBaseURL: "https://example.test",
          serverUserId: "user",
          serverVersion: "2.26.0")
        try account.insert(db)
        let accountID = try #require(account.id)

        var bookLibrary = LibraryRecord(
          accountId: accountID, serverLibraryId: "library-books", mediaType: "book",
          name: "Books")
        try bookLibrary.insert(db)

        var book = ItemRecord(
          accountId: accountID, libraryId: try #require(bookLibrary.id),
          serverItemId: Self.bookID, mediaKind: "book", title: "A Book",
          sortTitle: "a book")
        try book.insert(db)

        var library = LibraryRecord(
          accountId: accountID, serverLibraryId: "library-1", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)

        var show = ItemRecord(
          accountId: accountID, libraryId: try #require(library.id),
          serverItemId: Self.showID, mediaKind: "podcast", title: "A Show",
          sortTitle: "a show")
        try show.insert(db)
        let showRowID = try #require(show.id)

        for episodeID in Self.episodeIDs {
          var episode = PodcastEpisodeRecord(
            accountId: accountID, itemId: showRowID, serverEpisodeId: episodeID,
            title: episodeID, lastSeenGeneration: 1)
          try episode.insert(db)
        }

        let episodeRowIDs = try Dictionary(
          uniqueKeysWithValues: Self.episodeIDs.map { episodeID in
            let rowID = try #require(
              try PodcastEpisodeRecord
                .filter(Column("itemId") == showRowID)
                .filter(Column("serverEpisodeId") == episodeID)
                .fetchOne(db)?.id)
            return (episodeID, rowID)
          })
        return (
          accountID,
          try #require(book.id),
          showRowID,
          episodeRowIDs
        )
      }
      accountID = ids.0
      bookRowID = ids.1
      showRowID = ids.2
      episodeRowIDs = ids.3
    }

    func seedProgress(
      itemID: String,
      episodeID: String? = nil,
      currentTime: Double,
      isFinished: Bool,
      localSequence: Int64,
      serverUpdatedAt: Date? = nil,
      readingPositionJSON: String? = nil,
      ebookProgress: Double? = nil,
      ebookLocation: String? = nil
    ) async throws {
      let itemRowID = itemID == Self.bookID ? bookRowID : showRowID
      let episodeRowID = try episodeID.map { try #require(episodeRowIDs[$0]) }
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountID,
          itemId: itemRowID,
          podcastEpisodeId: episodeRowID,
          currentTime: currentTime,
          isFinished: isFinished,
          serverUpdatedAt: serverUpdatedAt,
          localSequence: localSequence,
          origin: .server,
          originKey: ProgressOrigin.serverOriginKey,
          readingPositionJSON: readingPositionJSON,
          ebookProgress: ebookProgress,
          ebookLocation: ebookLocation)
        try progress.insert(db)
      }
    }

    func progress(itemID: String, episodeID: String? = nil) async throws -> MediaProgressRecord? {
      let itemRowID = itemID == Self.bookID ? bookRowID : showRowID
      let episodeRowID = try episodeID.map { try #require(episodeRowIDs[$0]) }
      return try await database.readAsync { db in
        var request =
          MediaProgressRecord
          .filter(Column("accountId") == accountID)
          .filter(Column("itemId") == itemRowID)
        if let episodeRowID {
          request = request.filter(Column("podcastEpisodeId") == episodeRowID)
        } else {
          request = request.filter(Column("podcastEpisodeId") == nil)
        }
        return try request.fetchOne(db)
      }
    }

    func outboxOperations() async throws -> [OutboxOperationRecord] {
      try await database.readAsync { db in
        try OutboxOperationRecord.order(Column("id")).fetchAll(db)
      }
    }

    func rowCounts() async throws -> (progress: Int, outbox: Int) {
      try await database.readAsync { db in
        (
          try MediaProgressRecord.fetchCount(db),
          try OutboxOperationRecord.fetchCount(db)
        )
      }
    }

    func finishedEpisodeProgressCount() async throws -> Int {
      try await database.readAsync { db in
        try MediaProgressRecord
          .filter(Column("podcastEpisodeId") != nil)
          .filter(Column("isFinished") == true)
          .fetchCount(db)
      }
    }
  }
}

private struct FinishedDownloadIdentity: Sendable, Equatable {
  let itemID: String
  let episodeID: String?
}

private actor FinishedDownloadDeletionRecorder {
  private(set) var values: [FinishedDownloadIdentity] = []

  func record(itemID: String, episodeID: String?) {
    values.append(FinishedDownloadIdentity(itemID: itemID, episodeID: episodeID))
  }
}
