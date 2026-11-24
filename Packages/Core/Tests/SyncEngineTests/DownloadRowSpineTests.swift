import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// The seam the automatic-retry path reaches both download tables through. The tables, their
/// records and their error columns stay separate; these tests pin each adapter's guarded arm, its
/// due list and its one-attempt requeue.
@Suite struct DownloadRowSpineTests {
  private let failedAt = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: - ABS

  @Test func absSpineArmsOnlyFailedAutomaticRows() async throws {
    let fixture = try await ABSRows.make()
    let automatic = try await fixture.failedRow(origin: .automatic, ino: "a")
    let manual = try await fixture.failedRow(origin: .manual, ino: "m")
    let promoted = try await fixture.failedRow(origin: .automatic, ino: "p")
    let spine = AbsDownloadRowSpine(store: fixture.store)
    let deadline = failedAt.addingTimeInterval(600)

    let automaticRow = try #require(await spine.fetch(id: automatic))
    #expect(spine.isFailedAutomatic(row: automaticRow))
    #expect(automaticRow.autoRetryCount == 0)
    #expect(automaticRow.origin == .automatic)
    #expect(await spine.arm(id: automatic, notBefore: deadline))
    #expect(try await fixture.store.fetchAsync(downloadId: automatic)?.autoRetryNotBefore == deadline)

    let manualRow = try #require(await spine.fetch(id: manual))
    #expect(spine.isFailedAutomatic(row: manualRow) == false)
    #expect(await spine.arm(id: manual, notBefore: deadline) == false)
    #expect(try await fixture.store.fetchAsync(downloadId: manual)?.autoRetryNotBefore == nil)

    // A row the user promoted to manual while it was failed is left alone.
    _ = try await fixture.store.promoteToManualAsync(downloadId: promoted)
    let promotedRow = try #require(await spine.fetch(id: promoted))
    #expect(spine.isFailedAutomatic(row: promotedRow) == false)
    #expect(await spine.arm(id: promoted, notBefore: deadline) == false)
    #expect(try await fixture.store.fetchAsync(downloadId: promoted)?.autoRetryNotBefore == nil)

    // So is one that has left `.failed` since the failure was written.
    _ = try await fixture.store.transitionAsync(downloadId: automatic, to: .pending)
    #expect(await spine.arm(id: automatic, notBefore: deadline) == false)
  }

  @Test func absSpineListsDueRowsInDeadlineOrderWithinTheLimit() async throws {
    let fixture = try await ABSRows.make()
    let late = try await fixture.failedRow(origin: .automatic, ino: "late")
    let early = try await fixture.failedRow(origin: .automatic, ino: "early")
    let unarmed = try await fixture.failedRow(origin: .automatic, ino: "unarmed")
    let manual = try await fixture.failedRow(origin: .manual, ino: "manual")
    let spine = AbsDownloadRowSpine(store: fixture.store)
    _ = await spine.arm(id: late, notBefore: failedAt.addingTimeInterval(300))
    _ = await spine.arm(id: early, notBefore: failedAt.addingTimeInterval(100))
    _ = await spine.arm(id: manual, notBefore: failedAt.addingTimeInterval(50))

    #expect(await spine.due(now: failedAt, limit: 5).isEmpty)
    let due = await spine.due(now: failedAt.addingTimeInterval(1_000), limit: 5)
    #expect(due.map(\.id) == [early, late])
    let deadlines = [failedAt.addingTimeInterval(100), failedAt.addingTimeInterval(300)]
    #expect(due.map(\.notBefore) == deadlines)
    #expect(await spine.due(now: failedAt.addingTimeInterval(1_000), limit: 1).map(\.id) == [early])
    #expect(due.contains { $0.id == unarmed || $0.id == manual } == false)
  }

  @Test func absSpineRequeuesADueRowOnceAndClearsTheFailure() async throws {
    let fixture = try await ABSRows.make()
    let id = try await fixture.failedRow(origin: .automatic, ino: "a")
    let spine = AbsDownloadRowSpine(store: fixture.store)
    let deadline = failedAt.addingTimeInterval(600)
    _ = await spine.arm(id: id, notBefore: deadline)

    // Not yet due: no attempt is spent.
    #expect(await spine.requeue(id: id, now: failedAt) == nil)

    #expect(await spine.requeue(id: id, now: deadline) == 1)
    let row = try #require(try await fixture.store.fetchAsync(downloadId: id))
    #expect(row.state == .pending)
    #expect(row.autoRetryCount == 1)
    #expect(row.autoRetryNotBefore == nil)
    #expect(row.errorCategory == nil, "the failure copy goes with the retry")

    // A repeated sweep in the same pass spends no second attempt.
    #expect(await spine.requeue(id: id, now: deadline) == nil)
  }

  // MARK: - RSS

