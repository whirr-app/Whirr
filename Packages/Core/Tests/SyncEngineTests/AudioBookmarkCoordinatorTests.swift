import Foundation
import GRDB
import Persistence
import Testing

@testable import SyncEngine

/// The coordinator resolves the account, floors new bookmarks to whole seconds, and asks for
/// a drain only after a write committed.
@Suite("Audio bookmark coordinator")
struct AudioBookmarkCoordinatorTests {
  private static let item = "item_book"
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  @Test("adding floors the position to a whole second, writes the outbox row and requests a drain")
  func addFloorsAndDrains() async throws {
    let fixture = try await Fixture()

    let outcome = try await fixture.coordinator.addBookmark(
      itemID: Self.item, at: 754.92, title: "Chapter 7")

    let expected = AudioBookmark(
      serverItemID: Self.item, time: 754, title: "Chapter 7", createdAt: Self.now)
    #expect(outcome == .created(expected))
    #expect(await fixture.drains.count == 1)
    let rows = try await fixture.outboxRows()
    #expect(rows.map(\.operationKind) == [OutboxOperationKind.bookmarkCreate.rawValue])
    #expect(rows.first?.payloadBookmarkTime == 754)
  }

  @Test("a refused add writes nothing and requests no drain")
  func refusedAddDoesNotDrain() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.coordinator.addBookmark(itemID: Self.item, at: 100.2, title: "First")

    let outcome = try await fixture.coordinator.addBookmark(
      itemID: Self.item, at: 100.9, title: "Second")

    guard case .tooCloseToExisting = outcome else {
      Issue.record("expected a refusal, got \(outcome)")
      return
    }
    #expect(await fixture.drains.count == 1)
    #expect(try await fixture.outboxRows().count == 1)
  }

  @Test("rename and delete request a drain only when they wrote")
  func renameAndDeleteDrainOnlyOnWrite() async throws {
    let fixture = try await Fixture()
    _ = try await fixture.coordinator.addBookmark(itemID: Self.item, at: 10, title: "Ten")

    try await fixture.coordinator.renameBookmark(itemID: Self.item, time: 10, to: "Renamed")
    try await fixture.coordinator.renameBookmark(itemID: Self.item, time: 99, to: "Missing")
    try await fixture.coordinator.deleteBookmark(itemID: Self.item, time: 99)
    #expect(await fixture.drains.count == 2)

    try await fixture.coordinator.deleteBookmark(itemID: Self.item, time: 10)
    #expect(await fixture.drains.count == 3)
    // The unsent create absorbed the rename and was then cancelled by the delete.
    #expect(try await fixture.outboxRows().isEmpty)
  }

  @Test("every intent throws notAuthenticated with no account")
  func intentsRequireAnAccount() async throws {
    let coordinator = AudioBookmarkCoordinator(database: try AppDatabase.inMemory())

    await #expect(throws: AudioBookmarkIntentError.notAuthenticated) {
      _ = try await coordinator.addBookmark(itemID: Self.item, at: 1, title: "t")
    }
    await #expect(throws: AudioBookmarkIntentError.notAuthenticated) {
      try await coordinator.renameBookmark(itemID: Self.item, time: 1, to: "t")
    }
    await #expect(throws: AudioBookmarkIntentError.notAuthenticated) {
      try await coordinator.deleteBookmark(itemID: Self.item, time: 1)
    }
  }

  @Test("the observation follows the signed-in account's bookmarks for the item")
  func observationFollowsTheItem() async throws {
    let fixture = try await Fixture()
    var iterator = fixture.coordinator.observeBookmarks(itemID: Self.item).makeAsyncIterator()
    #expect(await iterator.next() == [])

    _ = try await fixture.coordinator.addBookmark(itemID: Self.item, at: 42, title: "Answer")

    #expect(await iterator.next()?.map(\.time) == [42])
  }

  @Test("the observation is empty and finished with no account")
  func observationWithoutAccountFinishes() async throws {
    let coordinator = AudioBookmarkCoordinator(database: try AppDatabase.inMemory())
    var iterator = coordinator.observeBookmarks(itemID: Self.item).makeAsyncIterator()

    #expect(await iterator.next() == [])
    #expect(await iterator.next() == nil)
  }

  // MARK: - Fixture

  private actor DrainCounter {
    private(set) var count = 0
    func increment() { count += 1 }
  }

  private struct Fixture {
    let database: AppDatabase
    let drains = DrainCounter()
    let coordinator: AudioBookmarkCoordinator

    init() async throws {
      database = try AppDatabase.inMemory()
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.test",
          serverUserId: "user", serverVersion: "2.35.1")
        try account.insert(db)
      }
      let drains = drains
      coordinator = AudioBookmarkCoordinator(
        database: database, requestDrain: { await drains.increment() }, now: { AudioBookmarkCoordinatorTests.now })
    }

    func outboxRows() async throws -> [OutboxOperationRecord] {
      try await database.readAsync { db in
        try OutboxOperationRecord.order(Column("id")).fetchAll(db)
      }
    }
  }
}
