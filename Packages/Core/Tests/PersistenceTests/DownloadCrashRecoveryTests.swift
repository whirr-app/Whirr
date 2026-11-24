import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Crash recovery at every legal download-transition edge. Each test commits a row into some state
/// through an on-disk `AppDatabase`, then simulates a crash by opening a fresh instance over the
/// same file. `DownloadStore` reconciles in `init`, so opening it is the relaunch moment.
@Suite struct DownloadCrashRecoveryTests {

  private static let legalEdges: [(from: DownloadState, to: DownloadState)] =
    DownloadStore.legalTransitions
    .flatMap { from, destinations in destinations.map { (from: from, to: $0) } }
    .sorted {
      let lhsFrom = String(describing: $0.from)
      let rhsFrom = String(describing: $1.from)
      if lhsFrom != rhsFrom { return lhsFrom < rhsFrom }
      return String(describing: $0.to) < String(describing: $1.to)
    }

  @Test(arguments: legalEdges)
  func crashImmediatelyAfterATransitionLeavesAConsistentResumableState(
    edge: (from: DownloadState, to: DownloadState)
  ) async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let (accountId, libraryId) = try await insertAccountAndLibrary(preCrashDatabase)
      let itemId = try await PersistenceFixtures.insertItem(
        preCrashDatabase, accountId: accountId, libraryId: libraryId)
      let store = try DownloadStore(database: preCrashDatabase)

      let downloadId = try await preCrashDatabase.writeAsync { db in
        try DownloadRecord(
          accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
          destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 60, state: edge.from
        ).inserted(db).id!
      }

      _ = try await store.transitionAsync(downloadId: downloadId, to: edge.to)
      // Process dies here. The on-disk write inside `transition` already committed durably.
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      _ = try DownloadStore(database: reopened)

      let recovered = try await reopened.readAsync { db in
        try DownloadRecord.fetchOne(db, key: downloadId)
      }
      #expect(recovered != nil, "the download row must never be lost across a crash")

      if edge.to == .downloading {
        #expect(
          recovered?.state == .interrupted,
          "a crash immediately after entering `downloading` must be discovered as `interrupted`, never trusted as still in progress"
        )
      } else {
        #expect(recovered?.state == edge.to)
      }
    }
  }

  @Test func aRowCrashedMidDownloadingIsResumableAfterReconciliation() async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let (accountId, libraryId) = try await insertAccountAndLibrary(preCrashDatabase)
      let itemId = try await PersistenceFixtures.insertItem(
        preCrashDatabase, accountId: accountId, libraryId: libraryId)
      let preCrashStore = try DownloadStore(database: preCrashDatabase)

      let created = try preCrashStore.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      let downloadId = created.id!
      _ = try await preCrashStore.transitionAsync(
        downloadId: downloadId, to: .downloading, receivedBytes: 400)
      // Force-quit here. The durable transition has committed.
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      let reopenedStore = try DownloadStore(database: reopened)

      let recovered = try reopenedStore.fetch(downloadId: downloadId)
      #expect(recovered?.state == .interrupted)
      #expect(
        recovered?.receivedBytes == 400, "partial progress survives the crash for a later resume")

      // The row is still resumable: `interrupted -> pending` is legal, then an ordinary retry.
      let requeued = try await reopenedStore.transitionAsync(downloadId: downloadId, to: .pending)
      #expect(requeued.state == .pending)
      let redownloading = try await reopenedStore.transitionAsync(
        downloadId: downloadId, to: .downloading)
      #expect(redownloading.state == .downloading)
      #expect(redownloading.receivedBytes == 400, "resume never discards already-received bytes")
    }
  }

  @Test func crashDuringDownloadingWithConcurrentUnrelatedRowsRecoversOnlyTheStrandedRow() async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let (accountId, libraryId) = try await insertAccountAndLibrary(preCrashDatabase)
      let itemId = try await PersistenceFixtures.insertItem(
        preCrashDatabase, accountId: accountId, libraryId: libraryId)
      let store = try DownloadStore(database: preCrashDatabase)

      let downloading = try store.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      let downloadingId = downloading.id!
      _ = try await store.transitionAsync(downloadId: downloadingId, to: .downloading)

      let paused = try store.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
        destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      let pausedId = paused.id!
      _ = try await store.transitionAsync(downloadId: pausedId, to: .downloading)
      _ = try await store.transitionAsync(downloadId: pausedId, to: .paused)

      let completed = try store.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-3", orderIndex: 2,
        destinationRelativePath: "item-1/file-2.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      let completedId = completed.id!
      _ = try await store.transitionAsync(downloadId: completedId, to: .downloading)
      _ = try store.complete(downloadId: completedId, finalSizeBytes: 1000)
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      _ = try DownloadStore(database: reopened)

      let rows = try await reopened.readAsync { db -> [Int64: DownloadRecord] in
        let all = try DownloadRecord.fetchAll(db)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id!, $0) })
      }
      #expect(rows.count == 3, "no row may be lost across a crash")
      #expect(rows[downloadingId]?.state == .interrupted)
      #expect(rows[pausedId]?.state == .paused, "a durable non-transferring state is never touched")
      #expect(rows[completedId]?.state == .completed)
    }
  }

  // MARK: - Helpers

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

}
