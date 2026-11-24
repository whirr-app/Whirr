import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The integrity sweep reconciles the `download` table against what is on disk. It re-derives
/// everything from the current rows and directory tree, never a separately tracked manifest, so
/// it is safe to run on every launch and again before playback source resolution.
@Suite struct DownloadIntegritySweepTests {

  @Test func scopedValidationRepairsOnlyTheSelectedItemAndDoesNotEnumerateOrphans() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, selectedItemId) = try await insertAccountAndItem(database)
    let otherItemId = try await insertItem(database, accountId: accountId, serverItemId: "item-2")
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let selectedDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: selectedItemId)
    let otherDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: otherItemId)
    for downloadId in [selectedDownloadId, otherDownloadId] {
      _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
      let completed = try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
      try FileManager.default.removeItem(
        at: fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath))
    }
    let orphanURL = root.appendingPathComponent("orphan/untouched.m4b")
    try FileManager.default.createDirectory(
      at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x01]).write(to: orphanURL)

    let result = try DownloadIntegritySweep(
      rootURL: root, downloadStore: downloadStore
    ).validate(itemID: selectedItemId)

    #expect(result.failedMissingFileDownloadIds == [selectedDownloadId])
    #expect(result.finishedDeletionDownloadIds.isEmpty)
    #expect(result.removedOrphanRelativePaths.isEmpty)
    #expect(try downloadStore.fetch(downloadId: selectedDownloadId)?.state == .failed)
    #expect(try downloadStore.fetch(downloadId: otherDownloadId)?.state == .completed)
    #expect(FileManager.default.fileExists(atPath: orphanURL.path))
  }

  @Test func scopedValidationFinishesDeletionOnlyForTheSelectedItem() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, selectedItemId) = try await insertAccountAndItem(database)
    let otherItemId = try await insertItem(database, accountId: accountId, serverItemId: "item-2")

    let selectedDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: selectedItemId)
    let otherDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: otherItemId)
    _ = try downloadStore.transition(downloadId: selectedDownloadId, to: .deleting)
    _ = try downloadStore.transition(downloadId: otherDownloadId, to: .deleting)

    let result = try DownloadIntegritySweep(
      rootURL: root, downloadStore: downloadStore
    ).validate(itemID: selectedItemId)

    #expect(result.finishedDeletionDownloadIds == [selectedDownloadId])
    #expect(try downloadStore.fetch(downloadId: selectedDownloadId) == nil)
    #expect(try downloadStore.fetch(downloadId: otherDownloadId)?.state == .deleting)
  }

  @Test func aCompletedRowWhoseFileIsMissingBecomesFailedRedownloadableNeverPlayable() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)

    // The file vanishes out from under the row (manual deletion, external tooling, corruption),
    // not through `DownloadFileStore`'s own deletion protocol.
    try FileManager.default.removeItem(at: destinationURL)

    let sweep = DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore)
    let result = try sweep.run()

    #expect(result.failedMissingFileDownloadIds == [downloadId])
    let recovered = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(recovered.state == .failed)
    #expect(recovered.isPlayable == false)
    #expect(recovered.isSchedulable == false, "failed rows are retried via an explicit transition back to pending")
  }

  @Test func anOrphanFileWithNoMatchingRowIsDeleted() throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (_, downloadStore) = try makeStore()

    let orphanURL = root.appendingPathComponent("1/999/orphan.m4b")
    try FileManager.default.createDirectory(
      at: orphanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x01]).write(to: orphanURL)

    let sweep = DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore)
    let result = try sweep.run()

    #expect(result.removedOrphanRelativePaths == ["1/999/orphan.m4b"])
    #expect(FileManager.default.fileExists(atPath: orphanURL.path) == false)
  }

  @Test("the ABS launch sweep leaves an RSS-owned enclosure file alone")
  func anRSSEnclosureSurvivesTheABSLaunchSweep() throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (_, downloadStore) = try makeStore()
    let relativePath = RSSFileStore.destinationRelativePath(
      feedId: 7, episodeRowId: 11,
      enclosureURL: URL(string: "https://example.com/episode.mp3")!,
      enclosureMimeType: "audio/mpeg")
    let enclosureURL = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: enclosureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 5).write(to: enclosureURL)

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.removedOrphanRelativePaths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: enclosureURL.path))
  }

  @Test
  func aDownloadEnqueuedAndCompletedAfterTheLaunchSnapshotKeepsItsFinishedFile() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "late-ino", mimeType: "audio/mp4")
    let temporaryFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadIntegritySweepTests-late-\(UUID().uuidString)")
    try Data(repeating: 0x42, count: 5).write(to: temporaryFileURL)
    defer { try? FileManager.default.removeItem(at: temporaryFileURL) }

    let sweep = DownloadIntegritySweep(
      rootURL: root,
      downloadStore: downloadStore,
      beforeOrphanRemoval: {
        // The callback runs after the row snapshot/keep-set and before the directory walk.
        let row = try downloadStore.enqueue(
          accountId: accountId, itemId: itemId, serverFileIno: "late-ino", orderIndex: 0,
          destinationRelativePath: relativePath, expectedBytes: 5,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
        let downloadId = try #require(row.id)
        _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
        _ = try fileStore.completeTransfer(
          downloadId: downloadId,
          temporaryFileURL: temporaryFileURL,
          response: DownloadTransferResponse(
            httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
      })

    let result = try sweep.run()

    #expect(result.removedOrphanRelativePaths.isEmpty)
    let completed = try #require(
      try downloadStore.fetchAll().first { $0.destinationRelativePath == relativePath })
    #expect(completed.state == .completed)
    #expect(
      FileManager.default.fileExists(
        atPath: fileStore.absoluteURL(forRelativePath: relativePath).path))
  }

  @Test func aDeletingRowWhoseFileIsStillPresentFinishesDeletion() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)

    // Crash right after the "mark deleting" transaction committed, but the file deletion never ran.
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))

    let sweep = DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore)
    let result = try sweep.run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func aDeletingRowWhoseFileIsAlreadyAbsentFinishesDeletion() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)

    // Never completed, so no file was written, but the row is `deleting` (a crash right before
    // the row delete boundary, e.g. after file removal already succeeded).
    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId)
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)

    let sweep = DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore)
    let result = try sweep.run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func healthyNonDeletingRowsWithPresentFilesAreLeftUntouched() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)

    let pendingId = try enqueue(downloadStore, accountId: accountId, itemId: itemId)

    let sweep = DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore)
    let result = try sweep.run()

    #expect(result.failedMissingFileDownloadIds.isEmpty)
    #expect(result.finishedDeletionDownloadIds.isEmpty)
    #expect(result.removedOrphanRelativePaths.isEmpty)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(try downloadStore.fetch(downloadId: completed.id!)?.state == .completed)
    #expect(try downloadStore.fetch(downloadId: pendingId)?.state == .pending)
  }

  @Test
  func aCompletedEbookRowWithAnExactEpubFileSurvivesTheIntegritySweep() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ebook-ino", mimeType: "application/epub+zip")
    #expect(relativePath.hasSuffix(".epub"))
    let row = try downloadStore.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-ino", orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 5,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    let downloadID = try #require(row.id)
    _ = try downloadStore.transition(downloadId: downloadID, to: .downloading)
    _ = try fileStore.completeTransfer(
      downloadId: downloadID, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "application/epub+zip", contentLength: 5))

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.failedMissingFileDownloadIds.isEmpty)
    #expect(try downloadStore.fetch(downloadId: downloadID)?.state == .completed)
    #expect(
      FileManager.default.fileExists(
        atPath: fileStore.absoluteURL(forRelativePath: relativePath).path))
  }

  @Test
  func aTruncatedCompletedEbookFileIsDemotedToStorageFailureByTheIntegritySweep() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ebook-truncated", mimeType: "application/epub+zip")
    let row = try downloadStore.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-truncated", orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 5,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    let downloadID = try #require(row.id)
    _ = try downloadStore.transition(downloadId: downloadID, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadID, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "application/epub+zip", contentLength: 5))
    try Data(repeating: 0x42, count: 4).write(
      to: fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath))

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.failedMissingFileDownloadIds == [downloadID])
    #expect(try downloadStore.fetch(downloadId: downloadID)?.state == .failed)
    #expect(try downloadStore.fetch(downloadId: downloadID)?.errorCategory == .storage)
  }

  @Test
  func anAbsentCompletedEbookFileIsDemotedExactlyLikeAnAudioFile() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ebook-absent", mimeType: "application/epub+zip")
    let row = try downloadStore.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-absent", orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 5,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    let downloadID = try #require(row.id)
    _ = try downloadStore.transition(downloadId: downloadID, to: .downloading)
    _ = try fileStore.completeTransfer(
      downloadId: downloadID, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "application/epub+zip", contentLength: 5))
    try FileManager.default.removeItem(at: fileStore.absoluteURL(forRelativePath: relativePath))

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.failedMissingFileDownloadIds == [downloadID])
    #expect(try downloadStore.fetch(downloadId: downloadID)?.state == .failed)
  }

  /// Pairs with `DownloadStore.tombstonedEpisodeDownloads`: an episode soft-delete is a
  /// reversible sync inference, so the sweep must not turn it into a file deletion. Reclaiming
  /// those bytes is an explicit intent (`DownloadCoordinator.purgeTombstonedEpisodeDownloads`),
  /// never a launch-time side effect.
  @Test func aCompletedEpisodeDownloadBehindASoftDeletedEpisodeIsNeverSweptAway() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, showId, episodeId) = try await insertAccountShowAndEpisode(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: showId, podcastEpisodeId: episodeId)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [episodeId])
    }

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.finishedDeletionDownloadIds.isEmpty)
    #expect(result.removedOrphanRelativePaths.isEmpty)
    #expect(result.failedMissingFileDownloadIds.isEmpty)
    #expect(try downloadStore.fetch(downloadId: downloadId)?.state == .completed)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(
      try downloadStore.tombstonedEpisodeDownloads().compactMap(\.id) == [downloadId],
      "reported as reclaimable instead")
  }

  @Test func aDeletingRowWhosePathEscapesTheDownloadsRootLeavesTheOutsideFileAlone() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let sentinelName = "abs-sweep-escape-\(UUID().uuidString)"
    let sentinel = root.deletingLastPathComponent().appendingPathComponent(sentinelName)
    try Data([0xA5, 0x5A]).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: sentinel) }

    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: "../\(sentinelName)", expectedBytes: 5,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(try Data(contentsOf: sentinel) == Data([0xA5, 0x5A]))
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func anAbsoluteRowPathIsNeverRemovedByTheSweep() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let sentinel = FileManager.default.temporaryDirectory.appendingPathComponent(
      "abs-sweep-absolute-\(UUID().uuidString)")
    try Data([0x5A, 0xA5]).write(to: sentinel)
    defer { try? FileManager.default.removeItem(at: sentinel) }

    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: sentinel.path, expectedBytes: 5,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)

    let result = try DownloadIntegritySweep(rootURL: root, downloadStore: downloadStore).run()

    #expect(result.finishedDeletionDownloadIds == [downloadId])
    #expect(try Data(contentsOf: sentinel) == Data([0x5A, 0xA5]))
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  // MARK: - Helpers

  private func makeStore() throws -> (AppDatabase, DownloadStore) {
    let database = try AppDatabase.inMemory()
    let store = try DownloadStore(database: database)
    return (database, store)
  }

  private func insertAccountAndItem(_ database: AppDatabase) async throws -> (
    accountId: Int64, itemId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "item-1", mediaKind: "book",
        title: "Title", sortTitle: "title")
      try item.insert(db)

      return (account.id!, item.id!)
    }
  }

  private func insertItem(
    _ database: AppDatabase, accountId: Int64, serverItemId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      let libraryId = try Int64.fetchOne(
        db, sql: "SELECT id FROM library WHERE accountId = ? LIMIT 1", arguments: [accountId])
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: try #require(libraryId),
        serverItemId: serverItemId, mediaKind: "book",
        title: serverItemId, sortTitle: serverItemId)
      try item.insert(db)
      return try #require(item.id)
    }
  }

  private func insertAccountShowAndEpisode(_ database: AppDatabase) async throws -> (
    accountId: Int64, showId: Int64, episodeId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "podcast", name: "Library")
      try library.insert(db)

      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)

      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "ep-1", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)

      return (account.id!, show.id!, episode.id!)
    }
  }

  private func enqueue(
    _ store: DownloadStore, accountId: Int64, itemId: Int64, podcastEpisodeId: Int64? = nil
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId, orderIndex: 0,
      serverFileIno: "ino-\(UUID().uuidString)", mimeType: "audio/mp4")
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
      serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 5,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    return record.id!
  }

  private func makeTempRoot() throws -> (url: URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadIntegritySweepTests-\(UUID().uuidString)", isDirectory: true)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
  }

  private func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
  }
}
