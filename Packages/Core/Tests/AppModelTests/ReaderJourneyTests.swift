import Foundation
import GRDB
import Persistence
import ReaderCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Deterministic reader journeys. The only renderer in this package is the Foundation-only
/// FakeEPUBRendering; publication-server behaviour, real EPUB parsing, and DRM detection are out
/// of scope.
@MainActor
@Suite("Reader journeys", .timeLimit(.minutes(1)))
struct ReaderJourneyTests {

  @Test("paginated discovery, detail, download/open, debounced PATCH, close flush, and exact relaunch resume")
  func discoverDetailReadDownloadPositionsPatchCloseAndRelaunchResumes() async throws {
    let env = try await ReaderJourneyEnvironment()
    let library = DefaultLibraryReading(database: env.database)
    let browse = LibraryBrowseModel(library: library, sync: env.engine, defaults: FakeBrowseFilterDefaults())

    env.enqueuePaginatedLibrary()
    await env.engine.refresh()
    // The journey item is pre-seeded in the database, so "contains env.itemID" is already true
    // on the initial emission, so wait for the full paginated result before asserting on it.
    await waitUntil {
      browse.state.loadedItems.map(\.serverItemId) == ["other-book", env.itemID]
    }
    #expect(browse.state.loadedItems.map(\.serverItemId) == ["other-book", env.itemID])

    let detail = ItemDetailModel(
      itemId: env.itemID, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      readerReading: DefaultReaderStateReading(database: env.database, downloadRootURL: env.downloadRoot))
    await waitUntil {
      if case .loaded = detail.state { return true }
      return false
    }
    #expect(detail.readAffordance == .none, "expanded EPUB identity is fetched on detail")

    let extras = ItemDetailExtrasService(database: env.database, client: env.client)
    env.enqueueExpandedDetail()
    let extrasModel = ItemDetailExtrasModel(itemId: env.itemID, access: extras)
    await waitUntil {
      if case .loaded = extrasModel.state { return true }
      return false
    }
    await waitUntil { detail.readAffordance == ReadAffordanceState.read }
    #expect(detail.readAffordance == ReadAffordanceState.read)
    env.enqueueExpandedDetail()

    let download = env.makeDownloadCoordinator()
    let renderer = FakeEPUBRendering()
    let clock = ManualReaderClock()
    let progress = DatabaseReaderProgressAccess(
      database: env.database, accountID: env.accountID, itemRowID: env.itemRowID,
      serverItemID: env.itemID)
    let reader = ReaderModel(
      itemID: env.itemID, category: .ebook,
      stateReading: DefaultReaderStateReading(database: env.database, downloadRootURL: env.downloadRoot),
      progress: progress,
      preferencesStore: ReaderPreferencesStore(database: env.database, accountId: env.accountID),
      downloadIntents: download,
      renderer: renderer,
      appLifecycle: FakeAppLifecycle(),
      clock: clock)

    let openTask = Task { await reader.open() }
    await waitUntil {
      env.background.calls.contains {
        if case .enqueue = $0 { return true }
        return false
      }
    }
    let row = try #require(try env.downloadStore.fetchDownloads(itemId: env.itemRowID).first)
    let temp = try env.tempFile(byteCount: Int(row.expectedBytes))
    env.background.pushEvent(
      .finished(
        identity: .abs(rowID: try #require(row.id)), temporaryFileURL: temp,
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: row.expectedBytes)))
    await openTask.value
    #expect(reader.state == .reading)

    let first = ReadingPosition(
      href: "Text/chapter.xhtml", progression: 0.42, totalProgression: 0.42,
      position: 7, cfi: "epubcfi(/6/4!/4/2/8:0)")
    renderer.emit(first)
    await waitUntil { reader.currentPosition == first && clock.pendingSleepCount > 0 }
    clock.advance(by: ReadingSessionTracker.syncInterval)
    await waitUntil { (try? env.queuedEbookOperations())?.count == 1 }

    let latest = ReadingPosition(
      href: "Text/chapter.xhtml", progression: 0.77, totalProgression: 0.77,
      position: 12, cfi: "epubcfi(/6/4!/4/2/13:0)")
    renderer.emit(latest)
    await waitUntil { reader.currentPosition == latest }
    await reader.close()
    #expect(try env.queuedEbookOperations().count == 1, "close coalesces into the same position operation")

    let operation = try #require(try env.queuedEbookOperations().first)
    #expect(operation.payloadEbookProgress == latest.ebookProgress)
    #expect(operation.payloadEbookLocation == latest.ebookLocation)
    env.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await env.drainer.drainOutbox(now: env.now, randomUnit: { 1 })
    let request = try #require(env.http.requests.last { $0.method == .patch })
    let body = try #require(request.body).jsonObject()
    #expect(body["ebookProgress"] as? Double == 0.77)
    #expect(body["ebookLocation"] as? String == latest.ebookLocation)
    #expect(body["currentTime"] == nil)
    #expect(body["id"] == nil, "API-CONVENTIONS rule 11")
    #expect(try env.queuedEbookOperations().isEmpty)

    let relaunchedRenderer = FakeEPUBRendering()
    let relaunched = ReaderModel(
      itemID: env.itemID, category: .ebook,
      stateReading: DefaultReaderStateReading(database: env.database, downloadRootURL: env.downloadRoot),
      progress: progress,
      preferencesStore: ReaderPreferencesStore(database: env.database, accountId: env.accountID),
      downloadIntents: download,
      renderer: relaunchedRenderer,
      appLifecycle: FakeAppLifecycle(),
      clock: ManualReaderClock())
    await relaunched.open()
    #expect(relaunchedRenderer.goToPositions == [latest], "resume is the exact local locator, not a rounded fraction")
    await relaunched.close()
  }

