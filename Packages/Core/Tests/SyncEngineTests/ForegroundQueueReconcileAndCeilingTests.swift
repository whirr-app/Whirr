import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// `AppEnvironment`'s foreground pair runs the Up Next reconciler and then the storage ceiling back
/// to back. Each half is unit-tested against fakes; these run the real pair over one real
/// database, as the sequence could only fail to converge through a disagreement between two
/// queries: the reconciler re-requesting on every foreground what the ceiling then evicts.
/// `StorageEvictionStore`'s candidate query excludes every `listeningQueueEntry` identity, so the
/// reconciler's request survives the following eviction and the second foreground finds nothing
/// left to request.
@Suite("Foreground reconcile-then-evict")
struct ForegroundQueueReconcileAndCeilingTests {

  @Test("a queued identity is requested once and the following ceiling evicts elsewhere")
  func queuedIdentityIsRequestedOnceAndSurvivesTheCeiling() async throws {
    let fixture = try await Fixture(storageCeilingBytes: 1_000, requestedDownloadBytes: 800)
    let queued = try await fixture.insertBook(serverItemID: "queued-book")
    try await fixture.enqueueInUpNext(itemID: queued)
    let cold = try await fixture.insertBook(serverItemID: "cold-book")
    try fixture.insertCompletedDownload(itemID: cold, bytes: 900)

    await fixture.foregroundTransition()
    await fixture.foregroundTransition()

    // One request across both transitions, and the row it created is still on disk: the eviction
    // that followed it took the unqueued download instead.
    #expect(
      await fixture.timeline.events == [
        .requested(itemID: "queued-book"),
        .evicted(itemID: "cold-book"),
      ])
    #expect(try fixture.completedBytes(serverItemID: "queued-book") == 800)
    #expect(try fixture.downloadRowCount(serverItemID: "cold-book") == 0)
  }

  @Test("a queue identity over the whole ceiling is neither evicted nor re-requested")
  func queueIdentityOverTheWholeCeilingDoesNotChurn() async throws {
    let fixture = try await Fixture(storageCeilingBytes: 100, requestedDownloadBytes: 800)
    let queued = try await fixture.insertBook(serverItemID: "queued-book")
    try await fixture.enqueueInUpNext(itemID: queued)

    await fixture.foregroundTransition()
    await fixture.foregroundTransition()

    // The ceiling stays unmet for as long as the identity is queued. That is the designed
    // trade-off (Up Next outranks the ceiling), and it costs one request, not one per foreground.
    #expect(await fixture.timeline.events == [.requested(itemID: "queued-book")])
    #expect(try fixture.completedBytes(serverItemID: "queued-book") == 800)
    #expect(await fixture.ceiling.lastResult?.unmetBytes == 700)
  }

  @Test("removal from Up Next is what makes the identity evictable again")
  func removalFromUpNextReleasesTheIdentityToTheCeiling() async throws {
    let fixture = try await Fixture(storageCeilingBytes: 100, requestedDownloadBytes: 800)
    let queued = try await fixture.insertBook(serverItemID: "queued-book")
    try await fixture.enqueueInUpNext(itemID: queued)
    await fixture.foregroundTransition()

    try await fixture.removeFromUpNext(itemID: queued)
    await fixture.foregroundTransition()

    #expect(
      await fixture.timeline.events == [
        .requested(itemID: "queued-book"),
        .evicted(itemID: "queued-book"),
      ])
    #expect(try fixture.downloadRowCount(serverItemID: "queued-book") == 0)
  }

  // MARK: - Fixture

  private struct Fixture: Sendable {
    let database: AppDatabase
    let accountID: Int64
    let libraryID: Int64
    let downloadStore: DownloadStore
    let timeline: AutomationTimeline
    let reconciler: QueueAutoDownloadReconciler
    let ceiling: StorageCeilingCoordinator

    init(storageCeilingBytes: Int64, requestedDownloadBytes: Int64) async throws {
      database = try AppDatabase.inMemory()
      (accountID, libraryID) = try await Self.insertAccountAndLibrary(database)
      downloadStore = try DownloadStore(database: database)
      timeline = AutomationTimeline()

      let preferences = FakeDownloadPreferences(
        queueAutoDownloadPolicy: .always, storageCeilingBytes: storageCeilingBytes)
      let queueStore = ListeningQueueStore(database: database, accountId: accountID)
      reconciler = QueueAutoDownloadReconciler(
        candidateProvider: queueStore,
        requesting: CompletingDownloadRequester(
          database: database, downloadStore: downloadStore, accountID: accountID,
          bytes: requestedDownloadBytes, timeline: timeline),
        preferences: preferences,
        networkConditions: FakeNetworkConditions())
      ceiling = StorageCeilingCoordinator(
        preferences: preferences,
        storageReading: DefaultStorageReading(database: database),
        evictionClaiming: StorageEvictionStore(database: database, accountId: accountID),
        purging: FinalizingPurging(
          database: database, downloadStore: downloadStore, timeline: timeline))
    }

    /// `AppEnvironment.swift`'s foreground body: reconcile, then enforce, in that order.
    func foregroundTransition() async {
      await reconciler.run()
      _ = await ceiling.enforce()
    }

    func insertBook(serverItemID: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
          mediaKind: "book", title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
        return item.id!
      }
    }

    func enqueueInUpNext(itemID: Int64) async throws {
      try await database.writeAsync { db in
        var entry = ListeningQueueEntryRecord(
          accountId: accountID, itemId: itemID, podcastEpisodeId: nil, position: 0)
        try entry.insert(db)
      }
    }

    func removeFromUpNext(itemID: Int64) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: "DELETE FROM listeningQueueEntry WHERE accountId = ? AND itemId = ?",
          arguments: [accountID, itemID])
      }
    }

    @discardableResult
    func insertCompletedDownload(itemID: Int64, bytes: Int64) throws -> Int64 {
      let record = try downloadStore.enqueue(
        accountId: accountID, itemId: itemID, serverFileIno: UUID().uuidString, orderIndex: 0,
        destinationRelativePath: "\(UUID().uuidString).bin", expectedBytes: bytes,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      _ = try downloadStore.transition(downloadId: record.id!, to: .downloading)
      return try downloadStore.complete(downloadId: record.id!, finalSizeBytes: bytes).id!
    }

    func completedBytes(serverItemID: String) throws -> Int64 {
      try database.read { db in
        try Int64.fetchOne(
          db,
          sql: """
            SELECT COALESCE(SUM(download.receivedBytes), 0)
            FROM download
            JOIN item ON item.id = download.itemId AND item.accountId = download.accountId
            WHERE item.accountId = ? AND item.serverItemId = ? AND download.state = ?
            """,
          arguments: [accountID, serverItemID, DownloadState.completed.rawValue]) ?? 0
      }
    }

    func downloadRowCount(serverItemID: String) throws -> Int {
      try database.read { db in
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*)
            FROM download
            JOIN item ON item.id = download.itemId AND item.accountId = download.accountId
            WHERE item.accountId = ? AND item.serverItemId = ?
            """,
          arguments: [accountID, serverItemID]) ?? 0
      }
    }

    private static func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
      accountID: Int64, libraryID: Int64
    ) {
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: UUID().uuidString, serverVersion: "2.10.0")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: UUID().uuidString, mediaType: "book",
          name: "Library")
        try library.insert(db)
        return (account.id!, library.id!)
      }
    }
  }
}

/// The interleaved request/evict sequence across foreground transitions, which is the only thing a
/// churn loop would show up in.
private actor AutomationTimeline {
  enum Event: Equatable, Sendable {
    case requested(itemID: String)
    case evicted(itemID: String)
  }

  private(set) var events: [Event] = []

  func record(_ event: Event) {
    events.append(event)
  }
}

/// Stands in for `DownloadCoordinator` plus a transfer that finishes before the next foreground:
/// the request leaves a completed row, so the identity's bytes count against the ceiling and its
/// candidacy for a further request depends on that row surviving.
private struct CompletingDownloadRequester: QueueAutoDownloadRequesting {
  let database: AppDatabase
  let downloadStore: DownloadStore
  let accountID: Int64
  let bytes: Int64
  let timeline: AutomationTimeline

  func requestDownload(itemID: String) async throws {
    await timeline.record(.requested(itemID: itemID))
    let itemRowID = try await database.readAsync { [accountID] db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM item WHERE accountId = ? AND serverItemId = ?",
        arguments: [accountID, itemID])
    }
    guard let itemRowID else { return }
    let record = try downloadStore.enqueue(
      accountId: accountID, itemId: itemRowID, serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: "\(UUID().uuidString).bin", expectedBytes: bytes,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try downloadStore.transition(downloadId: record.id!, to: .downloading)
    _ = try downloadStore.complete(downloadId: record.id!, finalSizeBytes: bytes)
  }

  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await requestDownload(itemID: itemID)
  }
}

/// The file half of the deletion protocol, without files: the claim has already marked the row
/// `.deleting`, so finishing the row removal is what a real purge would leave behind.
private struct FinalizingPurging: StorageCeilingPurging {
  let database: AppDatabase
  let downloadStore: DownloadStore
  let timeline: AutomationTimeline

  func cancelStorageCeilingDownload(downloadId: Int64) async {}

  func deleteStorageCeilingDownload(downloadId: Int64) async throws {
    let serverItemID = try await database.readAsync { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT item.serverItemId
          FROM download
          JOIN item ON item.id = download.itemId AND item.accountId = download.accountId
          WHERE download.id = ?
          """,
        arguments: [downloadId])
    }
    if let serverItemID {
      await timeline.record(.evicted(itemID: serverItemID))
    }
    try downloadStore.finalizeDeletion(downloadId: downloadId)
  }

  func scheduleAfterStorageCeiling() async {}
}
