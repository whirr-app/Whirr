import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

/// The single cross-consumer matrix. A bundled EPUB shares the item-level download table with its
/// audiobook sibling; per-format projections stay explicit, while item-level status and badges
/// fold the rows actually requested.
///
/// The supplement cells prove a PDF row, in every state, never changes what the item is downloaded
/// as, while storage still counts its bytes.
@Suite("Bundled-EPUB matrix")
struct DownloadMediaKindMatrixTests {

  @Test("the bundled-EPUB matrix folds all requested rows for item aggregate")
  func bundledEPUBMatrix_downloadStoreAggregateFoldsAllRequestedRows() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)

      #expect(
        try fixture.downloadStore.aggregate(itemId: fixture.itemID)
          == fixture.expectedItemAggregate,
        "item aggregate for \(cell.rawValue)")
      #expect(
        try fixture.downloadStore.aggregate(itemId: fixture.itemID, mediaKind: .audio)
          == fixture.expectedAggregate(for: .audio),
        "audio aggregate for \(cell.rawValue)")
      #expect(
        try fixture.downloadStore.aggregate(itemId: fixture.itemID, mediaKind: .ebook)
          == fixture.expectedAggregate(for: .ebook),
        "ebook aggregate for \(cell.rawValue)")
    }
  }

  @Test("the bundled-EPUB matrix folds all requested rows for item status")
  func bundledEPUBMatrix_downloadStoreItemStatusFoldsAllRequestedRows() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)

      #expect(
        try fixture.downloadStore.itemStatus(itemId: fixture.itemID)
          == fixture.expectedItemStatus,
        "item status for \(cell.rawValue)")
      #expect(
        try fixture.downloadStore.itemStatus(itemId: fixture.itemID, mediaKind: .audio)
          == fixture.expectedStatus(for: .audio),
        "audio status for \(cell.rawValue)")
      #expect(
        try fixture.downloadStore.itemStatus(itemId: fixture.itemID, mediaKind: .ebook)
          == fixture.expectedStatus(for: .ebook),
        "ebook status for \(cell.rawValue)")
    }
  }

  @Test("the bundled-EPUB matrix folds all requested rows for item presence")
  func bundledEPUBMatrix_downloadStoreItemPresenceFoldsAllRequestedRows() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)
      let presence = try fixture.database.read { db in
        (
          try DownloadStore.itemPresence(db),
          try DownloadStore.itemPresence(db, mediaKind: .audio),
          try DownloadStore.itemPresence(db, mediaKind: .ebook)
        )
      }

      #expect(
        presence.0[fixture.serverItemID, default: .none]
          == fixture.expectedItemPresence,
        "item presence for \(cell.rawValue)")
      #expect(
        presence.1[fixture.serverItemID, default: .none] == fixture.expectedPresence(for: .audio),
        "audio presence for \(cell.rawValue)")
      #expect(
        presence.2[fixture.serverItemID, default: .none] == fixture.expectedPresence(for: .ebook),
        "ebook presence for \(cell.rawValue)")
    }
  }

  @Test("Home includes an item when any media kind is complete")
  func bundledEPUBMatrix_defaultHomeReadingIncludesAnyCompletedKind() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)
      var iterator = DefaultHomeReading(database: fixture.database)
        .observeDownloaded(category: nil, limit: 10)
        .makeAsyncIterator()
      let result = try #require(await iterator.next())

      let expected = fixture.expectedHomeDownloaded ? [fixture.serverItemID] : []
      #expect(result.map(\.serverItemId) == expected, "Home rollup for \(cell.rawValue)")
    }
  }

  @Test("item filters require every requested media kind to be complete")
  func bundledEPUBMatrix_itemFilterPredicateRequiresEveryRequestedKind() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)
      let expected = fixture.expectedItemDownloaded ? [fixture.serverItemID] : []
      let itemPredicate = ItemFilterPredicate.itemDownloadedOnly(true)
      let libraryPredicate = ItemFilterPredicate.libraryEntryDownloadedOnly(true)

      #expect(
        try fixture.items(matching: itemPredicate) == expected,
        "item scope for \(cell.rawValue)")
      #expect(
        try fixture.items(matching: libraryPredicate) == expected,
        "library-entry scope for \(cell.rawValue)")
    }
  }

  @Test("the bundled-EPUB matrix keeps storage accounting medium-neutral")
  func bundledEPUBMatrix_storageAccountingCountsAudioAndEbookRows() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)
      let accounting = StorageAccounting(downloadStore: fixture.downloadStore)

      #expect(
        try accounting.itemTotals(itemId: fixture.itemID).totalBytes == fixture.expectedStorageBytes,
        "item storage for \(cell.rawValue)")
      #expect(
        try accounting.accountTotals().totalBytes == fixture.expectedStorageBytes,
        "account storage for \(cell.rawValue)")

      let downloadedItems = try fixture.database.read { db in
        try StorageAccounting.downloadedItems(db)
      }
      #expect(downloadedItems.count == 1)
      #expect(downloadedItems.first?.itemId == fixture.serverItemID)
      #expect(downloadedItems.first?.totalBytes == fixture.expectedStorageBytes)
    }
  }

  @Test("the bundled-EPUB matrix playback path prepares audio rows only")
  func bundledEPUBMatrix_playbackSessionCoordinatorUsesAudioRowsOnly() async throws {
    for cell in MatrixCell.allCases {
      let fixture = try await MatrixFixture(cell: cell)
      let coordinator = fixture.makePlaybackCoordinator()
      if fixture.expectedLocalPlayback {
        // No HTTP response is queued: local playback must not touch /play.
      } else {
        fixture.enqueuePlayResponse()
      }

      let prepared = try await coordinator.startSession(
        itemID: fixture.serverItemID, episodeID: nil)

      #expect(
        prepared.source == (fixture.expectedLocalPlayback ? .local : .streaming),
        "source for \(cell.rawValue)")
      #expect(
        prepared.tracks.allSatisfy { !["epub", "pdf"].contains($0.url.pathExtension.lowercased()) },
        "EPUB never becomes a prepared playback track for \(cell.rawValue)")
      if fixture.expectedLocalPlayback {
        #expect(prepared.tracks.count == 1, "audio-only track count for \(cell.rawValue)")
        #expect(prepared.tracks.first?.duration == 100)
      }
    }
  }

  @Test("ebook-scoped intents request pause resume and purge only the ebook row")
  func bundledEPUBMatrix_downloadIntentsScopeEbookActions() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await configureEbook(harness, ino: "ebook-ino", ext: ".epub")
    let audio = try harness.downloadStore.enqueue(
      accountId: harness.accountId,
      itemId: harness.itemRowId,
      serverFileIno: "audio-ino",
      orderIndex: 0,
      destinationRelativePath: "audio/audio-ino.mp3",
      expectedBytes: 20,
      expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let audioID = try #require(audio.id)
    _ = try harness.downloadStore.transition(downloadId: audioID, to: .downloading)
    _ = try harness.downloadStore.complete(downloadId: audioID, finalSizeBytes: 20)
    enqueueEbookDetail(harness, ino: "ebook-ino", ext: ".epub", size: 10)

    let intents: any DownloadIntents = harness.coordinator
    try await intents.requestEbookDownload(itemID: DownloadCoordinatorHarness.itemID)
    let ebookID = try #require(
      try harness.fetchDownloads(itemId: harness.itemRowId)
        .first(where: { $0.mediaKind == .ebook })?.id)
    #expect(try harness.downloadStore.fetch(downloadId: audioID)?.state == .completed)
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: ebookID))?.state == .downloading
      })

    try await intents.pauseEbookDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(try harness.downloadStore.fetch(downloadId: audioID)?.state == .completed)
    #expect(try harness.downloadStore.fetch(downloadId: ebookID)?.state == .paused)

    try await intents.resumeEbookDownload(itemID: DownloadCoordinatorHarness.itemID)
    #expect(
      await TestSupport.waitUntil {
        (try? harness.downloadStore.fetch(downloadId: ebookID))?.state == .downloading
      })
    #expect(try harness.downloadStore.fetch(downloadId: audioID)?.state == .completed)

    try await intents.purgeEbookDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .readerEbook)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).map(\.mediaKind) == [.audio])

    try await intents.purgeItemDownload(
      itemID: DownloadCoordinatorHarness.itemID, source: .itemDetail)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).isEmpty)
  }

  @Test("account removal deletes both media kinds and leaves no download file")
  func bundledEPUBMatrix_accountRemovalRemovesAudioAndEbookFiles() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountID = try await harness.seedSignedInAccount(database: database)
    let itemID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "lib-ebook", mediaType: "book", name: "Books")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountID,
        libraryId: library.id!,
        serverItemId: "account-removal-bundle",
        mediaKind: "book",
        title: "Bundle",
        sortTitle: "bundle",
        numAudioFiles: 1,
        ebookFormat: "epub")
      try item.insert(db)
      return item.id!
    }

    let audioPath = "\(accountID)/\(itemID)/audio.m4b"
    let ebookPath = "\(accountID)/\(itemID)/ebook.epub"
    try await database.writeAsync { db in
      var audio = DownloadRecord(
        accountId: accountID,
        itemId: itemID,
        serverFileIno: "audio-ino",
        orderIndex: 0,
        destinationRelativePath: audioPath,
        expectedBytes: 3,
        expectedMimeType: "audio/mp4",
        fileDurationSeconds: 60,
        receivedBytes: 3,
        state: .completed,
        mediaKind: .audio)
      try audio.insert(db)
      var ebook = DownloadRecord(
        accountId: accountID,
        itemId: itemID,
        serverFileIno: "ebook-ino",
        orderIndex: 0,
        destinationRelativePath: ebookPath,
        expectedBytes: 4,
        expectedMimeType: "application/epub+zip",
        fileDurationSeconds: 0,
        receivedBytes: 4,
        state: .completed,
        mediaKind: .ebook)
      try ebook.insert(db)
    }

    let audioURL = harness.downloadsRootURL.appendingPathComponent(audioPath)
    let ebookURL = harness.downloadsRootURL.appendingPathComponent(ebookPath)
    try FileManager.default.createDirectory(
      at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([0x01, 0x02, 0x03]).write(to: audioURL)
    try Data([0x04, 0x05, 0x06, 0x07]).write(to: ebookURL)
    await harness.stubSuccessfulLogout()

    let coordinator = harness.makeCoordinator(database: database)
    try await coordinator.confirmRemoval()

    #expect(FileManager.default.fileExists(atPath: audioURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: ebookURL.path) == false)
    #expect(
      try database.read { db in try DownloadRecord.fetchAll(db).isEmpty })
  }

  private func configureEbook(
    _ harness: DownloadCoordinatorHarness,
    ino: String?,
    ext: String?
  ) async throws {
    try await harness.database.writeAsync { db in
      try ItemRecord
        .filter(key: harness.itemRowId)
        .updateAll(
          db,
          Column("numAudioFiles").set(to: 1),
          Column("ebookFormat").set(to: "epub"),
          Column("ebookFileIno").set(to: ino),
          Column("ebookFileExt").set(to: ext))
    }
  }

  private func enqueueEbookDetail(
    _ harness: DownloadCoordinatorHarness,
    ino: String,
    ext: String,
    size: Int?
  ) {
    var metadata: [String: Any] = [
      "filename": "fixture.epub", "ext": ext, "path": "<redacted>",
    ]
    if let size { metadata["size"] = size }
    let object: [String: Any] =
      [
        "id": DownloadCoordinatorHarness.itemID,
        "libraryId": "lib-1",
        "mediaType": "book",
        "media": [
          "metadata": ["title": "Ebook"],
          "duration": 0.0,
          "audioFiles": [[String: Any]](),
          "tracks": [[String: Any]](),
          "chapters": [[String: Any]](),
          "ebookFile": ["ino": ino, "metadata": metadata],
        ] as [String: Any],
      ] as [String: Any]
    harness.http.enqueue(DownloadCoordinatorHarness.jsonResponse(object: object))
  }
}

