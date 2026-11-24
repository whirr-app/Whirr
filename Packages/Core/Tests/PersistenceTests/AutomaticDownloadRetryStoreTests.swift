import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The persisted retry count and deadline on both download tables. The count must survive a
/// relaunch, so it lives on the row rather than in the coordinator.
@Suite struct AutomaticDownloadRetryStoreTests {
  private let failedAt = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: - Schema

  @Test func v79AddsTheRetryColumnsToBothDownloadTables() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue)
    try queue.read { db in
      for table in ["download", "rssDownload"] {
        let columns = try db.columns(in: table)
        let count = try #require(columns.first { $0.name == "autoRetryCount" })
        #expect(count.isNotNull)
        #expect(count.defaultValueSQL == "0")
        let deadline = try #require(columns.first { $0.name == "autoRetryNotBefore" })
        #expect(deadline.isNotNull == false)
        #expect(deadline.defaultValueSQL == nil)
      }
    }
  }

  // MARK: - ABS

  @Test func absArmingStoresADeadlineOnlyOnAFailedAutomaticRow() async throws {
    let fixture = try await ABSFixture.make()
    let automatic = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    let manual = try await fixture.failedRow(origin: .manual, serverFileIno: "m")
    let deadline = failedAt.addingTimeInterval(600)

    #expect(try await fixture.store.armAutomaticRetryAsync(downloadId: automatic, notBefore: deadline))
    #expect(try await fixture.store.armAutomaticRetryAsync(downloadId: manual, notBefore: deadline) == false)
    #expect(try await fixture.store.fetchAsync(downloadId: automatic)?.autoRetryNotBefore == deadline)
    #expect(try await fixture.store.fetchAsync(downloadId: manual)?.autoRetryNotBefore == nil)

    // A row the user already moved on from is not re-armed.
    _ = try await fixture.store.transitionAsync(downloadId: automatic, to: .pending)
    #expect(try await fixture.store.armAutomaticRetryAsync(downloadId: automatic, notBefore: deadline) == false)
  }

  @Test func absDueRetriesAreOldestDeadlineFirstAndBounded() async throws {
    let fixture = try await ABSFixture.make()
    let late = try await fixture.failedRow(origin: .automatic, serverFileIno: "late")
    let early = try await fixture.failedRow(origin: .automatic, serverFileIno: "early")
    let notYet = try await fixture.failedRow(origin: .automatic, serverFileIno: "not-yet")
    let unarmed = try await fixture.failedRow(origin: .automatic, serverFileIno: "unarmed")
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: late, notBefore: failedAt.addingTimeInterval(300))
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: early, notBefore: failedAt.addingTimeInterval(100))
    _ = try await fixture.store.armAutomaticRetryAsync(
      downloadId: notYet, notBefore: failedAt.addingTimeInterval(10_000))

    let now = failedAt.addingTimeInterval(1_000)
    let due = try await fixture.store.fetchDueAutomaticRetriesAsync(now: now, limit: 5)
    #expect(due.compactMap(\.id) == [early, late])
    let bounded = try await fixture.store.fetchDueAutomaticRetriesAsync(now: now, limit: 1)
    #expect(bounded.compactMap(\.id) == [early])
    #expect(due.contains { $0.id == unarmed } == false)
  }

  @Test func absRequeueSpendsOneAttemptAndClearsTheDeadline() async throws {
    let fixture = try await ABSFixture.make()
    let id = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    let deadline = failedAt.addingTimeInterval(600)
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: deadline)

    #expect(try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt) == nil)
    let requeued = try #require(
      try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: deadline))
    #expect(requeued.state == .pending)
    #expect(requeued.autoRetryCount == 1)
    #expect(requeued.autoRetryNotBefore == nil)
    #expect(requeued.errorCategory == nil)
    // Already pending: a second sweep in the same pass must not spend another attempt.
    #expect(try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: deadline) == nil)
  }

  @Test func absRequeueSkipsARowPromotedToManual() async throws {
    let fixture = try await ABSFixture.make()
    let id = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    _ = try await fixture.store.promoteToManualAsync(downloadId: id)
    #expect(try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt) == nil)
    #expect(try await fixture.store.fetchDueAutomaticRetriesAsync(now: failedAt, limit: 2).isEmpty)
  }

  @Test func absEveryTransitionClearsTheDeadlineAndTryAgainResetsTheCount() async throws {
    let fixture = try await ABSFixture.make()
    let id = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    _ = try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt)
    _ = try await fixture.store.transitionAsync(downloadId: id, to: .downloading)
    // A fresh failure is written without a deadline, and keeps the attempts already spent; only
    // arming adds a deadline.
    let refailed = try await fixture.store.transitionAsync(downloadId: id, to: .failed, errorCategory: .transport)
    #expect(refailed.autoRetryNotBefore == nil)
    #expect(refailed.autoRetryCount == 1)

    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    #expect(try await fixture.store.fetchAsync(downloadId: id)?.autoRetryNotBefore == failedAt)
    // Try Again is the generic `.failed -> .pending` edge.
    let retried = try await fixture.store.transitionAsync(downloadId: id, to: .pending)
    #expect(retried.autoRetryCount == 0)
    #expect(retried.autoRetryNotBefore == nil)
  }

  @Test func absCompletionResetsTheCount() async throws {
    let fixture = try await ABSFixture.make()
    let id = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    _ = try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt)
    _ = try await fixture.store.transitionAsync(downloadId: id, to: .downloading)
    let completed = try fixture.store.complete(downloadId: id, finalSizeBytes: 100)
    #expect(completed.autoRetryCount == 0)
    #expect(try await fixture.store.fetchAsync(downloadId: id)?.autoRetryCount == 0)
  }

  @Test func absCountSurvivesARelaunch() async throws {
    let fixture = try await ABSFixture.make()
    let id = try await fixture.failedRow(origin: .automatic, serverFileIno: "a")
    _ = try await fixture.store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    _ = try await fixture.store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt)
    _ = try await fixture.store.transitionAsync(downloadId: id, to: .downloading)

    let relaunched = try DownloadStore(database: fixture.database)
    let row = try #require(try await relaunched.fetchAsync(downloadId: id))
    #expect(row.state == .interrupted)
    #expect(row.autoRetryCount == 1)
  }

  // MARK: - RSS

  @Test func rssArmDueRequeueAndResetFollowTheSameRules() async throws {
    let database = try AppDatabase.inMemory()
    let store = try RSSDownloadStore(database: database)
    let automatic = try await rssFailedRow(database, store: store, suffix: "auto", origin: .automatic)
    let manual = try await rssFailedRow(database, store: store, suffix: "manual", origin: .manual)
    let deadline = failedAt.addingTimeInterval(600)

    #expect(try await store.armAutomaticRetryAsync(downloadId: automatic, notBefore: deadline))
    #expect(try await store.armAutomaticRetryAsync(downloadId: manual, notBefore: deadline) == false)
    #expect(try await store.fetchDueAutomaticRetriesAsync(now: failedAt, limit: 2).isEmpty)
    #expect(try await store.fetchDueAutomaticRetriesAsync(now: deadline, limit: 2).compactMap(\.id) == [automatic])

    #expect(try await store.requeueAutomaticRetryAsync(downloadId: automatic, now: failedAt) == nil)
    let requeued = try #require(try await store.requeueAutomaticRetryAsync(downloadId: automatic, now: deadline))
    #expect(requeued.state == .pending)
    #expect(requeued.autoRetryCount == 1)
    #expect(requeued.autoRetryNotBefore == nil)
    #expect(requeued.errorCode == nil)
    #expect(requeued.updatedAt == deadline)

    _ = try await store.transitionAsync(downloadId: automatic, to: .downloading)
    _ = try await store.transitionAsync(downloadId: automatic, to: .failed, errorCode: .transport)
    #expect(try await store.fetchAsync(downloadId: automatic)?.autoRetryCount == 1)
    _ = try await store.armAutomaticRetryAsync(downloadId: automatic, notBefore: deadline)
    let retried = try await store.transitionAsync(downloadId: automatic, to: .pending)
    #expect(retried.autoRetryCount == 0)
    #expect(retried.autoRetryNotBefore == nil)

    _ = try await store.transitionAsync(downloadId: automatic, to: .downloading)
    let relaunched = try RSSDownloadStore(database: database)
    _ = try await relaunched.transitionAsync(downloadId: automatic, to: .pending)
    _ = try await relaunched.transitionAsync(downloadId: automatic, to: .downloading)
    _ = try await relaunched.transitionAsync(downloadId: automatic, to: .failed, errorCode: .transport)
    _ = try await relaunched.armAutomaticRetryAsync(downloadId: automatic, notBefore: deadline)
    _ = try await relaunched.requeueAutomaticRetryAsync(downloadId: automatic, now: deadline)
    _ = try await relaunched.transitionAsync(downloadId: automatic, to: .downloading)
    let completed = try await relaunched.completeAsync(downloadId: automatic, actualBytes: 10)
    #expect(completed.autoRetryCount == 0)
  }

  @Test func rssRequeueSkipsARowPromotedToManual() async throws {
    let database = try AppDatabase.inMemory()
    let store = try RSSDownloadStore(database: database)
    let id = try await rssFailedRow(database, store: store, suffix: "auto", origin: .automatic)
    _ = try await store.armAutomaticRetryAsync(downloadId: id, notBefore: failedAt)
    _ = try await store.promoteToManualAsync(downloadId: id)
    #expect(try await store.requeueAutomaticRetryAsync(downloadId: id, now: failedAt) == nil)
  }

  // MARK: - Fixtures

  private struct ABSFixture {
    let database: AppDatabase
    let store: DownloadStore
    let accountId: Int64
    let itemId: Int64
    let episodeId: Int64

    static func make() async throws -> ABSFixture {
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
          accountId: account.id!, libraryId: library.id!, serverItemId: "item-1", mediaKind: "podcast",
          title: "Title", sortTitle: "title")
        try item.insert(db)
        var episode = PodcastEpisodeRecord(
          accountId: account.id!, itemId: item.id!, serverEpisodeId: "ep-1", title: "Episode",
          lastSeenGeneration: 1)
        try episode.insert(db)
        return (account.id!, item.id!, episode.id!)
      }
      return ABSFixture(
        database: database, store: try DownloadStore(database: database), accountId: ids.0, itemId: ids.1,
        episodeId: ids.2)
    }

    func failedRow(origin: DownloadOrigin, serverFileIno: String) async throws -> Int64 {
      let row = try store.enqueue(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: serverFileIno,
        orderIndex: 0, destinationRelativePath: "item-1/\(serverFileIno).mp3", expectedBytes: 100,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 30, origin: origin)
      let id = try #require(row.id)
      _ = try await store.transitionAsync(downloadId: id, to: .downloading)
      _ = try await store.transitionAsync(downloadId: id, to: .failed, errorCategory: .transport)
      return id
    }
  }

  private func rssFailedRow(
    _ database: AppDatabase, store: RSSDownloadStore, suffix: String, origin: DownloadOrigin
  ) async throws -> Int64 {
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
