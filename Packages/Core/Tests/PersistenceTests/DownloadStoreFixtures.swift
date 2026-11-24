import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC`, so async tests go through this
/// indirection.
enum DownloadStoreFixtures {
  static func currentThreadIsMain() -> Bool { Thread.isMainThread }
}

extension DownloadStoreTests {
  // MARK: - Helpers

  struct DownloadTwin {
    let syncDatabase: AppDatabase
    let asyncDatabase: AppDatabase
    let syncStore: DownloadStore
    let asyncStore: DownloadStore
    let accountId: Int64
    let itemId: Int64
  }

  func makeTwin(kind: String = "book") async throws -> DownloadTwin {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let (syncAccountId, syncLibraryId) = try await insertAccountAndLibrary(syncDatabase)
    let (asyncAccountId, asyncLibraryId) = try await insertAccountAndLibrary(asyncDatabase)
    let syncItemId = try await insertItem(
      syncDatabase, accountId: syncAccountId, libraryId: syncLibraryId, kind: kind)
    let asyncItemId = try await insertItem(
      asyncDatabase, accountId: asyncAccountId, libraryId: asyncLibraryId, kind: kind)
    #expect(asyncAccountId == syncAccountId)
    #expect(asyncItemId == syncItemId)
    return DownloadTwin(
      syncDatabase: syncDatabase,
      asyncDatabase: asyncDatabase,
      syncStore: try DownloadStore(database: syncDatabase),
      asyncStore: try DownloadStore(database: asyncDatabase),
      accountId: syncAccountId,
      itemId: syncItemId)
  }

  func seedDownload(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    serverFileIno: String,
    orderIndex: Int = 0,
    state: DownloadState = .pending,
    receivedBytes: Int64 = 0,
    origin: DownloadOrigin = .manual,
    mediaKind: DownloadMediaKind = .audio
  ) async throws -> DownloadRecord {
    try await database.writeAsync { db in
      var record = DownloadRecord(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        serverFileIno: serverFileIno,
        orderIndex: orderIndex,
        destinationRelativePath: "item-1/\(serverFileIno).m4b",
        expectedBytes: 1000,
        expectedMimeType: "audio/mp4",
        fileDurationSeconds: 60,
        receivedBytes: receivedBytes,
        state: state,
        origin: origin,
        mediaKind: mediaKind)
      try record.insert(db)
      return record
    }
  }

  func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
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

  func insertItem(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, kind: String,
    serverItemId: String = "item-1"
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: kind,
        title: "Title", sortTitle: "title")
      try item.insert(db)
      return item.id!
    }
  }

}