private enum MatrixCell: String, CaseIterable, Sendable {
  case audioOnly
  case ebookOnly
  case bothComplete
  case audioCompleteEbookPending
  case audioPendingEbookComplete
  case ebookFailed
  case audioCompleteSupplementComplete
  case audioCompleteSupplementPending
  case audioCompleteSupplementFailed
  case audioCompleteSupplementWaitingForWiFi
  case audioPendingSupplementComplete
  case supplementOnlyComplete
  case supplementOnlyPending

  var hasAudio: Bool {
    switch self {
    case .ebookOnly, .ebookFailed:
      return false
    default:
      return true
    }
  }

  var hasReadableEbook: Bool {
    switch self {
    case .ebookOnly, .bothComplete, .audioCompleteEbookPending, .audioPendingEbookComplete,
      .ebookFailed:
      return true
    default:
      return false
    }
  }

  var rowSpecs: [MatrixRowSpec] {
    switch self {
    case .audioOnly:
      return [.audio(state: .completed, receivedBytes: 100)]
    case .ebookOnly:
      return [.ebook(state: .completed, receivedBytes: 40)]
    case .bothComplete:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .ebook(state: .completed, receivedBytes: 40),
      ]
    case .audioCompleteEbookPending:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .ebook(state: .pending, receivedBytes: 7),
      ]
    case .audioPendingEbookComplete:
      return [
        .audio(state: .pending, receivedBytes: 7),
        .ebook(state: .completed, receivedBytes: 40),
      ]
    case .ebookFailed:
      return [.ebook(state: .failed, receivedBytes: 3)]
    case .audioCompleteSupplementComplete:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .supplement(state: .completed, receivedBytes: 30),
      ]
    case .audioCompleteSupplementPending:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .supplement(state: .pending, receivedBytes: 5),
      ]
    case .audioCompleteSupplementFailed:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .supplement(state: .failed, receivedBytes: 2),
      ]
    case .audioCompleteSupplementWaitingForWiFi:
      return [
        .audio(state: .completed, receivedBytes: 100),
        .supplement(state: .pending, receivedBytes: 0, holdReason: .waitingForWiFi),
      ]
    case .audioPendingSupplementComplete:
      return [
        .audio(state: .pending, receivedBytes: 7),
        .supplement(state: .completed, receivedBytes: 30),
      ]
    case .supplementOnlyComplete:
      return [.supplement(state: .completed, receivedBytes: 30)]
    case .supplementOnlyPending:
      return [.supplement(state: .pending, receivedBytes: 5)]
    }
  }

  /// The rows every item-level fold counts.
  var itemMediaSpecs: [MatrixRowSpec] { rowSpecs.filter { $0.mediaKind.isItemMedia } }
}

