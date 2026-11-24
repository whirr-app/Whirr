import Foundation
import Testing

@testable import Persistence

@Suite struct RSSFileStoreTests {
  @Test func destinationUsesExactRSSRootAndMIMEExtension() {
    #expect(
      RSSFileStore.destinationRelativePath(
        feedId: 12, episodeRowId: 34,
        enclosureURL: URL(string: "https://cdn.example.test/episode.weird")!,
        enclosureMimeType: "audio/mpeg") == "RSS/12/34.mp3")
    #expect(
      RSSFileStore.destinationRelativePath(
        feedId: 12, episodeRowId: 34,
        enclosureURL: URL(string: "https://cdn.example.test/episode.m4a")!,
        enclosureMimeType: nil) == "RSS/12/34.m4a")
  }

  /// The 2026-09 "In Our Time" case: the BBC declares 40,864,000 bytes for an enclosure whose
  /// redirected CDN response is 20,742,157 bytes of perfectly good `audio/mpeg`. The declared
  /// length is advisory metadata, not a checksum, so the file stores.
  @Test func aFileSmallerThanTheDeclaredLengthStoresWhenItMatchesTheResponse() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 40_864_000)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let served = try Self.makeSparseFile(size: 20_742_157)

    let completed = try fixture.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: served,
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 20_742_157))

    #expect(completed.state == .completed)
    #expect(completed.actualBytes == 20_742_157)
    #expect(completed.expectedBytes == 40_864_000)
    #expect(try fixture.files.validatedLocalURL(episodeId: fixture.episodeID) != nil)
  }

  /// The BBC's own final hop is a `206`; its `Content-Range` total is the authoritative length.
  @Test func a206WhoseContentRangeTotalMatchesTheFileStores() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 40_864_000)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let served = try Self.makeSparseFile(size: 20_742_157)

    let completed = try fixture.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: served,
      response: DownloadTransferResponse(
        httpStatusCode: 206, mimeType: "audio/mpeg", contentLength: 20_742_157,
        contentRange: "bytes 0-20742156/20742157"))

    #expect(completed.state == .completed)
    #expect(completed.actualBytes == 20_742_157)
  }

  /// Stale metadata lies in the other direction too: a file well past the declared length plus
  /// any tolerance still stores, bounded only by the absolute cap.
  @Test func aFileLargerThanTheDeclaredLengthStoresBelowTheCap() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 1_000_000)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let served = try Self.makeSparseFile(size: 50_000_000)

    let completed = try fixture.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: served,
      response: DownloadTransferResponse(
        httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 50_000_000))

    #expect(completed.actualBytes == 50_000_000)
    #expect(try fixture.files.validatedLocalURL(episodeId: fixture.episodeID) != nil)
  }

  /// A declared length does not raise the cap either: it is neither a floor nor a ceiling.
  @Test func aDeclaredLengthNeverBypassesTheAbsoluteCap() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: RSSFileStore.sizeCapBytes + 1)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let overCap = try Self.makeSparseFile(size: RSSFileStore.sizeCapBytes + 1)

    #expect(throws: RSSFileStoreError.sizeLimitExceeded) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: overCap,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg",
          contentLength: RSSFileStore.sizeCapBytes + 1))
    }
    #expect(FileManager.default.fileExists(atPath: overCap.path) == false)
    #expect(try fixture.store.fetch(downloadId: row.id!)?.errorCode == .validation)
  }

  /// The response's own length is authoritative where the declared length is not: a file that
  /// disagrees with `Content-Length`, or with a `206`'s `Content-Range` total, is truncated.
  @Test func aFileInconsistentWithTheFinalResponseLengthIsRejected() async throws {
    let short = try await Self.makeFixture(expectedBytes: 40_864_000)
    defer { try? FileManager.default.removeItem(at: short.root) }
    let shortRow = try await short.store.claimOrCreateAsync(episodeId: short.episodeID)
    _ = try await short.store.transitionAsync(downloadId: shortRow.id!, to: .downloading)
    let truncated = try Self.makeSparseFile(size: 20_000_000)
    #expect(throws: RSSFileStoreError.responseSizeMismatch) {
      try short.files.completeTransfer(
        downloadId: shortRow.id!, temporaryFileURL: truncated,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 20_742_157))
    }
    #expect(FileManager.default.fileExists(atPath: truncated.path) == false)
    #expect(try short.store.fetch(downloadId: shortRow.id!)?.state == .failed)

    let partial = try await Self.makeFixture(expectedBytes: nil)
    defer { try? FileManager.default.removeItem(at: partial.root) }
    let partialRow = try await partial.store.claimOrCreateAsync(episodeId: partial.episodeID)
    _ = try await partial.store.transitionAsync(downloadId: partialRow.id!, to: .downloading)
    let firstHalf = try Self.makeSparseFile(size: 1_000)
    #expect(throws: RSSFileStoreError.responseSizeMismatch) {
      try partial.files.completeTransfer(
        downloadId: partialRow.id!, temporaryFileURL: firstHalf,
        response: DownloadTransferResponse(
          httpStatusCode: 206, mimeType: "audio/mpeg", contentLength: 1_000,
          contentRange: "bytes 0-999/2000"))
    }
  }

  @Test func aNonSuccessStatusIsRejectedBeforeTheFileIsRead() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 4)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let body = try Self.makeSparseFile(size: 4)

    #expect(throws: RSSFileStoreError.invalidHTTPStatus) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: body,
        response: DownloadTransferResponse(httpStatusCode: 404, mimeType: "audio/mpeg", contentLength: 4))
    }
    #expect(FileManager.default.fileExists(atPath: body.path) == false)
    #expect(try fixture.store.fetch(downloadId: row.id!)?.errorCode == .validation)
  }

  /// A CDN error page served with `200` is the ordinary shape of a broken enclosure.
  @Test func aNonAudioResponseIsRejectedWhateverItsLength() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 40_864_000)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let page = try Self.makeSparseFile(size: 2_048)

    #expect(throws: RSSFileStoreError.invalidMIMEType) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: page,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "text/html; charset=utf-8", contentLength: 2_048))
    }
    #expect(FileManager.default.fileExists(atPath: page.path) == false)
  }

  @Test func anEmptyFileIsRejected() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 40_864_000)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: empty.path, contents: nil)

    #expect(throws: RSSFileStoreError.invalidFile) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: empty,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))
    }
    #expect(try fixture.store.fetch(downloadId: row.id!)?.state == .failed)
  }

  /// Protection is part of completion: a file that cannot be protected is not a download, and the
  /// row says so as a storage problem rather than a bad response.
  @Test func aProtectionFailureRemovesTheFileAndFailsTheRowAsStorage() async throws {
    let fixture = try await Self.makeFixture(
      expectedBytes: 4, attributes: RecordingFileAttributes(protectionFails: true))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let body = try Self.makeSparseFile(size: 4)

    #expect(throws: RSSFileStoreError.storageFailure) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: body,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))
    }
    let failed = try #require(try fixture.store.fetch(downloadId: row.id!))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .storage)
    #expect(
      FileManager.default.fileExists(atPath: fixture.files.absoluteURL(forRelativePath: failed.relativePath).path)
        == false)
  }

  /// Every rejection names its guard for the trace and its durable category for the row, and
  /// the one non-rejection (`downloadNotFound`) names neither.
  @Test func everyRejectionHasAClosedReasonAndACategory() {
    let rejections: [RSSFileStoreError] = [
      .invalidEnclosureType, .invalidRelativePath, .invalidHTTPStatus, .invalidMIMEType,
      .sizeLimitExceeded, .responseSizeMismatch, .missingFile, .invalidFile, .storageFailure,
    ]
    #expect(Set(rejections.compactMap(\.rejection)).count == rejections.count)
    #expect(rejections.allSatisfy { ($0 == .storageFailure) == ($0.errorCategory == .storage) })
    #expect(RSSFileStoreError.downloadNotFound(1).rejection == nil)
  }

  @Test func unknownSizeIsCappedAtOneGiBWithoutAllocatingThePayload() async throws {
    let accepted = try await Self.makeFixture(expectedBytes: nil)
    defer { try? FileManager.default.removeItem(at: accepted.root) }
    let row = try await accepted.store.claimOrCreateAsync(episodeId: accepted.episodeID)
    _ = try await accepted.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let withinCap = try Self.makeSparseFile(size: RSSFileStore.sizeCapBytes)
    _ = try accepted.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: withinCap,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))

    let rejected = try await Self.makeFixture(expectedBytes: nil)
    defer { try? FileManager.default.removeItem(at: rejected.root) }
    let rejectedRow = try await rejected.store.claimOrCreateAsync(episodeId: rejected.episodeID)
    _ = try await rejected.store.transitionAsync(downloadId: rejectedRow.id!, to: .downloading)
    let overCap = try Self.makeSparseFile(size: RSSFileStore.sizeCapBytes + 1)
    #expect(throws: RSSFileStoreError.sizeLimitExceeded) {
      try rejected.files.completeTransfer(
        downloadId: rejectedRow.id!, temporaryFileURL: overCap,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))
    }
  }

  @Test func extremeAndNonpositiveExpectedSizesUseOverflowSafeCapSemantics() async throws {
    #expect(RSSFileStore.admissionBytes(expectedBytes: Int64.max) == Int64.max)
    #expect(
      RSSFileStore.admissionBytes(expectedBytes: 0)
        == RSSFileStore.sizeCapBytes + RSSFileStore.unknownSizeReserveBytes)
    #expect(
      RSSFileStore.admissionBytes(expectedBytes: -1)
        == RSSFileStore.sizeCapBytes + RSSFileStore.unknownSizeReserveBytes)

    let nonpositive = try await Self.makeFixture(expectedBytes: 0)
    defer { try? FileManager.default.removeItem(at: nonpositive.root) }
    let row = try await nonpositive.store.claimOrCreateAsync(episodeId: nonpositive.episodeID)
    _ = try await nonpositive.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let atCap = try Self.makeSparseFile(size: RSSFileStore.sizeCapBytes)
    _ = try nonpositive.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: atCap,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))

    // An absurd declared length is just more stale metadata: it neither rejects a small file nor
    // admits an oversized one.
    let extreme = try await Self.makeFixture(expectedBytes: Int64.max)
    defer { try? FileManager.default.removeItem(at: extreme.root) }
    let extremeRow = try await extreme.store.claimOrCreateAsync(episodeId: extreme.episodeID)
    _ = try await extreme.store.transitionAsync(downloadId: extremeRow.id!, to: .downloading)
    let tiny = try Self.makeSparseFile(size: 1)
    #expect(
      try extreme.files.completeTransfer(
        downloadId: extremeRow.id!, temporaryFileURL: tiny,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg")
      ).actualBytes == 1)
  }

  @Test func maliciousPersistedPathIsRejectedWithoutTouchingOutsideSentinel() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 4)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let maliciousPath = "RSS/1/../../rss-outside-sentinel-\(UUID().uuidString)"
    let sentinel = fixture.root.deletingLastPathComponent()
      .appendingPathComponent(maliciousPath.split(separator: "/").last.map(String.init)!)
    try Data([0xA5, 0x5A]).write(to: sentinel)
    try fixture.database.write { db in
      try db.execute(
        sql: "UPDATE rssDownload SET relativePath = ? WHERE id = ?",
        arguments: [maliciousPath, row.id!])
    }
    defer { try? FileManager.default.removeItem(at: sentinel) }

    #expect(throws: RSSFileStoreError.invalidRelativePath) {
      try fixture.files.transferDestinationURL(forRelativePath: maliciousPath)
    }
    let temporary = try Self.makeSparseFile(size: 4)
    #expect(throws: RSSFileStoreError.invalidRelativePath) {
      try fixture.files.completeTransfer(
        downloadId: row.id!, temporaryFileURL: temporary,
        response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))
    }
    #expect(throws: RSSFileStoreError.invalidRelativePath) {
      try fixture.files.delete(downloadId: row.id!)
    }
    #expect(try Data(contentsOf: sentinel) == Data([0xA5, 0x5A]))
  }

  @Test func missingCompletedFileHasNoLocalURLAndProtectionIsApplied() async throws {
    let fixture = try await Self.makeFixture(expectedBytes: 4)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let row = try await fixture.store.claimOrCreateAsync(episodeId: fixture.episodeID)
    _ = try await fixture.store.transitionAsync(downloadId: row.id!, to: .downloading)
    let temporary = try Self.makeSparseFile(size: 4)
    _ = try fixture.files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg"))
    #expect(fixture.attributes.downloadsRootCalls.contains(fixture.root))
    #expect(fixture.attributes.fileCalls.isEmpty == false)
    #expect(try fixture.files.validatedLocalURL(episodeId: fixture.episodeID) != nil)
    let local = try #require(try fixture.store.fetch(episodeId: fixture.episodeID))
    try FileManager.default.removeItem(at: fixture.files.absoluteURL(forRelativePath: local.relativePath))
    #expect(try fixture.files.validatedLocalURL(episodeId: fixture.episodeID) == nil)
  }

  private struct Fixture {
    let root: URL
    let database: AppDatabase
    let store: RSSDownloadStore
    let files: RSSFileStore
    let attributes: RecordingFileAttributes
    let episodeID: Int64
  }

  private static func makeFixture(
    expectedBytes: Int64?, attributes: RecordingFileAttributes = RecordingFileAttributes()
  ) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.test/\(UUID().uuidString).xml")!, title: "Feed",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", enclosureURL: URL(string: "https://cdn.example.test/a.mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: expectedBytes)
      ])
    let episodeID = try #require(
      try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM rssEpisode LIMIT 1")
      })
    let store = try RSSDownloadStore(database: database)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let files = try RSSFileStore(rootURL: root, fileAttributes: attributes, downloadStore: store)
    return Fixture(
      root: root, database: database, store: store, files: files, attributes: attributes,
      episodeID: episodeID)
  }

  private static func makeSparseFile(size: Int64) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: UInt64(size - 1))
    try handle.write(contentsOf: Data([0]))
    try handle.close()
    return url
  }
}

// Kept: records protection calls and can fail them; InertFileAttributes records nothing.
private final class RecordingFileAttributes: FileAttributeApplying, @unchecked Sendable {
  private let lock = NSLock()
  private let protectionFails: Bool
  private(set) var fileCalls: [URL] = []
  private(set) var downloadsRootCalls: [URL] = []

  init(protectionFails: Bool = false) {
    self.protectionFails = protectionFails
  }

  func protectDirectory(at directoryURL: URL) throws {}
  func protectDatabaseArtifacts(at databaseURL: URL) throws {}
  func protectDownloadsRoot(at directoryURL: URL) throws {
    lock.lock()
    downloadsRootCalls.append(directoryURL)
    lock.unlock()
  }
  func protectDownloadedFile(at fileURL: URL) throws {
    lock.lock()
    fileCalls.append(fileURL)
    lock.unlock()
    if protectionFails {
      throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
  }
}