  @Test("newer other-device ebook progress arrives on pull and moves the resume target")
  func serverProgressFromAnotherDeviceMovesResumeTarget() async throws {
    let env = try await ReaderJourneyEnvironment()
    env.enqueuePaginatedLibrary(progress: 0.20, lastUpdate: 1_700_000_000_000)
    await env.engine.refresh()
    env.enqueuePaginatedLibrary(progress: 0.80, lastUpdate: 1_700_000_001_000)
    await env.engine.refresh()
    let target = try #require(
      try MediaProgressDAO(database: env.database).fetchCurrent(
        accountId: env.accountID, identity: .item(itemId: env.itemRowID)))
    #expect(target.ebookProgress == 0.80)
    #expect(target.readingPositionJSON == nil, "a server fraction is not fabricated into a locator")
  }

  @Test("offline open/read/close creates one coalesced operation and reconnect drains it once")
  func offlineJourneyCoalescesAndDrainsOnce() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let renderer = FakeEPUBRendering()
    let clock = ManualReaderClock()
    let reader = env.makeReader(renderer: renderer, clock: clock)
    await reader.open()
    let position = ReadingPosition(href: "Text/offline.xhtml", progression: 0.61, totalProgression: 0.61)
    renderer.emit(position)
    await waitUntil { reader.currentPosition == position }
    await reader.close()
    #expect(try env.queuedEbookOperations().count == 1)

    let offlineDrainer = env.makeDrainer(http: FakeHTTPClient(failure: FakeHTTPClientError(message: "airplane")))
    await offlineDrainer.drainOutbox(now: env.now, randomUnit: { 1 })
    #expect(try env.queuedEbookOperations().count == 1, "offline retains exactly one operation")
    let reconnectHTTP = FakeHTTPClient(responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await env.makeDrainer(http: reconnectHTTP).drainOutbox(now: env.now.addingTimeInterval(2), randomUnit: { 1 })
    #expect(reconnectHTTP.requests.filter { $0.method == .patch }.count == 1)
    #expect(try env.queuedEbookOperations().isEmpty)
  }

  @Test("ebook finish round-trips as its own flag operation and never writes currentTime")
  func finishFlowUsesDedicatedEbookSafeOperation() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let renderer = FakeEPUBRendering()
    let reader = env.makeReader(renderer: renderer, clock: ManualReaderClock())
    await reader.open()
    renderer.emit(ReadingPosition(href: "Text/end.xhtml", progression: 1, totalProgression: 1))
    await waitUntil { reader.isFinishOfferVisible }
    #expect(reader.isFinishOfferVisible)
    await reader.markFinished()
    let finish = try #require(
      try env.queuedEbookOperations().first { $0.operationKind == OutboxOperationKind.sharedFinish.rawValue })
    #expect(finish.payloadCurrentTime == nil)
    env.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    await env.drainer.drainOutbox(now: env.now, randomUnit: { 1 })
    let request = try #require(env.http.requests.last { $0.method == .patch })
    let body = try #require(request.body).jsonObject()
    #expect(body as NSDictionary == ["isFinished": true])
    #expect(body["currentTime"] == nil)
    await reader.close()
  }

  @Test("bundled EPUB audiobook keeps audio and ebook positions independent through listen plus read")
  func bundledAudiobookPositionsNeverCrossContaminate() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true, bundledAudiobook: true)
    let dao = MediaProgressDAO(database: env.database)
    _ = try await dao.writeLocalAsync(
      accountId: env.accountID, identity: .item(itemId: env.itemRowID),
      field: .audio(currentTime: 91, isFinished: false), originKey: "journey")
    let renderer = FakeEPUBRendering()
    let reader = env.makeReader(renderer: renderer, category: .audiobook, clock: ManualReaderClock())
    await reader.open()
    let position = ReadingPosition(href: "Text/bundled.xhtml", progression: 0.5, totalProgression: 0.5)
    renderer.emit(position)
    await waitUntil { reader.currentPosition == position }
    await reader.close()
    let stored = try #require(try dao.fetchCurrent(accountId: env.accountID, identity: .item(itemId: env.itemRowID)))
    #expect(stored.currentTime == 91 && stored.ebookProgress == 0.5, "audio and ebook positions are independent")
  }

  @Test("reading a bundled EPUB audiobook to the end offers no finish and leaves isFinished untouched")
  func bundledAudiobookEndLeavesFinishedUntouched() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true, bundledAudiobook: true)
    let renderer = FakeEPUBRendering()
    _ = try await MediaProgressDAO(database: env.database).writeLocalAsync(
      accountId: env.accountID, identity: .item(itemId: env.itemRowID),
      field: .audio(currentTime: 0, isFinished: false), originKey: "journey")
    let reader = env.makeReader(renderer: renderer, category: .audiobook, clock: ManualReaderClock())
    await reader.open()
    renderer.emit(ReadingPosition(href: "Text/end.xhtml", progression: 1, totalProgression: 1))
    await waitUntil { reader.currentPosition?.totalProgression == 1 }
    #expect(reader.isFinishOfferVisible == false)
    let progress = try MediaProgressDAO(database: env.database).fetchCurrent(
      accountId: env.accountID, identity: .item(itemId: env.itemRowID))
    #expect(progress?.isFinished == false)
    await reader.close()
  }
}