private struct MatrixRowSpec: Sendable {
  let mediaKind: DownloadMediaKind
  let state: DownloadState
  let receivedBytes: Int64
  let expectedBytes: Int64
  let expectedMimeType: String
  let fileDurationSeconds: Double
  let serverFileIno: String
  var holdReason: DownloadHoldReason? = nil

  static func supplement(
    state: DownloadState, receivedBytes: Int64, holdReason: DownloadHoldReason? = nil
  ) -> Self {
    Self(
      mediaKind: .supplement,
      state: state,
      receivedBytes: receivedBytes,
      expectedBytes: 30,
      expectedMimeType: "application/pdf",
      fileDurationSeconds: 0,
      serverFileIno: "supplement-\(state.rawValue)",
      holdReason: holdReason)
  }

  static func audio(state: DownloadState, receivedBytes: Int64) -> Self {
    Self(
      mediaKind: .audio,
      state: state,
      receivedBytes: receivedBytes,
      expectedBytes: 100,
      expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 100,
      serverFileIno: "audio-\(state.rawValue)")
  }

  static func ebook(state: DownloadState, receivedBytes: Int64) -> Self {
    Self(
      mediaKind: .ebook,
      state: state,
      receivedBytes: receivedBytes,
      expectedBytes: 40,
      expectedMimeType: "application/epub+zip",
      fileDurationSeconds: 0,
      serverFileIno: "ebook-\(state.rawValue)")
  }
}

