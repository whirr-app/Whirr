import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct ReaderStateReadingTests {
  @Test("no EPUB advertised is distinct from an EPUB identity that was never fetched")
  func noEpubAdvertisedAndNeverFetchedAreDistinct() async throws {
    let fixture = try await Self.makeFixture(ebookFormat: nil, expanded: nil)
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .noEpubAdvertised)

    try await fixture.updateItem(ebookFormat: "epub", expanded: nil)
    #expect(try #require(await iterator.next()) == .ebookIdentityNotFetched)
  }

  @Test("an advertised EPUB without an expanded file identity is unavailable, including no size")
  func advertisedButUnavailable() async throws {
    let fixture = try await Self.makeFixture(ebookFormat: "epub", expanded: Date())
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .advertisedButUnavailable)
  }

  @Test("a cleared coverage marker does not retract an EPUB whose identity is already on the row")
  func clearedCoverageMarkerKeepsAFetchedIdentityReadable() async throws {
    // v52 clears `expandedMetadataFetchedAt` library-wide to backfill expected download sizes.
    // The ino is still there, so the reader must not go dark meanwhile.
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: nil)
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .availableNotDownloaded)
  }

  @Test("a leading-dot mixed-case EPUB format is readable")
  func leadingDotMixedCaseEpubFormatIsReadable() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: ".EPUB", ino: "ino-1", ext: ".EPUB", expanded: Date())
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .availableNotDownloaded)
  }

  @Test("an available EPUB with no download is not downloaded")
  func availableNotDownloaded() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .availableNotDownloaded)
  }

  @Test("an EPUB download reports downloading progress")
  func downloadingWithProgress() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    _ = try #require(await iterator.next())

    try await fixture.insertDownload(state: .downloading, receivedBytes: 25)
    #expect(
      try #require(await iterator.next())
        == .downloading(progress: 0.25))
  }

  @Test("a completed EPUB yields a resolved local file reference")
  func downloadedReadyCarriesResolvedLocalFileReference() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    let relativePath = "1/2/0-ino-1.epub"
    let fileURL = fixture.downloadRoot.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("epub".utf8).write(to: fileURL)
    try await fixture.insertDownload(
      state: .completed, receivedBytes: 4, expectedBytes: 4, relativePath: relativePath)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(
      try #require(await iterator.next())
        == .downloadedReady(fileURL: fileURL))
  }

  @Test("a queued EPUB download projects downloading, not available-not-downloaded")
  func queuedDownloadProjectsDownloading() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(state: .pending, receivedBytes: 25)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloading(progress: 0.25))
  }

  /// A held row must not project plain `downloading`: the bar cannot advance (on cellular, never)
  /// and nothing says why. The fraction rides along for screens that draw a bar. `queued` and
  /// `interrupted` are not holds, as both advance on their own.
  @Test(
    "a held EPUB download projects why it is held, not progress",
    arguments: [
      (DownloadState.pending, DownloadHoldReason.waitingForWiFi, ReaderDownloadHold.waitingForWiFi),
      (DownloadState.paused, nil, ReaderDownloadHold.paused),
      (DownloadState.pausedAuth, nil, ReaderDownloadHold.pausedAuth),
    ])
  func heldDownloadProjectsItsHold(
    rowState: DownloadState, holdReason: DownloadHoldReason?, expected: ReaderDownloadHold
  ) async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(
      state: rowState, receivedBytes: 40, holdReason: holdReason)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(
      try #require(await iterator.next()) == .downloadHeld(reason: expected, progress: 0.4))
  }

  @Test("an interrupted EPUB download still projects downloading - it retries on its own")
  func interruptedDownloadProjectsDownloading() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(state: .interrupted, receivedBytes: 40)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloading(progress: 0.4))
  }

  @Test("a post-sweep missing EPUB is demoted to downloaded-but-file-missing")
  func downloadedButFileMissing() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(
      state: .failed, receivedBytes: 0, errorCategory: .storage)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloadedButFileMissing)
  }

  /// A non-storage failure must not project `availableNotDownloaded`: that latches the reader on a
  /// 0% download bar, because the request it makes in response is suppressed by the failed row, so
  /// nothing writes to the database and this projection never emits again.
  @Test("a failed EPUB download is its own state, not available-not-downloaded")
  func failedDownloadIsDistinctFromNotDownloaded() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(
      state: .failed, receivedBytes: 0, errorCategory: .transport)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloadFailed)
  }

  /// A validation rejection is the app refusing what the server sent, not a transfer that broke.
  /// Retrying re-reads the same server-side metadata and reproduces the rejection, so the two
  /// cannot share a state: the reader's copy must not advise a retry that cannot work.
  @Test("a download rejected by validation is distinct from one that failed in transit")
  func validationRejectionIsDistinctFromTransportFailure() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertDownload(
      state: .failed, receivedBytes: 0, errorCategory: .validation)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloadRejected)
  }

  /// A finished book must not project a terminal `finished` state that hides its download state,
  /// or nothing could re-read it and the Contents tab would call it "Not Downloaded". Finished
  /// belongs to the progress projection (`observeItemPlaybackStatuses`); this one answers only
  /// "where is the file".
  @Test("a finished EPUB still projects its own download state so it can be re-read")
  func finishedKeepsDownloadState() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    let relativePath = "1/2/0-ino-1.epub"
    let fileURL = fixture.downloadRoot.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("epub".utf8).write(to: fileURL)
    try await fixture.insertDownload(
      state: .completed, receivedBytes: 4, expectedBytes: 4, relativePath: relativePath)
    try await fixture.insertProgress(ebookProgress: 1, isFinished: true)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .downloadedReady(fileURL: fileURL))
  }

  @Test("a finished EPUB with no local file is available to download again")
  func finishedWithoutDownloadIsAvailable() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertProgress(ebookProgress: 1, isFinished: true)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .availableNotDownloaded)
  }

  @Test("stored ebook progress is observable and re-emits on change, nil when absent")
  func ebookProgressObservable() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    var iterator = fixture.reading.observeEbookProgress(itemId: fixture.serverItemId)
      .makeAsyncIterator()

    #expect(try #require(await iterator.next()) == nil)

    try await fixture.insertProgress(ebookProgress: 0.42, isFinished: false)
    #expect(try #require(await iterator.next()) == 0.42)

    try await fixture.updateProgress(ebookProgress: 0.85, isFinished: false)
    #expect(try #require(await iterator.next()) == 0.85)
  }

  /// Progress is not an input here: `observeEbookProgress` is its own stream, and this projection
  /// answers only where the file is.
  @Test("the projection re-emits when the item and download inputs change")
  func reemitsOnEachInputChange() async throws {
    let fixture = try await Self.makeFixture()
    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()

    #expect(try #require(await iterator.next()) == .noEpubAdvertised)

    try await fixture.updateItem(ebookFormat: "epub", ino: "ino-1", ext: "epub", expanded: Date())
    #expect(try #require(await iterator.next()) == .availableNotDownloaded)

    try await fixture.insertDownload(state: .downloading, receivedBytes: 50)
    #expect(try #require(await iterator.next()) == .downloading(progress: 0.5))

    try await fixture.updateDownload(state: .downloading, receivedBytes: 75)
    #expect(try #require(await iterator.next()) == .downloading(progress: 0.75))
  }

  @Test("a bundled EPUB audiobook projects reader state independently of audio fields")
  func bundledEpubDoesNotReadAudioFields() async throws {
    let fixture = try await Self.makeFixture(
      ebookFormat: "epub", numAudioFiles: 2, ino: "ino-1", ext: "epub", expanded: Date())
    try await fixture.insertProgress(
      currentTime: 720, ebookProgress: 0.2, isFinished: false)

    var iterator = fixture.reading.observeReaderState(itemId: fixture.serverItemId).makeAsyncIterator()
    #expect(try #require(await iterator.next()) == .availableNotDownloaded)

    try await fixture.insertDownload(state: .downloading, receivedBytes: 20)
    #expect(try #require(await iterator.next()) == .downloading(progress: 0.2))
  }

  private struct Fixture: Sendable {
    let database: AppDatabase
    let reading: DefaultReaderStateReading
    let accountId: Int64
    let itemId: Int64
    let serverItemId: String
    let downloadRoot: URL

    func updateItem(
      ebookFormat: String?,
      ino: String? = nil,
      ext: String? = nil,
      expanded: Date?
    ) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: """
            UPDATE item
            SET ebookFormat = ?, ebookFileIno = ?, ebookFileExt = ?, expandedMetadataFetchedAt = ?
            WHERE id = ?
            """,
          arguments: [ebookFormat, ino, ext, expanded, itemId])
      }
    }

    func insertDownload(
      state: DownloadState,
      receivedBytes: Int64,
      expectedBytes: Int64 = 100,
      relativePath: String = "1/2/0-ino-1.epub",
      errorCategory: DownloadErrorCategory? = nil,
      holdReason: DownloadHoldReason? = nil
    ) async throws {
      try await database.writeAsync { db in
        var row = DownloadRecord(
          accountId: accountId,
          itemId: itemId,
          serverFileIno: "ino-1",
          orderIndex: 0,
          destinationRelativePath: relativePath,
          expectedBytes: expectedBytes,
          expectedMimeType: "application/epub+zip",
          fileDurationSeconds: 0,
          receivedBytes: receivedBytes,
          state: state,
          holdReason: holdReason,
          errorCategory: errorCategory,
          mediaKind: .ebook)
        try row.insert(db)
      }
    }

    func updateDownload(state: DownloadState, receivedBytes: Int64) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: "UPDATE download SET state = ?, receivedBytes = ? WHERE itemId = ?",
          arguments: [state.rawValue, receivedBytes, itemId])
      }
    }

    func insertProgress(
      currentTime: Double = 0,
      ebookProgress: Double?,
      isFinished: Bool
    ) async throws {
      try await database.writeAsync { db in
        var row = MediaProgressRecord(
          accountId: accountId,
          itemId: itemId,
          currentTime: currentTime,
          isFinished: isFinished,
          localSequence: 1,
          origin: .local,
          originKey: "client",
          ebookProgress: ebookProgress)
        try row.insert(db)
      }
    }

    func updateProgress(ebookProgress: Double?, isFinished: Bool) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: "UPDATE mediaProgress SET ebookProgress = ?, isFinished = ? WHERE itemId = ?",
          arguments: [ebookProgress, isFinished, itemId])
      }
    }
  }

  private static func makeFixture(
    ebookFormat: String? = nil,
    numAudioFiles: Int? = nil,
    ino: String? = nil,
    ext: String? = nil,
    expanded: Date? = nil
  ) async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let root = URL(fileURLWithPath: "/tmp/reader-state-reading")
    let (accountId, _, itemId) = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: "item-1",
        mediaKind: "book",
        title: "Book",
        sortTitle: "book",
        numAudioFiles: numAudioFiles,
        ebookFormat: ebookFormat,
        ebookFileIno: ino,
        ebookFileExt: ext,
        expandedMetadataFetchedAt: expanded)
      try item.insert(db)
      return (account.id!, library.id!, item.id!)
    }
    return Fixture(
      database: database,
      reading: DefaultReaderStateReading(database: database, downloadRootURL: root),
      accountId: accountId,
      itemId: itemId,
      serverItemId: "item-1",
      downloadRoot: root)
  }
}