@MainActor
@Suite("Reader crash matrix", .timeLimit(.minutes(1)))
struct ReaderCrashMatrixTests {

  @Test("position write/outbox enqueue cut reopens twice without duplicate operations or regression")
  func positionWriteAndEnqueueRecoveryTwice() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let access = DatabaseReaderProgressAccess(
      database: env.database, accountID: env.accountID, itemRowID: env.itemRowID,
      serverItemID: env.itemID)
    for fraction in [0.25, 0.50] {
      try await access.write(
        position: ReadingPosition(href: "Text/recovery.xhtml", progression: fraction, totalProgression: fraction),
        itemID: env.itemID)
      let reopened = try OutboxStore(database: env.database)
      let rows = try reopened.fetchQueued(accountId: env.accountID, entityKey: env.itemID)
      #expect(rows.count == 1)
      #expect(rows.first?.payloadEbookProgress == fraction)
    }
    #expect(try env.queuedEbookOperations().count == 1)
    let restored = try #require(
      try MediaProgressDAO(database: env.database).fetchCurrent(
        accountId: env.accountID, identity: .item(itemId: env.itemRowID)))
    #expect(restored.ebookProgress == 0.50)
  }

  @Test("drain send/ack cut reopens twice and acknowledges once")
  func drainSendAcknowledgeRecoveryTwice() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let access = DatabaseReaderProgressAccess(
      database: env.database, accountID: env.accountID, itemRowID: env.itemRowID,
      serverItemID: env.itemID)
    try await access.write(
      position: ReadingPosition(href: "Text/ack.xhtml", progression: 0.33, totalProgression: 0.33),
      itemID: env.itemID)
    let store = try OutboxStore(database: env.database)
    let operation = try #require(try env.queuedEbookOperations().first)
    _ = try store.transition(operationId: try #require(operation.id), to: .sending)
    for _ in 0..<2 {
      let reopened = try OutboxStore(database: env.database)
      let queued = try reopened.fetchQueued(accountId: env.accountID, entityKey: env.itemID)
      if queued.isEmpty == false {
        #expect(queued.count == 1)
        env.http.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        await env.makeDrainer(http: env.http).drainOutbox(now: env.now, randomUnit: { 1 })
      }
      #expect(try env.queuedEbookOperations().isEmpty)
    }
    #expect(env.http.requests.filter { $0.method == .patch }.count == 1)
  }

  @Test("download temp-move/commit cut reopens twice without a position regression or orphan")
  func downloadTempMoveCommitRecoveryTwice() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let row = try env.downloadStore.enqueue(
      accountId: env.accountID, itemId: env.itemRowID, serverFileIno: "crash-epub", orderIndex: 1,
      destinationRelativePath: "crash.epub", expectedBytes: 4,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    let id = try #require(row.id)
    _ = try env.downloadStore.transition(downloadId: id, to: .downloading)
    let moved = try env.tempFile(byteCount: 4)
    let destination = env.downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: moved, to: destination)
    for _ in 0..<2 {
      _ = try DownloadStore(database: env.database)
      if try env.downloadStore.fetch(downloadId: id)?.state != .completed {
        _ = try env.downloadStore.transition(downloadId: id, to: .pending)
        _ = try env.downloadStore.transition(downloadId: id, to: .downloading)
        let retry = try env.tempFile(byteCount: 4)
        _ = try env.downloadFileStore.completeTransfer(
          downloadId: id, temporaryFileURL: retry,
          response: DownloadTransferResponse(httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: 4))
        #expect(FileManager.default.fileExists(atPath: retry.path) == false)
      }
      #expect(try env.downloadStore.fetch(downloadId: id)?.state == .completed)
      #expect(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  @Test("preferences write cut reopens twice without duplicate rows")
  func preferencesWriteRecoveryTwice() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let store = ReaderPreferencesStore(database: env.database, accountId: env.accountID)
    let json =
      "{\"theme\":\"sepia\",\"fontFamily\":\"publisherDefault\",\"fontSizeStep\":1,\"lineSpacingStep\":0,\"marginsStep\":0,\"readingMode\":\"paginated\",\"reflowable\":true}"
    for _ in 0..<2 {
      try await store.writePreferencesJSON(json)
      let reopened = ReaderPreferencesStore(database: env.database, accountId: env.accountID)
      #expect(try await reopened.fetchPreferencesJSON() == json)
    }
    #expect(try env.database.read { db in try ReaderPreferencesRecord.fetchCount(db) } == 1)
  }

  @Test("mid-open relaunch repeats twice without position regression or orphaned reader file")
  func midOpenRelaunchRecoveryTwice() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let position = ReadingPosition(href: "Text/mid-open.xhtml", progression: 0.66, totalProgression: 0.66)
    var reader = env.makeReader(renderer: FakeEPUBRendering(), clock: ManualReaderClock())
    await reader.open()
    let renderer = FakeEPUBRendering()
    reader = env.makeReader(renderer: renderer, clock: ManualReaderClock())
    await reader.open()
    renderer.emit(position)
    await waitUntil { reader.currentPosition == position }
    await reader.background()
    await reader.close()
    for _ in 0..<2 {
      let reopenedRenderer = FakeEPUBRendering()
      let reopened = env.makeReader(renderer: reopenedRenderer, clock: ManualReaderClock())
      await reopened.open()
      #expect(reopenedRenderer.goToPositions == [position])
      await reopened.close()
    }
    #expect(
      FileManager.default.fileExists(atPath: env.downloadFileStore.absoluteURL(forRelativePath: "reader.epub").path))
  }
}