private final class MatrixFixture: @unchecked Sendable {
  let cell: MatrixCell
  let database: AppDatabase
  let accountID: Int64
  let libraryID: Int64
  let itemID: Int64
  let serverItemID: String
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let http: FakeHTTPClient
  let client: ABSClient
  let server: ABSServerConfig
  let outbox: OutboxStore
  let rootURL: URL

  init(cell: MatrixCell) async throws {
    self.cell = cell
    let database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: URL(string: "https://matrix.example.test")!)
    let http = FakeHTTPClient()
    let clientUUID = UUID().uuidString
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "matrix-user")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "matrix-access", refreshToken: "matrix-refresh"),
      for: tokenAccount)

    let (accountID, libraryID) = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "matrix-user",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "matrix-library", mediaType: "book", name: "Matrix")
      try library.insert(db)
      return (account.id!, library.id!)
    }
    let serverItemID = "matrix-\(cell.rawValue)"
    let itemID = try await database.writeAsync { db -> Int64 in
      var item = ItemRecord(
        accountId: accountID,
        libraryId: libraryID,
        serverItemId: serverItemID,
        mediaKind: "book",
        title: serverItemID,
        sortTitle: serverItemID,
        numAudioFiles: cell.hasAudio ? 1 : 0,
        ebookFormat: cell.hasReadableEbook ? "epub" : nil,
        ebookFileIno: cell.hasReadableEbook ? "ebook-catalog-ino" : nil,
        ebookFileExt: cell.hasReadableEbook ? "epub" : nil)
      try item.insert(db)
      return item.id!
    }

    let downloadStore = try DownloadStore(database: database)
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "DownloadMediaKindMatrix-\(UUID().uuidString)", isDirectory: true)
    let fileStore = try DownloadFileStore(
      rootURL: rootURL,
      fileAttributes: InertFileAttributes(),
      downloadStore: downloadStore)
    try await database.writeAsync { db in
      for spec in cell.rowSpecs {
        let relativePath = DownloadFileStore.destinationRelativePath(
          accountId: accountID,
          itemId: itemID,
          podcastEpisodeId: nil,
          orderIndex: 0,
          serverFileIno: spec.serverFileIno,
          mimeType: spec.expectedMimeType)
        var row = DownloadRecord(
          accountId: accountID,
          itemId: itemID,
          serverFileIno: spec.serverFileIno,
          orderIndex: 0,
          destinationRelativePath: relativePath,
          expectedBytes: spec.expectedBytes,
          expectedMimeType: spec.expectedMimeType,
          fileDurationSeconds: spec.fileDurationSeconds,
          receivedBytes: spec.receivedBytes,
          state: spec.state,
          holdReason: spec.holdReason,
          errorCategory: spec.state == .failed ? .validation : nil,
          mediaKind: spec.mediaKind)
        try row.insert(db)
      }
    }
    for spec in cell.rowSpecs where spec.state == .completed {
      let relativePath = DownloadFileStore.destinationRelativePath(
        accountId: accountID,
        itemId: itemID,
        podcastEpisodeId: nil,
        orderIndex: 0,
        serverFileIno: spec.serverFileIno,
        mimeType: spec.expectedMimeType)
      let url = fileStore.absoluteURL(forRelativePath: relativePath)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(repeating: 0x42, count: Int(spec.expectedBytes)).write(to: url)
    }

    self.database = database
    self.accountID = accountID
    self.libraryID = libraryID
    self.itemID = itemID
    self.serverItemID = serverItemID
    self.downloadStore = downloadStore
    self.downloadFileStore = fileStore
    self.http = http
    self.client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    self.server = server
    self.outbox = try OutboxStore(database: database)
    self.rootURL = rootURL
  }

  deinit {
    try? FileManager.default.removeItem(at: rootURL)
  }

  var expectedHomeDownloaded: Bool {
    Set(cell.itemMediaSpecs.map(\.mediaKind)).contains { mediaKind in
      let rows = cell.itemMediaSpecs.filter { $0.mediaKind == mediaKind }
      return rows.isEmpty == false && rows.allSatisfy { $0.state == .completed }
    }
  }

  var expectedItemDownloaded: Bool {
    cell.itemMediaSpecs.isEmpty == false && cell.itemMediaSpecs.allSatisfy { $0.state == .completed }
  }

  var expectedItemAggregate: DownloadAggregate {
    expectedAggregate(for: nil)
  }

  var expectedItemStatus: ItemDownloadStatus {
    switch cell {
    case .audioOnly, .ebookOnly, .bothComplete, .audioCompleteSupplementComplete,
      .audioCompleteSupplementPending, .audioCompleteSupplementFailed,
      .audioCompleteSupplementWaitingForWiFi:
      return .completed
    case .audioCompleteEbookPending, .audioPendingEbookComplete, .audioPendingSupplementComplete:
      return .queued
    case .ebookFailed:
      return .failed(category: .validation)
    case .supplementOnlyComplete, .supplementOnlyPending:
      return .notDownloaded
    }
  }

  var expectedItemPresence: ItemDownloadPresence {
    expectedPresence(for: nil)
  }

  var expectedLocalPlayback: Bool {
    cell.rowSpecs.contains { $0.mediaKind == .audio && $0.state == .completed }
      && cell.rowSpecs.filter { $0.mediaKind == .audio }.allSatisfy { $0.state == .completed }
  }

  var expectedStorageBytes: Int64 {
    cell.rowSpecs.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
  }

  func expectedAggregate(for mediaKind: DownloadMediaKind?) -> DownloadAggregate {
    let rows =
      if let mediaKind {
        cell.rowSpecs.filter { $0.mediaKind == mediaKind }
      } else {
        cell.itemMediaSpecs
      }
    guard rows.isEmpty == false else { return DownloadAggregate(state: .none, progressFraction: 0) }
    guard rows.allSatisfy({ $0.state == .completed }) else {
      let expected = rows.reduce(into: Int64(0)) { $0 += $1.expectedBytes }
      let received = rows.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
      return DownloadAggregate(
        state: .partial,
        progressFraction: min(max(Double(received) / Double(expected), 0), 1))
    }
    return DownloadAggregate(state: .complete, progressFraction: 1)
  }

  func expectedStatus(for mediaKind: DownloadMediaKind) -> ItemDownloadStatus {
    guard let row = cell.rowSpecs.first(where: { $0.mediaKind == mediaKind }) else {
      return .notDownloaded
    }
    switch row.state {
    case .completed:
      return .completed
    case .pending:
      return .queued
    case .failed:
      return .failed(category: .validation)
    default:
      return .notDownloaded
    }
  }

  func expectedPresence(for mediaKind: DownloadMediaKind?) -> ItemDownloadPresence {
    let status: ItemDownloadStatus
    if let mediaKind {
      status = expectedStatus(for: mediaKind)
    } else {
      status = expectedItemStatus
    }
    switch status {
    case .notDownloaded:
      return .none
    case .completed:
      return .completed
    default:
      return .partial
    }
  }

  func items(matching predicate: String) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT item.serverItemId FROM item
          WHERE (\(predicate))
          ORDER BY item.serverItemId
          """)
    }
  }

  func makePlaybackCoordinator() -> PlaybackSessionCoordinator {
    PlaybackSessionCoordinator(
      client: client,
      database: database,
      outbox: outbox,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      downloadStore: downloadStore,
      downloadFileStore: downloadFileStore)
  }

  func enqueuePlayResponse() {
    let object: [String: Any] = [
      "id": "matrix-session",
      "libraryItemId": serverItemID,
      "mediaType": "book",
      "displayTitle": "Matrix Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "matrix-device"],
      "audioTracks": [
        [
          "index": 1,
          "startOffset": 0,
          "duration": 3600,
          "title": "Track 1",
          "contentUrl": "/api/items/\(serverItemID)/file/audio",
          "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    http.enqueue(
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }
}
