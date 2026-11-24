import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The `audioBookmark` table, the store's intents with their outbox rows, the coalescing table,
/// and the pull's protection of unacknowledged intents.
@Suite struct AudioBookmarkStoreTests {
  private static let item = "item_book"
  private static let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Schema

  @Test("v87 creates audioBookmark keyed by account, item and exact time")
  func migrationCreatesTable() throws {
    let database = try AppDatabase.inMemory()
    let (columns, primaryKey, outboxColumns) = try database.read { db in
      (
        try db.columns(in: "audioBookmark").map(\.name),
        try db.primaryKey("audioBookmark").columns,
        try db.columns(in: "outboxOperation").map(\.name)
      )
    }
    #expect(columns == ["accountId", "serverItemId", "time", "title", "createdAt"])
    #expect(primaryKey == ["accountId", "serverItemId", "time"])
    #expect(outboxColumns.contains("payloadBookmarkTime"))
    #expect(outboxColumns.contains("payloadBookmarkTitle"))
  }

  @Test("removing the account removes its bookmarks")
  func accountCascade() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 10, title: "Ten",
      createdAt: Self.createdAt)

    try await database.writeAsync { db in
      _ = try AccountRecord.deleteOne(db, key: accountId)
    }

    let remaining = try await database.readAsync { db in try AudioBookmarkRecord.fetchCount(db) }
    #expect(remaining == 0)
  }

  @Test("a fractional server time is stored and read back as exactly the same double")
  func exactTimeRoundTrip() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let time = 0.30000000000000004

    try await store.applyServerBookmarks(
      accountId: accountId,
      [AudioBookmark(serverItemID: Self.item, time: time, title: "t", createdAt: nil)],
      isComplete: true)

    let stored = try store.bookmarks(accountId: accountId, serverItemId: Self.item)
    #expect(stored.map(\.time) == [time])
    #expect(stored.first?.time.bitPattern == time.bitPattern)
  }

  // MARK: - Intents

  @Test("create writes the bookmark and one pending create row")
  func createWritesRowAndOutbox() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)

    let outcome = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 125, title: "  Chapter 3 \n",
      createdAt: Self.createdAt)

    let expected = AudioBookmark(
      serverItemID: Self.item, time: 125, title: "Chapter 3", createdAt: Self.createdAt)
    #expect(outcome == .created(expected))
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item) == [expected])
    let rows = try await Self.outboxRows(database)
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(row.operationKind == OutboxOperationKind.bookmarkCreate.rawValue)
    #expect(row.entityKey == Self.item)
    #expect(row.podcastEpisodeId == nil)
    #expect(row.payloadBookmarkTime == 125)
    #expect(row.payloadBookmarkTitle == "Chapter 3")
    #expect(row.state == .pending)
    #expect(
      row.coalescingKey
        == OutboxStore.audioBookmarkCoalescingKey(
          accountId: accountId, serverItemId: Self.item, time: 125))
  }

  @Test("the bookmark and its outbox row commit together or not at all")
  func createIsOneTransaction() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 10, title: "First",
      createdAt: Self.createdAt, clientOperationId: "duplicate-operation-id")

    // `clientOperationId` is unique, so the outbox insert fails after the bookmark insert.
    await #expect(throws: DatabaseError.self) {
      _ = try await store.create(
        accountId: accountId, serverItemId: Self.item, time: 60, title: "Second",
        createdAt: Self.createdAt, clientOperationId: "duplicate-operation-id")
    }

    let times = try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.time)
    #expect(times == [10])
  }

  @Test(
    "a new bookmark less than a second from an existing one is refused",
    arguments: [(10.0, 10.0), (10.4, 11.0), (10.0, 9.2)])
  func createRefusesNearby(existing: Double, new: Double) async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await store.applyServerBookmarks(
      accountId: accountId,
      [AudioBookmark(serverItemID: Self.item, time: existing, title: "Existing", createdAt: nil)],
      isComplete: true)

    let outcome = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: new, title: "New",
      createdAt: Self.createdAt)

    guard case .tooCloseToExisting(let nearby) = outcome else {
      Issue.record("expected a refusal, got \(outcome)")
      return
    }
    #expect(nearby.time == existing)
    #expect(try await Self.outboxRows(database).isEmpty)
  }

  @Test("bookmarks exactly a second apart, or on another item, are both kept")
  func createAllowsSpacedOrOtherItem() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)

    for (item, time) in [(Self.item, 10.0), (Self.item, 11.0), ("item_other", 10.0)] {
      let outcome = try await store.create(
        accountId: accountId, serverItemId: item, time: time, title: "B",
        createdAt: Self.createdAt)
      guard case .created = outcome else {
        Issue.record("expected \(item) at \(time) to be created, got \(outcome)")
        return
      }
    }
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.time) == [10, 11])
  }

  @Test("a blank title, a bad time, or an empty or device-owned item is refused before anything is written")
  func createValidates() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)

    await #expect(throws: AudioBookmarkStoreError.emptyTitle) {
      _ = try await store.create(
        accountId: accountId, serverItemId: Self.item, time: 1, title: " \n ",
        createdAt: Self.createdAt)
    }
    await #expect(throws: AudioBookmarkStoreError.invalidTime) {
      _ = try await store.create(
        accountId: accountId, serverItemId: Self.item, time: -1, title: "t",
        createdAt: Self.createdAt)
    }
    await #expect(throws: AudioBookmarkStoreError.invalidTime) {
      _ = try await store.create(
        accountId: accountId, serverItemId: Self.item, time: .nan, title: "t",
        createdAt: Self.createdAt)
    }
    for item in ["", "rss:42"] {
      await #expect(throws: AudioBookmarkStoreError.invalidItem) {
        _ = try await store.create(
          accountId: accountId, serverItemId: item, time: 1, title: "t", createdAt: Self.createdAt)
      }
    }
    #expect(try await Self.outboxRows(database).isEmpty)
  }

  @Test("rename and delete of a bookmark that is not stored write nothing")
  func renameAndDeleteOfMissingBookmark() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)

    #expect(
      try await store.rename(accountId: accountId, serverItemId: Self.item, time: 5, title: "x")
        == false)
    #expect(try await store.delete(accountId: accountId, serverItemId: Self.item, time: 5) == false)
    #expect(try await Self.outboxRows(database).isEmpty)
  }

  @Test("renaming to the same title writes nothing")
  func renameToSameTitleIsNoOp() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 5, title: "Same")

    #expect(
      try await store.rename(accountId: accountId, serverItemId: Self.item, time: 5, title: "Same")
        == false)
    #expect(try await Self.outboxRows(database).isEmpty)
  }

  // MARK: - Coalescing (one test per row of the coalescing table)

  @Test("create then rename leaves one create carrying the new title")
  func createThenRename() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 30, title: "Old",
      createdAt: Self.createdAt)

    try await store.rename(accountId: accountId, serverItemId: Self.item, time: 30, title: "New")

    let rows = try await Self.outboxRows(database)
    #expect(rows.map(\.operationKind) == [OutboxOperationKind.bookmarkCreate.rawValue])
    #expect(rows.first?.payloadBookmarkTitle == "New")
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.title) == ["New"])
  }

  @Test("create never attempted, then delete, leaves nothing to send")
  func unsentCreateThenDelete() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 30, title: "Gone",
      createdAt: Self.createdAt)

    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 30)

    #expect(try await Self.outboxRows(database).isEmpty)
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).isEmpty)
  }

  @Test("create already attempted, then delete, becomes a delete because the create may have landed")
  func attemptedCreateThenDelete() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let outbox = try OutboxStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 30, title: "Maybe",
      createdAt: Self.createdAt)
    let createId = try #require(try await Self.outboxRows(database).first?.id)
    _ = try outbox.transition(operationId: createId, to: .sending)
    _ = try outbox.transition(
      operationId: createId, to: .retryWaiting, nextAttemptAt: Self.createdAt)

    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 30)

    let rows = try await Self.outboxRows(database)
    #expect(rows.map(\.id) == [createId])
    #expect(rows.first?.operationKind == OutboxOperationKind.bookmarkDelete.rawValue)
    #expect(rows.first?.payloadBookmarkTitle == nil)
    #expect(rows.first?.payloadBookmarkTime == 30)
  }

  @Test("rename then rename leaves one rename carrying the later title")
  func renameThenRename() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 30, title: "Server")

    try await store.rename(accountId: accountId, serverItemId: Self.item, time: 30, title: "One")
    try await store.rename(accountId: accountId, serverItemId: Self.item, time: 30, title: "Two")

    let rows = try await Self.outboxRows(database)
    #expect(rows.map(\.operationKind) == [OutboxOperationKind.bookmarkRename.rawValue])
    #expect(rows.first?.payloadBookmarkTitle == "Two")
  }

  @Test("rename then delete leaves one delete")
  func renameThenDelete() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 30, title: "Server")

    try await store.rename(accountId: accountId, serverItemId: Self.item, time: 30, title: "One")
    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 30)

    let rows = try await Self.outboxRows(database)
    #expect(rows.map(\.operationKind) == [OutboxOperationKind.bookmarkDelete.rawValue])
    #expect(rows.first?.payloadBookmarkTitle == nil)
  }

  @Test("delete then create at the same time leaves one create")
  func deleteThenCreate() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 30, title: "Server")

    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 30)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 30, title: "Again",
      createdAt: Self.createdAt)

    let rows = try await Self.outboxRows(database)
    #expect(rows.map(\.operationKind) == [OutboxOperationKind.bookmarkCreate.rawValue])
    #expect(rows.first?.payloadBookmarkTitle == "Again")
  }

  @Test("an intent behind a sending row queues as its own row after it")
  func intentBehindSendingRowQueues() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let outbox = try OutboxStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 30, title: "In flight",
      createdAt: Self.createdAt)
    let createId = try #require(try await Self.outboxRows(database).first?.id)
    _ = try outbox.transition(operationId: createId, to: .sending)

    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 30)

    let rows = try await Self.outboxRows(database)
    #expect(
      rows.map(\.operationKind) == [
        OutboxOperationKind.bookmarkCreate.rawValue, OutboxOperationKind.bookmarkDelete.rawValue,
      ])
    #expect(rows.map(\.state) == [.sending, .pending])
  }

  @Test("bookmark intents never merge with another bookmark or another kind on the same item")
  func bookmarksCoalesceOnlyWithTheirOwnKey() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let outbox = try OutboxStore(database: database)
    _ = try outbox.enqueueContinueListeningVisibility(
      accountId: accountId, entityKey: Self.item, podcastEpisodeId: nil, localSequence: 7,
      hideFromContinueListening: true)

    for time in [30.0, 31.0] {
      _ = try await store.create(
        accountId: accountId, serverItemId: Self.item, time: time, title: "B",
        createdAt: Self.createdAt)
    }
    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 31)

    let rows = try await Self.outboxRows(database)
    #expect(
      rows.map(\.operationKind) == [
        OutboxOperationKind.continueListeningVisibility.rawValue,
        OutboxOperationKind.bookmarkCreate.rawValue,
      ])
    #expect(rows.last?.payloadBookmarkTime == 30)
  }

  // MARK: - Pull

  @Test("a complete list removes bookmarks the server no longer has and adds new ones")
  func completeListReplaces() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 10, title: "Old")

    try await store.applyServerBookmarks(
      accountId: accountId,
      [AudioBookmark(serverItemID: Self.item, time: 20, title: "New", createdAt: Self.createdAt)],
      isComplete: true)

    #expect(
      try store.bookmarks(accountId: accountId, serverItemId: Self.item)
        == [AudioBookmark(serverItemID: Self.item, time: 20, title: "New", createdAt: Self.createdAt)])
  }

  @Test("an incomplete list adds and retitles but never removes")
  func incompleteListOnlyUpserts() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 10, title: "Kept")
    try await Self.serverBookmark(store, accountId: accountId, time: 20, title: "Old title")

    try await store.applyServerBookmarks(
      accountId: accountId,
      [
        AudioBookmark(serverItemID: Self.item, time: 20, title: "New title", createdAt: nil),
        AudioBookmark(serverItemID: Self.item, time: 30, title: "Added", createdAt: nil),
      ],
      isComplete: false)

    #expect(
      try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.title)
        == ["Kept", "New title", "Added"])
  }

  @Test("a pending create survives a complete snapshot taken before it reached the server")
  func pendingCreateSurvives() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 40, title: "Mine",
      createdAt: Self.createdAt)

    try await store.applyServerBookmarks(accountId: accountId, [], isComplete: true)

    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.time) == [40])
  }

  @Test("a pending delete is not brought back by a snapshot that still lists it")
  func pendingDeleteStaysDeleted() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 40, title: "Server")
    try await store.delete(accountId: accountId, serverItemId: Self.item, time: 40)

    try await store.applyServerBookmarks(
      accountId: accountId,
      [AudioBookmark(serverItemID: Self.item, time: 40, title: "Server", createdAt: nil)],
      isComplete: true)

    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).isEmpty)
  }

  @Test("a pending rename keeps its title against an older snapshot")
  func pendingRenameKeepsTitle() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: accountId, time: 40, title: "Server")
    try await store.rename(accountId: accountId, serverItemId: Self.item, time: 40, title: "Mine")

    try await store.applyServerBookmarks(
      accountId: accountId,
      [AudioBookmark(serverItemID: Self.item, time: 40, title: "Server", createdAt: nil)],
      isComplete: true)

    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.title) == ["Mine"])
  }

  @Test("a create acknowledged during the fetch is kept through the key read before the fetch")
  func createAcknowledgedDuringFetchSurvives() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let outbox = try OutboxStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 40, title: "Mine",
      createdAt: Self.createdAt)

    let protectedBeforeFetch = try await store.unacknowledgedKeys(accountId: accountId)
    let createId = try #require(try await Self.outboxRows(database).first?.id)
    _ = try outbox.transition(operationId: createId, to: .sending)
    try await outbox.acknowledgeAsync(operationId: createId) { _ in }
    // The snapshot was taken before the create landed, so it does not list it.
    try await store.applyServerBookmarks(
      accountId: accountId, [], isComplete: true, protecting: protectedBeforeFetch)

    #expect(protectedBeforeFetch == [AudioBookmarkKey(serverItemID: Self.item, time: 40)])
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).map(\.time) == [40])
  }

  @Test("a dead-lettered create no longer protects its bookmark")
  func deadLetteredCreateIsNotProtected() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    let outbox = try OutboxStore(database: database)
    _ = try await store.create(
      accountId: accountId, serverItemId: Self.item, time: 40, title: "Orphan",
      createdAt: Self.createdAt)
    let createId = try #require(try await Self.outboxRows(database).first?.id)
    _ = try outbox.transition(operationId: createId, to: .sending)
    _ = try outbox.transition(operationId: createId, to: .deadLetter, deadLetterReason: "notFound")

    #expect(try await store.unacknowledgedKeys(accountId: accountId).isEmpty)
    try await store.applyServerBookmarks(accountId: accountId, [], isComplete: true)
    #expect(try store.bookmarks(accountId: accountId, serverItemId: Self.item).isEmpty)
  }

  @Test("one account's pull never touches another account's bookmarks")
  func pullIsScopedToAccount() async throws {
    let database = try AppDatabase.inMemory()
    let (first, second) = try await database.writeAsync { db -> (Int64, Int64) in
      (try Self.insertAccount(db, serverUserId: "user-1"), try Self.insertAccount(db, serverUserId: "user-2"))
    }
    let store = AudioBookmarkStore(database: database)
    try await Self.serverBookmark(store, accountId: first, time: 10, title: "First")
    try await Self.serverBookmark(store, accountId: second, time: 10, title: "Second")

    try await store.applyServerBookmarks(accountId: first, [], isComplete: true)

    #expect(try store.bookmarks(accountId: first, serverItemId: Self.item).isEmpty)
    #expect(try store.bookmarks(accountId: second, serverItemId: Self.item).map(\.title) == ["Second"])
  }

  @Test("the observation emits the item's bookmarks in time order as they change")
  func observationEmits() async throws {
    let (database, accountId) = try await Self.databaseWithAccount()
    let store = AudioBookmarkStore(database: database)
    var iterator = store.observeBookmarks(accountId: accountId, serverItemId: Self.item)
      .makeAsyncIterator()
    #expect(await iterator.next() == [])

    try await store.applyServerBookmarks(
      accountId: accountId,
      [
        AudioBookmark(serverItemID: Self.item, time: 90, title: "Later", createdAt: nil),
        AudioBookmark(serverItemID: Self.item, time: 15, title: "Earlier", createdAt: nil),
        AudioBookmark(serverItemID: "item_other", time: 1, title: "Elsewhere", createdAt: nil),
      ],
      isComplete: true)

    #expect(await iterator.next()?.map(\.title) == ["Earlier", "Later"])
  }

  // MARK: - Helpers

  private static func databaseWithAccount() async throws -> (AppDatabase, Int64) {
    let database = try AppDatabase.inMemory()
    let accountId = try await database.writeAsync { db in
      try insertAccount(db, serverUserId: "user-1")
    }
    return (database, accountId)
  }

  private static func insertAccount(_ db: Database, serverUserId: String) throws -> Int64 {
    var account = PersistenceFixtures.account(
      clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
      serverUserId: serverUserId, serverVersion: "2.35.1")
    try account.insert(db)
    return try #require(account.id)
  }

  /// Stores a bookmark as a pull would, with no outbox row.
  private static func serverBookmark(
    _ store: AudioBookmarkStore, accountId: Int64, time: Double, title: String
  ) async throws {
    let existing = try store.bookmarks(accountId: accountId, serverItemId: item)
    try await store.applyServerBookmarks(
      accountId: accountId,
      existing + [AudioBookmark(serverItemID: item, time: time, title: title, createdAt: nil)],
      isComplete: false)
  }

  private static func outboxRows(_ database: AppDatabase) async throws -> [OutboxOperationRecord] {
    try await database.readAsync { db in
      try OutboxOperationRecord.order(Column("id")).fetchAll(db)
    }
  }
}