@Suite("Reader privacy canaries")
struct ReaderPrivacyCanaryTests {
  private static let bookText = "CANARY-LOCATOR-TEXT-MUST-NEVER-ESCAPE"
  private static let title = "The Canary Reader Title"
  private static let accessToken = "CANARY-READER-ACCESS-TOKEN"
  private static let refreshToken = "CANARY-READER-REFRESH-TOKEN"

  @Test("database, diagnostics, ebook outbox payloads, and logs redact locator text, title paths, and tokens")
  func allReaderPrivacySurfacesStayRedacted() async throws {
    let env = try await ReaderJourneyEnvironment(downloaded: true)
    let access = DatabaseReaderProgressAccess(
      database: env.database, accountID: env.accountID, itemRowID: env.itemRowID,
      serverItemID: env.itemID)
    let position = ReadingPosition(
      href: "Text/chapter.xhtml", progression: 0.42, totalProgression: 0.42,
      cfi: "epubcfi(/6/4!/4/2/8:0)")
    try await access.write(position: position, itemID: env.itemID)

    let diagnostics = DiagnosticsStore(
      database: env.database, now: { Date(timeIntervalSince1970: 1_700_000_200) })
    await diagnostics.record(
      DiagnosticsEvent(
        category: .ebookProgress, statusClass: .success, durationMilliseconds: 3,
        endpointTemplate: EndpointTemplate("/api/me/progress/:id")),
      accountId: env.accountID)
    let recording = FakeDiagnosticsRecording()
    await recording.record(
      DiagnosticsEvent(
        category: .ebookProgress, statusClass: .success, durationMilliseconds: 3,
        endpointTemplate: EndpointTemplate("/api/me/progress/:id")),
      accountId: env.accountID)

    let request = HTTPRequest(
      method: .patch,
      url: try #require(
        URL(string: "https://reader.example.test/api/me/progress/\(Self.title)?token=\(Self.accessToken)")),
      headers: ["Authorization": "Bearer \(Self.accessToken)"],
      body: Data(Self.bookText.utf8), routeTemplate: "/api/me/progress/:id")
    let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.bookText.utf8))
    let logger = RedactingHTTPLogger()
    await logger.record(request: request, response: response, duration: 0.1, requestID: "reader-canary")
    await logger.recordFailure(
      request: request, duration: 0.2,
      requestID: "reader-canary-failure")

    let persistedDatabase = try env.database.read { db in
      let progress = try MediaProgressRecord.fetchAll(db)
      let outbox = try OutboxOperationRecord.fetchAll(db)
      let downloads = try DownloadRecord.fetchAll(db)
      let preferences = try ReaderPreferencesRecord.fetchAll(db)
      let diagnostics = try DiagnosticsEventRecord.fetchAll(db)
      return String(reflecting: (progress, outbox, downloads, preferences, diagnostics))
    }
    let outboxPayloads = try env.queuedEbookOperations().map { String(reflecting: $0) }.joined()
    let diagnosticEvents =
      String(reflecting: try diagnostics.fetchAll(accountId: env.accountID))
      + String(reflecting: recording.recorded)
    let logs = (await logger.formattedEntries()).joined(separator: "\n")
    let downloadPaths = try env.database.read { db in
      try DownloadRecord.fetchAll(db).map { row in
        row.destinationRelativePath + " "
          + env.downloadFileStore.absoluteURL(
            forRelativePath: row.destinationRelativePath
          ).path
      }.joined(separator: "\n")
    }

    for surface in [persistedDatabase, outboxPayloads, diagnosticEvents, logs] {
      #expect(surface.contains(Self.bookText) == false, "locator text leaked: \(surface)")
      #expect(surface.contains(Self.accessToken) == false, "access token leaked: \(surface)")
      #expect(surface.contains(Self.refreshToken) == false, "refresh token leaked: \(surface)")
    }
    #expect(downloadPaths.contains(Self.title) == false, "a file path contains the book title")
    #expect(downloadPaths.contains(Self.accessToken) == false)
    #expect(downloadPaths.contains(Self.refreshToken) == false)
  }
}

