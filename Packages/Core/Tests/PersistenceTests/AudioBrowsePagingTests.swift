import Foundation
import GRDB
import Testing

@testable import Persistence

/// Bounded audiobook paging: a page costs a page, whatever the library holds, and paging visits
/// each audiobook exactly once.
@Suite struct AudioBrowsePagingTests {

  @Test func pagingAnEightThousandItemLibraryVisitsEveryAudiobookOnceInOrder() async throws {
    let database = try AppDatabase.inMemory()
    let expected = try await Self.seedLargeLibrary(database, count: 8_000)
    let paging = DefaultAudioBrowsePaging(database: database)

    var seen: [String] = []
    var cursor: AudiobookPageCursor?
    var pages = 0
    repeat {
      let page = try await paging.audiobookPage(after: cursor, limit: 40)
      // Membership is decided before the limit, so only the final page may be short.
      #expect(page.rows.count == 40 || page.next == nil)
      seen += page.rows.map(\.identity.itemID)
      cursor = page.next
      pages += 1
    } while cursor != nil && pages < 1_000

    #expect(seen == expected)
    #expect(Set(seen).count == seen.count)
    #expect(pages == (expected.count + 39) / 40)
  }

  @Test func firstPageIsFullEvenWhenExcludedRowsSortFirst() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      // Fifty rows that are not listable sort ahead of the audiobooks.
      for index in 0..<50 {
        try Self.insert(
          db, scope: scope, id: "a-ebook-\(index)", sortTitle: "a\(index)", audioFiles: 0, ebook: "epub")
      }
      for index in 0..<10 {
        try Self.insert(db, scope: scope, id: "book-\(index)", sortTitle: "m\(index)")
      }
    }

    let page = try await DefaultAudioBrowsePaging(database: database).audiobookPage(after: nil, limit: 5)

    #expect(page.rows.map(\.identity.itemID) == (0..<5).map { "book-\($0)" })
    #expect(page.next != nil)
  }

  @Test func excludesSoftDeletedPodcastEbookOnlyAndExcludedLibraryRows() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      try Self.insert(db, scope: scope, id: "book", sortTitle: "a")
      try Self.insert(db, scope: scope, id: "mixed", sortTitle: "b", audioFiles: 3, ebook: "epub")
      try Self.insert(db, scope: scope, id: "ebook", sortTitle: "c", audioFiles: 0, ebook: "epub")
      try Self.insert(db, scope: scope, id: "deleted", sortTitle: "d", softDeleted: true)
      try Self.insert(db, scope: scope, id: "show", sortTitle: "e", mediaKind: "podcast")
      try Self.insert(db, scope: scope, id: "hidden", sortTitle: "f", libraryId: scope.excludedLibraryId)
    }

    let page = try await DefaultAudioBrowsePaging(database: database).audiobookPage(after: nil, limit: 20)

    #expect(page.rows.map(\.identity.itemID) == ["book", "mixed"])
    #expect(page.next == nil)
  }

  @Test func booksSharingASortTitlePageWithoutRepeatOrGap() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<7 {
        try Self.insert(db, scope: scope, id: "same-\(index)", sortTitle: "same")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    let first = try await paging.audiobookPage(after: nil, limit: 3)
    let second = try await paging.audiobookPage(after: first.next, limit: 3)
    let third = try await paging.audiobookPage(after: second.next, limit: 3)

    let ids = (first.rows + second.rows + third.rows).map(\.identity.itemID)
    #expect(ids == (0..<7).map { "same-\($0)" })
    #expect(third.next == nil)
  }

  @Test func aRowDeletedBetweenPagesDoesNotShiftTheNextPage() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<6 {
        try Self.insert(db, scope: scope, id: "book-\(index)", sortTitle: "t\(index)")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)
    let first = try await paging.audiobookPage(after: nil, limit: 3)

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE serverItemId = 'book-1'")
    }
    let second = try await paging.audiobookPage(after: first.next, limit: 3)

    #expect(second.rows.map(\.identity.itemID) == ["book-3", "book-4", "book-5"])
  }

  @Test func pageSizeIsClamped() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<150 {
        try Self.insert(db, scope: scope, id: "book-\(index)", sortTitle: String(format: "t%04d", index))
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    #expect(try await paging.audiobookPage(after: nil, limit: 10_000).rows.count == 100)
    #expect(try await paging.audiobookPage(after: nil, limit: 0).rows.count == 1)
  }

  @Test func downloadedAudioListsOnlyBooksAndEpisodesWhoseOwnAudioIsComplete() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      let complete = try Self.insert(db, scope: scope, id: "complete", sortTitle: "b")
      try Self.download(db, scope: scope, item: complete, ino: "c1")
      try Self.download(db, scope: scope, item: complete, ino: "c2")
      // The EPUB of a mixed book is on the device; its audio is not.
      let ebookOnly = try Self.insert(db, scope: scope, id: "ebook-only", sortTitle: "c", audioFiles: 2, ebook: "epub")
      try Self.download(db, scope: scope, item: ebookOnly, ino: "e1", mediaKind: .ebook)
      let partial = try Self.insert(db, scope: scope, id: "partial", sortTitle: "d")
      try Self.download(db, scope: scope, item: partial, ino: "p1")
      try Self.download(db, scope: scope, item: partial, ino: "p2", state: .downloading)
      let leaving = try Self.insert(db, scope: scope, id: "leaving", sortTitle: "e")
      try Self.download(db, scope: scope, item: leaving, ino: "l1", state: .deleting)
      let hidden = try Self.insert(
        db, scope: scope, id: "hidden", sortTitle: "f", libraryId: scope.excludedLibraryId)
      try Self.download(db, scope: scope, item: hidden, ino: "h1")
      try Self.insert(db, scope: scope, id: "none", sortTitle: "g")

      let show = try Self.insert(db, scope: scope, id: "show", sortTitle: "a", mediaKind: "podcast", audioFiles: 0)
      for (index, id) in ["old", "new", "pending", "gone"].enumerated() {
        var episode = PodcastEpisodeRecord(
          accountId: scope.accountId, itemId: show, serverEpisodeId: id, title: "Episode \(id)",
          publishedAt: Date(timeIntervalSince1970: Double(index)), lastSeenGeneration: 1,
          softDeleted: id == "gone")
        try episode.insert(db)
        try Self.download(
          db, scope: scope, item: show, episode: episode.id, ino: "ep-\(id)",
          state: id == "pending" ? .pending : .completed)
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    let first = try await paging.downloadedAudioPage(after: nil, limit: 2)
    let second = try await paging.downloadedAudioPage(after: first.next, limit: 2)

    #expect(
      first.rows.map(\.identity) == [
        ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "new"),
        ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "old"),
      ])
    #expect(first.rows.map(\.subtitle) == ["Title show", "Title show"])
    #expect(second.rows.map(\.identity) == [ListeningIdentity.audiobook(itemID: "complete")])
    #expect(second.rows.first?.subtitle == "Author")
    #expect(second.next == nil)
  }

  private struct Scope: Sendable {
    let accountId: Int64
    let libraryId: Int64
    let excludedLibraryId: Int64
  }

  private static func seedScope(_ database: AppDatabase) async throws -> Scope {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "paging-client", serverBaseURL: "https://example.test",
        serverUserId: "paging-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "books", mediaType: "book", name: "Books")
      try library.insert(db)
      var excluded = LibraryRecord(
        accountId: account.id!, serverLibraryId: "other", mediaType: "book", name: "Other",
        isIncluded: false)
      try excluded.insert(db)
      return Scope(accountId: account.id!, libraryId: library.id!, excludedLibraryId: excluded.id!)
    }
  }

  private static func download(
    _ db: Database, scope: Scope, item: Int64, episode: Int64? = nil, ino: String,
    mediaKind: DownloadMediaKind = .audio, state: DownloadState = .completed
  ) throws {
    var download = DownloadRecord(
      accountId: scope.accountId, itemId: item, podcastEpisodeId: episode, serverFileIno: ino,
      orderIndex: 0, destinationRelativePath: "files/\(ino)", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, state: state, mediaKind: mediaKind)
    try download.insert(db)
  }

  @discardableResult
  private static func insert(
    _ db: Database, scope: Scope, id: String, sortTitle: String, mediaKind: String = "book",
    audioFiles: Int = 1, ebook: String? = nil, softDeleted: Bool = false, libraryId: Int64? = nil
  ) throws -> Int64 {
    var item = ItemRecord(
      accountId: scope.accountId, libraryId: libraryId ?? scope.libraryId, serverItemId: id,
      mediaKind: mediaKind, title: "Title \(id)", sortTitle: sortTitle, author: "Author",
      numAudioFiles: audioFiles, ebookFormat: ebook, softDeleted: softDeleted)
    try item.insert(db)
    return item.id!
  }

  /// A library shaped like a real one: mostly audiobooks, with ebooks, removed rows and repeated
  /// sort titles spread through it. Returns the audiobooks' ids in the order paging must yield.
  private static func seedLargeLibrary(_ database: AppDatabase, count: Int) async throws -> [String] {
    let scope = try await seedScope(database)
    return try await database.writeAsync { db in
      var expected: [(sortTitle: String, rowID: Int64, id: String)] = []
      for index in 0..<count {
        let id = "item-\(index)"
        // Insertion order is unrelated to title order, and every fifth title repeats.
        let key = (index * 7_919) % count
        let sortTitle = String(format: "title %05d", key % 5 == 0 ? key / 5 : key)
        let isEbook = index % 4 == 3
        let isDeleted = index % 10 == 9
        try insert(
          db, scope: scope, id: id, sortTitle: sortTitle, audioFiles: isEbook ? 0 : 2,
          ebook: isEbook ? "epub" : nil, softDeleted: isDeleted)
        if isEbook == false && isDeleted == false {
          expected.append((sortTitle, db.lastInsertedRowID, id))
        }
      }
      return expected.sorted { ($0.sortTitle, $0.rowID) < ($1.sortTitle, $1.rowID) }.map(\.id)
    }
  }
}
