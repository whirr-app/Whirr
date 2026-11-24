import Foundation
import GRDB
import Testing

@testable import Persistence

/// The read the Saved for Later auto-download decorator performs. It answers in the shape
/// `ItemMediaCapability.downloadFormats` does (audio first for a mixed item, nothing for a
/// document Whirr cannot open) without SyncEngine having to reach AppModel.
@Suite struct SavedShelfDownloadTargetTests {

  @Test("an audio-only item resolves to its audio download")
  func audioOnlyItem() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(for: .item(itemID: fixture.audiobookServerItemID))
        == [.audio(itemID: fixture.audiobookServerItemID)])
  }

  @Test("an EPUB-only item resolves to its ebook download")
  func ebookOnlyItem() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(for: .item(itemID: fixture.ebookServerItemID))
        == [.ebook(itemID: fixture.ebookServerItemID)])
  }

  @Test("a mixed audio and EPUB item resolves to both, audio first")
  func mixedItemResolvesToBoth() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(for: .item(itemID: fixture.mixedServerItemID))
        == [
          .audio(itemID: fixture.mixedServerItemID), .ebook(itemID: fixture.mixedServerItemID),
        ])
  }

  @Test("a PDF beside audio is a supplement, not a second download")
  func pdfBesideAudioIsNotRequested() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(for: .item(itemID: fixture.audioWithPDFServerItemID))
        == [.audio(itemID: fixture.audioWithPDFServerItemID)])
  }

  @Test("a document Whirr cannot open resolves to nothing")
  func unsupportedDocumentResolvesToNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(for: .item(itemID: fixture.documentServerItemID)).isEmpty)
  }

  @Test("a podcast episode resolves to its episode download")
  func podcastEpisodeResolves() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(
        for: .podcastEpisode(
          itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID))
        == [.episode(itemID: fixture.showServerItemID, episodeID: fixture.episodeServerID)])
  }

  @Test("a podcast show reached as a whole item resolves to nothing")
  func podcastShowResolvesToNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(try await store.downloadTargets(for: .item(itemID: fixture.showServerItemID)).isEmpty)
  }

  @Test("an identity this account has no row for resolves to nothing")
  func unknownIdentityResolvesToNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(try await store.downloadTargets(for: .item(itemID: "absent")).isEmpty)
    #expect(
      try await store.downloadTargets(
        for: .podcastEpisode(itemID: fixture.showServerItemID, episodeID: "absent")
      ).isEmpty)
  }

  @Test("a native RSS episode resolves to its episode download")
  func rssEpisodeResolvesToEpisodeTarget() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let rss = try await Self.seedRSSEpisode(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(
        for: .rssEpisode(itemID: rss.itemID, episodeID: rss.identityKey))
        == [.episode(itemID: rss.itemID, episodeID: rss.identityKey)])
  }

  @Test("an RSS episode the feed store has no row for resolves to nothing")
  func unknownRSSEpisodeResolvesToNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let rss = try await Self.seedRSSEpisode(database)
    let store = SavedShelfStore(database: database, accountId: fixture.accountId)

    #expect(
      try await store.downloadTargets(
        for: .rssEpisode(itemID: rss.itemID, episodeID: "absent")
      ).isEmpty)
    #expect(
      try await store.downloadTargets(
        for: .rssEpisode(itemID: "not-a-source-identity", episodeID: rss.identityKey)
      ).isEmpty)
  }

  // MARK: - Fixture

  private struct RSSFixture: Sendable {
    let itemID: String
    let identityKey: String
  }

  private static func seedRSSEpisode(_ database: AppDatabase) async throws -> RSSFixture {
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/target-\(UUID().uuidString).xml")!,
      title: "Native Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let identityKey = "native-episode"
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: identityKey, title: "Native Episode",
          enclosureURL: URL(string: "https://example.com/native.mp3")!, durationSeconds: 60)
      ])
    return RSSFixture(
      itemID: try #require(PodcastSourceIdentity.rss(feedId: feedId)?.itemId),
      identityKey: identityKey)
  }

  private struct Fixture: Sendable {
    let accountId: Int64
    let audiobookServerItemID: String
    let ebookServerItemID: String
    let mixedServerItemID: String
    let audioWithPDFServerItemID: String
    let documentServerItemID: String
    let showServerItemID: String
    let episodeServerID: String
  }

  private static func seed(_ database: AppDatabase) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(UUID().uuidString)", serverBaseURL: "server",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)

      var audiobook = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book",
        mediaKind: "book", title: "Book", sortTitle: "book", numAudioFiles: 4)
      try audiobook.insert(db)

      var ebook = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "ebook",
        mediaKind: "book", title: "Ebook", sortTitle: "ebook", ebookFormat: "epub")
      try ebook.insert(db)

      var mixed = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "mixed",
        mediaKind: "book", title: "Mixed", sortTitle: "mixed", numAudioFiles: 6,
        ebookFormat: "epub")
      try mixed.insert(db)

      var audioWithPDF = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "audio-pdf",
        mediaKind: "book", title: "Audio and PDF", sortTitle: "audio and pdf", numAudioFiles: 2,
        ebookFormat: "pdf")
      try audioWithPDF.insert(db)

      var document = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "document",
        mediaKind: "book", title: "Document", sortTitle: "document", ebookFormat: "pdf")
      try document.insert(db)

      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)

      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "episode", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)

      return Fixture(
        accountId: account.id!, audiobookServerItemID: "book", ebookServerItemID: "ebook",
        mixedServerItemID: "mixed", audioWithPDFServerItemID: "audio-pdf",
        documentServerItemID: "document", showServerItemID: "show", episodeServerID: "episode")
    }
  }
}