// MARK: - Production composition used by the journeys

private final class ReaderJourneyEnvironment: @unchecked Sendable {
  static let itemID = "reader-journey-book"
  let itemID: String
  let database: AppDatabase
  let server: ABSServerConfig
  let account: TokenAccount
  let tokenStore: InMemoryTokenStore
  let client: ABSClient
  let http: FakeHTTPClient
  let accountID: Int64
  let itemRowID: Int64
  let databaseRoot: URL
  let downloadRoot: URL
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let background: FakeBackgroundTransferring
  let engine: SyncEngine
  let now = Date(timeIntervalSince1970: 1_700_000_100)

  init(downloaded: Bool = false, bundledAudiobook: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ReaderJourney-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    databaseRoot = root
    itemID = Self.itemID
    downloadRoot = root.appendingPathComponent("Downloads", isDirectory: true)
    server = try ABSServerConfig(url: URL(string: "https://reader-journey.example.test")!)
    let clientUUID = "reader-client"
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "reader-user")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "reader-access", refreshToken: "reader-refresh"), for: account)
    http = FakeHTTPClient()
    client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    database = try AppDatabase.inMemory()
    self.tokenStore = tokenStore
    let saved = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "reader-user", serverVersion: "2.35.1"))
    accountID = try #require(saved.id)
    let localDatabase = database
    let localAccountID = accountID
    let libraryID = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountID, serverLibraryId: "reader-library", mediaType: "book", name: "Books")
      try library.insert(db)
      return library.id!
    }
    let item = ItemRecord(
      accountId: localAccountID, libraryId: libraryID, serverItemId: Self.itemID,
      mediaKind: bundledAudiobook ? "book" : "book", title: "Reader Journey Book",
      sortTitle: "reader journey book", numAudioFiles: bundledAudiobook ? 1 : 0)
    itemRowID = try #require(try ItemDAO(database: localDatabase).upsert(item).id)
    if bundledAudiobook || downloaded {
      let localItemRowID = itemRowID
      let timestamp = now
      try await localDatabase.writeAsync { db in
        try ItemRecord.filter(key: localItemRowID).updateAll(
          db, Column("ebookFormat").set(to: "epub"), Column("ebookFileIno").set(to: "reader-epub-ino"),
          Column("ebookFileExt").set(to: "epub"), Column("expandedMetadataFetchedAt").set(to: timestamp))
      }
    }
    downloadStore = try DownloadStore(database: database)
    background = FakeBackgroundTransferring()
    let fileStore = try DownloadFileStore(
      rootURL: downloadRoot, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    downloadFileStore = fileStore
    engine = SyncEngine.make(
      client: client, database: database, diagnostics: FakeDiagnosticsRecording(), appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: now), randomSource: { 1 }, pageLimit: 1)
    if downloaded {
      let row = try downloadStore.enqueue(
        accountId: accountID, itemId: itemRowID, serverFileIno: "reader-epub-ino", orderIndex: 0,
        destinationRelativePath: "reader.epub", expectedBytes: 4, expectedMimeType: "application/epub+zip",
        fileDurationSeconds: 0, mediaKind: .ebook)
      _ = try downloadStore.transition(downloadId: try #require(row.id), to: .downloading)
      let temporary = try tempFile(byteCount: Int(row.expectedBytes))
      _ = try downloadFileStore.completeTransfer(
        downloadId: try #require(row.id), temporaryFileURL: temporary,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: row.expectedBytes))
    }
  }

  deinit { try? FileManager.default.removeItem(at: databaseRoot) }

  func enqueuePaginatedLibrary(progress: Double? = nil, lastUpdate: Double? = nil) {
    http.enqueue(Self.json(["libraries": [["id": "reader-library", "name": "Books", "mediaType": "book"]]]))
    let progressObject: [String: Any] = [
      "libraryItemId": Self.itemID, "ebookProgress": progress as Any, "isFinished": false,
      "lastUpdate": lastUpdate as Any,
    ]
    http.enqueue(Self.json(["mediaProgresses": progress == nil ? [] : [progressObject]]))
    http.enqueue(
      Self.json([
        "results": [
          [
            "id": "other-book", "libraryId": "reader-library", "mediaType": "book",
            "media": ["metadata": ["title": "Other Book"], "ebookFormat": "epub"],
          ]
        ], "total": 2, "limit": 1, "page": 0,
      ]))
    http.enqueue(
      Self.json([
        "results": [
          [
            "id": Self.itemID, "libraryId": "reader-library", "mediaType": "book",
            "media": ["metadata": ["title": "Reader Journey Book"], "ebookFormat": "epub"],
          ]
        ], "total": 2, "limit": 1, "page": 1,
      ]))
  }

  func enqueueExpandedDetail() {
    http.enqueue(
      Self.json([
        "id": Self.itemID, "libraryId": "reader-library", "mediaType": "book",
        "media": [
          "metadata": ["title": "Reader Journey Book"], "audioFiles": [[String: Any]](), "tracks": [[String: Any]](),
          "chapters": [[String: Any]](),
          "ebookFile": ["ino": "reader-epub-ino", "metadata": ["filename": "reader.epub", "ext": ".epub", "size": 4]],
        ],
      ]))
  }

  func makeDownloadCoordinator() -> DownloadCoordinator {
    DownloadCoordinator.make(
      client: client, database: database, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore,
      backgroundTransferring: background, downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions(),
      diagnostics: FakeDiagnosticsRecording(), freeSpaceReporting: FakeFreeSpaceReporting())
  }

  @MainActor
  func makeReader(renderer: FakeEPUBRendering, category: ItemMediaCategory = .ebook, clock: any ReadingSessionClock)
    -> ReaderModel
  {
    ReaderModel(
      itemID: Self.itemID, category: category,
      stateReading: DefaultReaderStateReading(database: database, downloadRootURL: downloadRoot),
      progress: DatabaseReaderProgressAccess(
        database: database, accountID: accountID, itemRowID: itemRowID, serverItemID: Self.itemID),
      preferencesStore: ReaderPreferencesStore(database: database, accountId: accountID),
      downloadIntents: makeDownloadCoordinator(), renderer: renderer, appLifecycle: FakeAppLifecycle(), clock: clock)
  }

  var drainer: OutboxDrainer { makeDrainer(http: http) }
  func makeDrainer(http: FakeHTTPClient) -> OutboxDrainer {
    OutboxDrainer(
      outboxStore: try! OutboxStore(database: database), database: database,
      absClient: ABSClient(server: server, httpClient: http, tokenStore: tokenStore), account: account,
      accountId: accountID)
  }

  func queuedEbookOperations() throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord.fetchAll(db).filter {
        $0.operationKind == OutboxOperationKind.ebookPosition.rawValue
          || $0.operationKind == OutboxOperationKind.sharedFinish.rawValue
      }
    }
  }
  func tempFile(byteCount: Int) throws -> URL {
    let url = databaseRoot.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 1, count: byteCount).write(to: url)
    return url
  }
  private static func json(_ object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

private actor DatabaseReaderProgressAccess: ReaderProgressAccessing {
  let dao: MediaProgressDAO
  let accountID: Int64
  let itemRowID: Int64
  let serverItemID: String
  init(database: AppDatabase, accountID: Int64, itemRowID: Int64, serverItemID: String) {
    dao = MediaProgressDAO(database: database)
    self.accountID = accountID
    self.itemRowID = itemRowID
    self.serverItemID = serverItemID
  }
  func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget? {
    guard let record = try await dao.fetchCurrentAsync(accountId: accountID, identity: .item(itemId: itemRowID)) else {
      return nil
    }
    if let json = record.readingPositionJSON,
      let position = try? JSONDecoder().decode(ReadingPosition.self, from: Data(json.utf8))
    {
      return .position(position)
    }
    return record.ebookProgress.map(ReaderRestoreTarget.totalProgression)
  }
  func write(position: ReadingPosition, itemID: String) async throws {
    let json = String(decoding: try JSONEncoder().encode(position), as: UTF8.self)
    _ = try await dao.writeEbookPositionAndEnqueueAsync(
      accountId: accountID, identity: .item(itemId: itemRowID), entityKey: serverItemID, readingPositionJSON: json,
      ebookProgress: position.ebookProgress, ebookLocation: position.ebookLocation, originKey: "reader-client")
  }
  func markEbookAsFinished(itemID: String) async throws {
    _ = try await dao.markEbookAsFinishedAndEnqueueAsync(
      accountId: accountID, identity: .item(itemId: itemRowID), entityKey: serverItemID, originKey: "reader-client")
  }
}

private final class ManualReaderClock: ReadingSessionClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: TimeInterval = 0
  private var sleepers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
  var pendingSleepCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepers.count
  }
  func now() -> TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func sleep(until deadline: TimeInterval) async {
    await withCheckedContinuation { continuation in
      lock.lock()
      if value >= deadline {
        lock.unlock()
        continuation.resume()
      } else {
        sleepers.append((deadline, continuation))
        lock.unlock()
      }
    }
  }
  func advance(by seconds: TimeInterval) {
    lock.lock()
    value += seconds
    let due = sleepers.filter { $0.0 <= value }
    sleepers.removeAll { $0.0 <= value }
    lock.unlock()
    for sleeper in due {
      sleeper.1.resume()
    }
  }
}

extension LibraryBrowseModel.State {
  fileprivate var loadedItems: [ItemSummary] {
    if case .loaded(let items) = self { return items }
    return []
  }
}

extension Data {
  fileprivate func jsonObject() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: self) as? [String: Any] ?? [:]
  }
}

extension HTTPRequest {
  fileprivate func jsonObject() throws -> [String: Any] { try (body ?? Data()).jsonObject() }
}
