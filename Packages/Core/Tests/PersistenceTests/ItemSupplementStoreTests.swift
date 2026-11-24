import Foundation
import GRDB
import Testing

@testable import Persistence

/// The v76 supplement set, its device-local page memory, and its join with the supplement
/// download rows.
@Suite struct ItemSupplementStoreTests {

  private struct Fixture {
    let database: AppDatabase
    let accountId: Int64
    let itemId: Int64
    let rootURL: URL
    let store: ItemSupplementStore

    init() async throws {
      database = try AppDatabase.inMemory()
      let ids = try await database.writeAsync { db -> (Int64, Int64) in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: "user-1", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
        try library.insert(db)
        var item = ItemRecord(
          accountId: account.id!, libraryId: library.id!, serverItemId: "item-1",
          mediaKind: "book", title: "Book", sortTitle: "book", numAudioFiles: 1)
        try item.insert(db)
        return (account.id!, item.id!)
      }
      accountId = ids.0
      itemId = ids.1
      rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ItemSupplementStoreTests-\(UUID().uuidString)", isDirectory: true)
      store = ItemSupplementStore(database: database, downloadRootURL: rootURL)
    }

    func store(_ supplements: [StoredItemSupplement]) async throws {
      try await ExpandedMetadataBatchStore(database: database).store(
        [
          ExpandedItemMetadataMutation(
            serverItemId: "item-1", seriesName: nil, narratorName: nil, itemDescription: nil,
            ebookFileIno: nil, ebookFileExt: nil, chapters: [], supplements: supplements)
        ],
        accountId: accountId, fetchedAt: Date(timeIntervalSince1970: 1_750_000_000))
    }

    func insertRow(
      ino: String, state: DownloadState, holdReason: DownloadHoldReason? = nil,
      path: String = "supplement.pdf"
    ) async throws {
      try await database.writeAsync { [accountId, itemId] db in
        var row = DownloadRecord(
          accountId: accountId, itemId: itemId, serverFileIno: ino, orderIndex: 0,
          destinationRelativePath: path, expectedBytes: 10, expectedMimeType: "application/pdf",
          fileDurationSeconds: 0, receivedBytes: state == .completed ? 10 : 0, state: state,
          holdReason: holdReason, mediaKind: .supplement)
        try row.insert(db)
      }
    }
  }

  private static let maps = StoredItemSupplement(
    serverFileIno: "900", position: 0, filename: "Maps.pdf", sizeBytes: 10)
  private static let tables = StoredItemSupplement(
    serverFileIno: "901", position: 1, filename: "Tables.pdf", sizeBytes: 20)

  @Test func replacingTheSetPreservesThePageOfASurvivingFile() async throws {
    let fixture = try await Fixture()
    try await fixture.store([Self.maps, Self.tables])
    await fixture.store.setLastViewedPage(itemId: "item-1", serverFileIno: "900", page: 12)
    await fixture.store.setLastViewedPage(itemId: "item-1", serverFileIno: "901", page: 3)

    try await fixture.store([
      StoredItemSupplement(serverFileIno: "900", position: 0, filename: "Maps v2.pdf", sizeBytes: 11)
    ])

    let supplements = try await fixture.store.supplements(itemId: "item-1")
    #expect(supplements.map(\.serverFileIno) == ["900"])
    #expect(supplements.first?.filename == "Maps v2.pdf")
    #expect(supplements.first?.lastViewedPage == 12)
  }

  @Test func anEmptyAuthoritativeListClearsTheSet() async throws {
    let fixture = try await Fixture()
    try await fixture.store([Self.maps])
    try await fixture.store([])
    #expect(try await fixture.store.supplements(itemId: "item-1").isEmpty)
  }

  @Test func fileStateFollowsTheSupplementRow() async throws {
    let fixture = try await Fixture()
    try await fixture.store([Self.maps, Self.tables])
    try await fixture.insertRow(ino: "901", state: .pending, holdReason: .waitingForWiFi)
    // An audio row with the same ino is never mistaken for the PDF's.
    try await fixture.database.writeAsync { [accountId = fixture.accountId, itemId = fixture.itemId] db in
      var audio = DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "audio-1", orderIndex: 0,
        destinationRelativePath: "audio.mp3", expectedBytes: 10, expectedMimeType: "audio/mpeg",
        fileDurationSeconds: 60, state: .completed)
      try audio.insert(db)
    }

    let supplements = try await fixture.store.supplements(itemId: "item-1")
    #expect(supplements.map(\.fileState) == [.notDownloaded, .waitingForWiFi])
  }

  @Test func aCompletedRowIsReadyOnlyWhileItsFileExists() async throws {
    let fixture = try await Fixture()
    try await fixture.store([Self.maps])
    try await fixture.insertRow(ino: "900", state: .completed, path: "a/maps.pdf")
    #expect(try await fixture.store.supplements(itemId: "item-1").first?.fileState == .failed)

    let url = fixture.rootURL.appendingPathComponent("a/maps.pdf")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 10).write(to: url)
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    #expect(
      try await fixture.store.supplements(itemId: "item-1").first?.fileState == .ready(fileURL: url))
  }

  @Test func theSetGoesWithItsItemAndItsAccount() async throws {
    let fixture = try await Fixture()
    try await fixture.store([Self.maps])
    try await fixture.database.writeAsync { [itemId = fixture.itemId] db in
      _ = try ItemRecord.deleteOne(db, key: itemId)
    }
    #expect(try fixture.database.read { db in try ItemSupplementRecord.fetchCount(db) } == 0)

    let other = try await Fixture()
    try await other.store([Self.maps])
    try await other.database.writeAsync { [accountId = other.accountId] db in
      _ = try AccountRecord.deleteOne(db, key: accountId)
    }
    #expect(try other.database.read { db in try ItemSupplementRecord.fetchCount(db) } == 0)
    #expect(
      try other.database.read { db in try AccountRemover.discoverAccountOwnedTables(db) }
        .contains("itemSupplement"))
  }

  @Test func theDownloadedShelfReportsACompletedSupplementBesideTheAudio() async throws {
    let fixture = try await Fixture()
    try await fixture.insertRow(ino: "900", state: .completed)
    try await fixture.database.writeAsync { [accountId = fixture.accountId, itemId = fixture.itemId] db in
      var audio = DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "audio-1", orderIndex: 0,
        destinationRelativePath: "audio.mp3", expectedBytes: 10, expectedMimeType: "audio/mpeg",
        fileDurationSeconds: 60, receivedBytes: 10, state: .completed)
      try audio.insert(db)
    }
    var iterator = DefaultHomeReading(database: fixture.database)
      .observeDownloaded(category: nil, limit: 10)
      .makeAsyncIterator()
    let item = try #require(await iterator.next()?.first)
    #expect(item.audioDownloaded)
    #expect(item.supplementDownloaded)
    #expect(item.isDownloaded)
  }
}
