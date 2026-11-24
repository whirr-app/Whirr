import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("Library selection retention")
struct LibrarySelectionRetentionTests {
  @Test("an excluded library's downloaded and queued item remains resolvable")
  func excludedLibraryRetainsDownloadAndQueueReads() async throws {
    let database = try AppDatabase.inMemory()
    let (accountID, itemID) = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: try #require(account.id), serverLibraryId: "excluded", mediaType: "book",
        name: "Excluded", isIncluded: false)
      try library.insert(db)
      var item = ItemRecord(
        accountId: try #require(account.id), libraryId: try #require(library.id),
        serverItemId: "retained-book", mediaKind: "book", title: "Retained", sortTitle: "retained",
        numAudioFiles: 1)
      try item.insert(db)
      return (try #require(account.id), try #require(item.id))
    }
    let downloads = try DownloadStore(database: database)
    let download = try downloads.enqueue(
      accountId: accountID, itemId: itemID, serverFileIno: "file-1", orderIndex: 0,
      destinationRelativePath: "retained.mp3", expectedBytes: 100, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 10)
    let queue = ListeningQueueStore(database: database, accountId: accountID)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "retained-book"))
    try await queue.append(identity: identity)

    #expect(try downloads.fetchDownloads(itemId: itemID).map(\.id) == [download.id])
    #expect(await queue.fetchQueue().map(\.identity) == [identity])
  }
}
