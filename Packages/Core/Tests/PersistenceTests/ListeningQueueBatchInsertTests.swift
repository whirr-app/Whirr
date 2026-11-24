import Foundation
import GRDB
import Testing

@testable import Persistence

/// `insertNext(identities:)` puts an ordered list at the front of Up Next in one transaction.
@Suite struct ListeningQueueBatchInsertTests {

  @Test("an ordered batch lands at the front in its own order")
  func orderIsKept() async throws {
    let f = try await Self.seed()
    let store = f.store
    try await store.append(identity: f.book(0))
    try await store.append(identity: f.book(1))

    let skipped = try await store.insertNext(identities: [f.book(2), f.book(3), f.book(4)])

    #expect(skipped.isEmpty)
    #expect(
      await store.fetchQueue().map(\.identity)
        == [f.book(2), f.book(3), f.book(4), f.book(0), f.book(1)])
    #expect(await store.fetchQueue().map(\.position) == [0, 1, 2, 3, 4])
  }

  @Test("an already-queued identity is moved into its place in the batch")
  func queuedIdentityIsMoved() async throws {
    let f = try await Self.seed()
    let store = f.store
    try await store.append(identity: f.book(0))
    try await store.append(identity: f.book(3))
    try await store.append(identity: f.book(1))

    try await store.insertNext(identities: [f.book(2), f.book(3), f.book(4)])

    #expect(
      await store.fetchQueue().map(\.identity)
        == [f.book(2), f.book(3), f.book(4), f.book(0), f.book(1)])
  }

  @Test("duplicates inside the batch keep their first position")
  func batchDuplicatesCollapse() async throws {
    let f = try await Self.seed()
    let store = f.store
    try await store.append(identity: f.book(0))

    try await store.insertNext(identities: [f.book(1), f.book(2), f.book(1)])

    #expect(await store.fetchQueue().map(\.identity) == [f.book(1), f.book(2), f.book(0)])
  }

  @Test("rejected identities are skipped and returned while the rest commit in order")
  func rejectedIdentitiesAreSkipped() async throws {
    let f = try await Self.seed()
    let store = f.store
    let missingEpisode = try #require(
      ListeningIdentity.podcastEpisode(itemID: f.showServerItemID, episodeID: "no-such-episode"))
    try await store.append(identity: f.book(0))

    let skipped = try await store.insertNext(
      identities: [f.book(1), f.ebook, f.book(2), missingEpisode])

    #expect(skipped == [f.ebook, missingEpisode])
    #expect(await store.fetchQueue().map(\.identity) == [f.book(1), f.book(2), f.book(0)])
  }

  @Test("an all-rejected or empty batch leaves the queue untouched")
  func nothingToInsertChangesNothing() async throws {
    let f = try await Self.seed()
    let store = f.store
    try await store.append(identity: f.book(0))

    #expect(try await store.insertNext(identities: []).isEmpty)
    #expect(try await store.insertNext(identities: [f.ebook]) == [f.ebook])
    #expect(await store.fetchQueue().map(\.identity) == [f.book(0)])
  }

  @Test(
    "a failure at either renumber checkpoint rolls the whole batch back",
    arguments: [
      ListeningQueueMutationCheckpoint.afterTemporaryRenumber,
      ListeningQueueMutationCheckpoint.afterFinalRenumber,
    ])
  func failureRollsBack(checkpointToFail: ListeningQueueMutationCheckpoint) async throws {
    struct InjectedFailure: Error {}
    let f = try await Self.seed()
    try await f.store.append(identity: f.book(0))
    try await f.store.append(identity: f.book(1))
    let failing = ListeningQueueStore(
      database: f.database, accountId: f.accountId,
      mutationCheckpoint: { checkpoint in
        if checkpoint == checkpointToFail { throw InjectedFailure() }
      })

    await #expect(throws: InjectedFailure.self) {
      try await failing.insertNext(identities: [f.book(2), f.book(1), f.book(3)])
    }

    #expect(await f.store.fetchQueue().map(\.identity) == [f.book(0), f.book(1)])
    #expect(await f.store.fetchQueue().map(\.position) == [0, 1])
  }

  // MARK: - Fixtures

  private struct Fixture {
    let database: AppDatabase
    let accountId: Int64
    let store: ListeningQueueStore
    let books: [ListeningIdentity]
    let ebook: ListeningIdentity
    let showServerItemID: String

    func book(_ index: Int) -> ListeningIdentity { books[index] }
  }

  private static func seed() async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let (accountId, books, ebook) = try await database.writeAsync {
      db -> (Int64, [ListeningIdentity], ListeningIdentity) in
      var account = AccountRecord(
        clientUUID: "client-\(UUID().uuidString)", serverBaseURL: "server",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var books: [ListeningIdentity] = []
      for number in 0..<5 {
        let serverItemID = "book-\(number)"
        var item = ItemRecord(
          accountId: account.id!, libraryId: library.id!, serverItemId: serverItemID,
          mediaKind: "book", title: "Book \(number)", sortTitle: "book \(number)",
          author: "Author", numAudioFiles: 4)
        try item.insert(db)
        books.append(try #require(ListeningIdentity.audiobook(itemID: serverItemID)))
      }
      var ebookItem = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "ebook",
        mediaKind: "book", title: "Ebook", sortTitle: "ebook", ebookFormat: "epub")
      try ebookItem.insert(db)
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      return (account.id!, books, try #require(ListeningIdentity.audiobook(itemID: "ebook")))
    }
    return Fixture(
      database: database, accountId: accountId,
      store: ListeningQueueStore(database: database, accountId: accountId),
      books: books, ebook: ebook, showServerItemID: "show")
  }
}