  @Test func rssSpineArmsOnlyFailedAutomaticRows() async throws {
    let fixture = try await RSSRows.make()
    let automatic = try await fixture.failedRow(origin: .automatic, suffix: "auto")
    let manual = try await fixture.failedRow(origin: .manual, suffix: "manual")
    let promoted = try await fixture.failedRow(origin: .automatic, suffix: "promoted")
    let spine = RssDownloadRowSpine(store: fixture.store)
    let deadline = failedAt.addingTimeInterval(600)

    let automaticRow = try #require(await spine.fetch(id: automatic))
    #expect(spine.isFailedAutomatic(row: automaticRow))
    #expect(automaticRow.origin == .automatic)
    #expect(await spine.arm(id: automatic, notBefore: deadline))
    #expect(try await fixture.store.fetchAsync(downloadId: automatic)?.autoRetryNotBefore == deadline)

    #expect(await spine.arm(id: manual, notBefore: deadline) == false)
    #expect(try await fixture.store.fetchAsync(downloadId: manual)?.autoRetryNotBefore == nil)

    _ = try await fixture.store.promoteToManualAsync(downloadId: promoted, now: failedAt)
    #expect(await spine.arm(id: promoted, notBefore: deadline) == false)

    _ = try await fixture.store.transitionAsync(downloadId: automatic, to: .pending)
    #expect(await spine.arm(id: automatic, notBefore: deadline) == false)
  }

  @Test func rssSpineRequeuesADueRowOnceAndKeepsItsOwnColumns() async throws {
    let fixture = try await RSSRows.make()
    let id = try await fixture.failedRow(origin: .automatic, suffix: "auto")
    let spine = RssDownloadRowSpine(store: fixture.store)
    let deadline = failedAt.addingTimeInterval(600)
    _ = await spine.arm(id: id, notBefore: deadline)

    #expect(await spine.due(now: failedAt, limit: 2).isEmpty)
    #expect(await spine.due(now: deadline, limit: 2).map(\.id) == [id])

    #expect(await spine.requeue(id: id, now: failedAt) == nil)

    #expect(await spine.requeue(id: id, now: deadline) == 1)
    let row = try #require(try await fixture.store.fetchAsync(downloadId: id))
    #expect(row.state == .pending)
    #expect(row.autoRetryCount == 1)
    #expect(row.autoRetryNotBefore == nil)
    #expect(row.errorCode == nil, "RSS clears errorCode where ABS clears errorCategory")
    #expect(row.updatedAt == deadline, "RSS is the only table that stamps updatedAt here")

    // A repeated sweep in the same pass spends no second attempt.
    #expect(await spine.requeue(id: id, now: deadline) == nil)
  }
}

// MARK: - Fixtures

/// One failed automatic ABS row's worth of schema, mirroring `AutomaticDownloadRetryStoreTests`.
private struct ABSRows {
  let database: AppDatabase
  let store: DownloadStore
  let accountId: Int64
  let itemId: Int64
  let episodeId: Int64

  static func make() async throws -> ABSRows {
    let database = try AppDatabase.inMemory()
    let ids = try await database.writeAsync { db -> (Int64, Int64, Int64) in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "podcast", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "item-1",
        mediaKind: "podcast", title: "Title", sortTitle: "title")
      try item.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: item.id!, serverEpisodeId: "ep-1", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return (account.id!, item.id!, episode.id!)
    }
    return ABSRows(
      database: database, store: try DownloadStore(database: database), accountId: ids.0,
      itemId: ids.1, episodeId: ids.2)
  }

  func failedRow(origin: DownloadOrigin, ino: String) async throws -> Int64 {
    let row = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: ino,
      orderIndex: 0, destinationRelativePath: "item-1/\(ino).mp3", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30, origin: origin)
    let id = try #require(row.id)
    _ = try await store.transitionAsync(downloadId: id, to: .downloading)
    _ = try await store.transitionAsync(downloadId: id, to: .failed, errorCategory: .transport)
    return id
  }
}

private struct RSSRows {
  let database: AppDatabase
  let store: RSSDownloadStore

  static func make() async throws -> RSSRows {
    let database = try AppDatabase.inMemory()
    return RSSRows(database: database, store: try RSSDownloadStore(database: database))
  }

  func failedRow(origin: DownloadOrigin, suffix: String) async throws -> Int64 {
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(suffix).xml")!, title: suffix, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodes = RSSEpisodeStore(database: database)
    _ = try await episodes.applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: suffix, enclosureURL: URL(string: "https://example.com/\(suffix).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 10)
      ])
    let episode = try #require(await episodes.fetchEpisode(feedId: feedID, identityKey: suffix))
    let row = try await store.claimOrCreateAsync(episodeId: try #require(episode.id), origin: origin)
    let id = try #require(row.id)
    _ = try await store.transitionAsync(downloadId: id, to: .downloading)
    _ = try await store.transitionAsync(downloadId: id, to: .failed, errorCode: .transport)
    return id
  }
}
