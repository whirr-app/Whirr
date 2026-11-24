import Foundation
import TestSupport
import Testing

@testable import Persistence

/// File layout, protection and integrity for downloaded media. `DownloadFileStore` owns the one
/// write (moving URLSession's temp file to its deterministic, account-scoped destination) and the
/// one removal. Each pairs with a separate DB transaction, the only thing allowed to mark a row
/// `completed` or gone.
@Suite struct DownloadFileStoreTests {

  // MARK: - Deterministic, account-scoped destinations

  @Test func destinationRelativePathIsDeterministicForTheSameInputs() {
    let first = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: "abc123",
      mimeType: "audio/mp4")
    let second = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: "abc123",
      mimeType: "audio/mp4")
    #expect(first == second)
  }

  @Test func audioMpegDownloadsUseTheMp3ExtensionAVFoundationRecognizesLocally() {
    let path = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: 20, orderIndex: 0,
      serverFileIno: "podcast-audio", mimeType: "audio/mpeg")

    #expect(path.hasSuffix(".mp3"))
  }

  @Test func destinationRelativePathIsScopedByAccountAndNeverAbsolute() {
    let accountOne = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: "abc123",
      mimeType: "audio/mp4")
    let accountTwo = DownloadFileStore.destinationRelativePath(
      accountId: 2, itemId: 10, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: "abc123",
      mimeType: "audio/mp4")

    #expect(accountOne != accountTwo)
    #expect(accountOne.hasPrefix("1/"))
    #expect(accountTwo.hasPrefix("2/"))
    #expect(accountOne.hasPrefix("/") == false, "no absolute path is ever persisted")
    #expect(accountOne.contains("..") == false)
  }

  @Test func destinationRelativePathDiffersByOrderAndFileIno() {
    let a = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: nil, orderIndex: 0, serverFileIno: "ino-a",
      mimeType: "audio/mp4")
    let b = DownloadFileStore.destinationRelativePath(
      accountId: 1, itemId: 10, podcastEpisodeId: nil, orderIndex: 1, serverFileIno: "ino-b",
      mimeType: "audio/mp4")
    #expect(a != b)
  }

  // MARK: - Protection applied to the root before first write, verified per file

  @Test func rootIsProtectedBeforeAnyFileIsWrittenAndEachCompletedFileIsVerified() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let fileAttributes = FakeFileAttributeApplying()
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)

    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: fileAttributes, downloadStore: downloadStore)

    #expect(fileAttributes.downloadsRootProtectionCalls.contains(root))
    #expect(
      fileAttributes.downloadsRootWasEmptyOnFirstProtection == true,
      "the root must be protected before any download file exists inside it")

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 100)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 100)

    _ = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: temp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 100))

    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    #expect(fileAttributes.downloadedFileProtectionCalls.contains(destinationURL))
  }

  // MARK: - Atomic same-volume move, then a separate completion transaction

  @Test func aValidTransferMovesTheTempFileIntoPlaceAndOnlyThenMarksTheRowCompleted() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 42)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 42)

    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: temp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 42))

    #expect(completed.state == .completed)
    #expect(completed.isPlayable)
    #expect(completed.receivedBytes == 42)

    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(FileManager.default.fileExists(atPath: temp.path) == false, "the temp file was moved, not copied")

    let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
    #expect((attributes[.size] as? NSNumber)?.int64Value == 42)
  }

  @Test func aFileAlreadyMovedIntoItsDestinationIsValidatedInPlaceWithoutDeletingIt() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 42)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 42).write(to: destinationURL)

    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: destinationURL,
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 42))

    #expect(completed.state == .completed)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    #expect(try Data(contentsOf: destinationURL) == Data(repeating: 0x42, count: 42))
  }

  @Test func aCrashBetweenTheRenameAndTheCompletionCommitLeavesAResumableNonPlayableOrphanNeverAPhantomPlayableRow()
    async throws
  {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 10)
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)

    // Simulates a crash: the atomic rename into place already happened (a dead earlier
    // attempt), but the DB completion transaction never ran, so the row is still `downloading`
    // (launch reconciliation would flip it to `interrupted`, equally "not completed").
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 10).write(to: destinationURL)

    let stillDownloading = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(stillDownloading.state == .downloading, "never a phantom-playable row")
    #expect(stillDownloading.isPlayable == false)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path), "the orphan file is on disk, resumable")

    // Resumable: a fresh completion attempt for the same row succeeds and overwrites the orphan.
    let temp = try makeTempFile(bytes: 10)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: temp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 10))
    #expect(completed.state == .completed)
  }

  @Test func a206ResumedResponseWithMatchingContentRangeTotalStores() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1_000)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 1_000).write(to: destinationURL)

    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: destinationURL,
      response: DownloadTransferResponse(
        httpStatusCode: 206, mimeType: "audio/mp4", contentLength: 900,
        contentRange: "bytes 100-999/1000"))

    #expect(completed.state == .completed)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
  }

  @Test func a206ResponseWithAMismatchedContentRangeTotalIsQuarantined() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1_000)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 1_000).write(to: destinationURL)

    #expect(throws: DownloadCompletionFailure(category: .validation, validationReason: .contentRangeTotal)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: destinationURL,
        response: DownloadTransferResponse(
          httpStatusCode: 206, mimeType: "audio/mp4", contentLength: 1_000,
          contentRange: "bytes 0-999/999"))
    }

    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  @Test func a206ResponseWithoutAContentRangeFallsThroughToTheOnDiskGuard() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let storedDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1_000)
    _ = try downloadStore.transition(downloadId: storedDownloadId, to: .downloading)
    let storedRecord = try #require(try downloadStore.fetch(downloadId: storedDownloadId))
    let storedDestinationURL = fileStore.absoluteURL(forRelativePath: storedRecord.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: storedDestinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 1_000).write(to: storedDestinationURL)

    let stored = try fileStore.completeTransfer(
      downloadId: storedDownloadId, temporaryFileURL: storedDestinationURL,
      response: DownloadTransferResponse(
        httpStatusCode: 206, mimeType: "audio/mp4", contentLength: 900))
    #expect(stored.state == .completed)
    #expect(FileManager.default.fileExists(atPath: storedDestinationURL.path))

    let rejectedDownloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1_000)
    _ = try downloadStore.transition(downloadId: rejectedDownloadId, to: .downloading)
    let rejectedRecord = try #require(try downloadStore.fetch(downloadId: rejectedDownloadId))
    let rejectedDestinationURL = fileStore.absoluteURL(forRelativePath: rejectedRecord.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: rejectedDestinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x42, count: 10).write(to: rejectedDestinationURL)

    #expect(throws: DownloadCompletionFailure(category: .validation, validationReason: .onDiskSize)) {
      try fileStore.completeTransfer(
        downloadId: rejectedDownloadId, temporaryFileURL: rejectedDestinationURL,
        response: DownloadTransferResponse(
          httpStatusCode: 206, mimeType: "audio/mp4", contentLength: 900))
    }

    #expect(FileManager.default.fileExists(atPath: rejectedDestinationURL.path) == false)
    let failed = try #require(try downloadStore.fetch(downloadId: rejectedDownloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  // MARK: - MIME/size mismatch quarantines the file and fails the row

  @Test func aMimeTypeMismatchQuarantinesTheFileAndFailsTheRowWithAValidationCategory() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(
      downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 10,
      expectedMimeType: "audio/mp4")
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 10)

    #expect(throws: DownloadCompletionFailure(category: .validation, validationReason: .mimeType)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "text/html", contentLength: 10))
    }

    #expect(FileManager.default.fileExists(atPath: temp.path) == false, "the mismatched file is quarantined")
    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  @Test func a200ResponseWithAShortContentLengthIsStillQuarantined() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 1000)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 10)

    #expect(throws: DownloadCompletionFailure(category: .validation, validationReason: .contentLength)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 10))
    }

    #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  @Test func aProtectionFailureQuarantinesTheDestinationAndFailsTheRowAsStorage() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileAttributes = FakeFileAttributeApplying(
      downloadedFileProtectionError: FileAttributeError.protectionNotApplied(path: "injected"))
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: fileAttributes, downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 10)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let destinationURL = fileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    let temp = try makeTempFile(bytes: 10)

    #expect(throws: DownloadCompletionFailure(category: .storage)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 10))
    }

    #expect(FileManager.default.fileExists(atPath: temp.path) == false)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .storage)
  }

  @Test func aNonSuccessStatusQuarantinesTheFileAndFailsTheRowWithAValidationCategory() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 10)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 10)

    #expect(throws: DownloadCompletionFailure(category: .validation, validationReason: .httpStatus)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(httpStatusCode: 403, mimeType: "audio/mp4", contentLength: 10))
    }

    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  // MARK: - Disk-full write failures classify `lowDisk` distinctly

  @Test func aDiskFullFailureDuringMoveIntoPlaceClassifiesLowDiskDistinctlyFromTransportOrValidation() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let outOfSpaceMover = FakeDownloadFileMoving(error: FakeDownloadFileMoving.outOfSpace)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore,
      fileMover: outOfSpaceMover)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 10)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try makeTempFile(bytes: 10)

    #expect(throws: DownloadCompletionFailure(category: .lowDisk)) {
      try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 10))
    }

    let failed = try #require(try downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .lowDisk)
    #expect(failed.errorCategory != .transport)
    #expect(failed.errorCategory != .validation)
  }

  // MARK: - Recoverable deletion protocol

  @Test func deleteMarksDeletingRemovesTheFileIdempotentlyThenDeletesTheRow() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 5)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))

    try fileStore.delete(downloadId: downloadId)

    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func deleteResumesFromAnAlreadyDeletingRowWhoseFileIsStillPresent() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 5)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let completed = try fileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: try makeTempFile(bytes: 5),
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 5))
    let destinationURL = fileStore.absoluteURL(forRelativePath: completed.destinationRelativePath)

    // Crash right after the "mark deleting" boundary: the row is `deleting`, the file is still
    // on disk. `delete` must resume from here rather than requiring a fresh mark.
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))

    try fileStore.delete(downloadId: downloadId)

    #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func deleteResumesFromAnAlreadyDeletingRowWhoseFileIsAlreadyAbsent() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    // Never completed, so no file was written, but a caller (the purge) already marked it
    // `deleting`. `delete` must finish (idempotent file removal, then the row) without erroring
    // on the missing file.
    let downloadId = try enqueue(downloadStore, accountId: accountId, itemId: itemId, expectedBytes: 5)
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)

    try fileStore.delete(downloadId: downloadId)

    #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
  }

  @Test func deleteFailsClosedForRowPathsThatEscapeTheDownloadsRoot() async throws {
    let (root, cleanup) = try makeTempRoot()
    defer { cleanup() }
    let (database, downloadStore) = try makeStore()
    let (accountId, itemId) = try await insertAccountAndItem(database)
    let fileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(), downloadStore: downloadStore)

    let traversalName = "abs-delete-escape-\(UUID().uuidString)"
    let traversalSentinel = root.deletingLastPathComponent().appendingPathComponent(traversalName)
    let absoluteSentinel = FileManager.default.temporaryDirectory.appendingPathComponent(
      "abs-delete-absolute-\(UUID().uuidString)")
    try Data([0xA5, 0x5A]).write(to: traversalSentinel)
    try Data([0x5A, 0xA5]).write(to: absoluteSentinel)
    defer {
      try? FileManager.default.removeItem(at: traversalSentinel)
      try? FileManager.default.removeItem(at: absoluteSentinel)
    }

    for relativePath in ["../\(traversalName)", absoluteSentinel.path] {
      let record = try downloadStore.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: UUID().uuidString, orderIndex: 0,
        destinationRelativePath: relativePath, expectedBytes: 5,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      let downloadId = try #require(record.id)

      try fileStore.delete(downloadId: downloadId)

      #expect(try downloadStore.fetch(downloadId: downloadId) == nil)
    }
    #expect(try Data(contentsOf: traversalSentinel) == Data([0xA5, 0x5A]))
    #expect(try Data(contentsOf: absoluteSentinel) == Data([0x5A, 0xA5]))
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

  private func enqueue(
    _ store: DownloadStore, accountId: Int64, itemId: Int64, expectedBytes: Int64 = 10,
    expectedMimeType: String = "audio/mp4"
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ino-\(UUID().uuidString)", mimeType: expectedMimeType)
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: UUID().uuidString, orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: expectedBytes,
      expectedMimeType: expectedMimeType, fileDurationSeconds: 60)
    return record.id!
  }

  private func makeTempRoot() throws -> (url: URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadFileStoreTests-\(UUID().uuidString)", isDirectory: true)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
  }

  private func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
  }
}
