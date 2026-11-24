import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct CompanionCatalogueTests {
  @Test func accountAndCombinedHashesIncludeEveryIdentityComponent() {
    let base = AccountIdentity(id: 1, clientUUID: "device", serverIdentityFingerprint: "server-a")
    let same = CompanionCatalogueBuilder.identityHashes(for: base)
    let otherAccount = CompanionCatalogueBuilder.identityHashes(
      for: AccountIdentity(id: 2, clientUUID: "device", serverIdentityFingerprint: "server-a"))
    let otherClient = CompanionCatalogueBuilder.identityHashes(
      for: AccountIdentity(id: 1, clientUUID: "another-device", serverIdentityFingerprint: "server-a"))
    let otherServer = CompanionCatalogueBuilder.identityHashes(
      for: AccountIdentity(id: 1, clientUUID: "device", serverIdentityFingerprint: "server-b"))
    #expect(same.account != otherAccount.account)
    #expect(same.combined != otherAccount.combined)
    #expect(same.account != otherClient.account)
    #expect(same.combined != otherClient.combined)
    #expect(same.server == otherAccount.server)
    #expect(same.server != otherServer.server)
    #expect(same.combined != otherServer.combined)
    #expect(same.combined == CompanionCatalogueBuilder.identityHashes(for: base).combined)
  }

  @Test("builds mixed shelves from ABS and native persisted projections")
  func buildsMixedCatalogue() {
    let book = Self.item(id: "book", title: "Book", category: .audiobook, progress: 90)
    let nativeContinue = Self.item(
      id: "rss:7", title: "Native Show", category: .podcast, episodeID: "native-episode",
      episodeTitle: "Native Episode", progress: 20)
    let nativeEpisode = Self.episode(
      itemID: "rss:7", episodeID: "native-episode", title: "Native Episode")
    let nativeDownload = RSSDownloadedFeed(
      id: 7,
      title: "Native Show",
      sourceURL: URL(string: "https://private.example/feed.xml")!,
      episodes: [
        RSSDownloadedEpisode(
          id: "native-episode", title: "Native Episode", state: .completed,
          actualBytes: 10, expectedBytes: 10, holdReason: nil)
      ])

    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity,
        continueListening: [book, nativeContinue],
        recentBooks: [book],
        recentEpisodes: [Self.episode(itemID: "book", episodeID: "book-episode", title: "ABS Episode"), nativeEpisode],
        downloads: [Self.item(id: "download", title: "Downloaded", category: .audiobook, downloaded: true)],
        nativeDownloads: [nativeDownload]))

    #expect(snapshot.isSignedIn)
    #expect(snapshot.continueListening.count == 2)
    #expect(snapshot.recentBooks.map(\.title) == ["Book"])
    #expect(snapshot.recentEpisodes.count == 2)
    #expect(snapshot.downloads.count == 2)
    #expect(snapshot.recentEpisodes.contains { $0.capabilities.watchPlayable == false })
    #expect(snapshot.items(in: .recentBooks) == snapshot.recentBooks)
  }

  @Test("Audiobookshelf rows are Watch-playable in every shelf; native rows never are")
  func watchPlayabilityFollowsSource() {
    let book = Self.item(id: "book", title: "Book", category: .audiobook, progress: 30)
    let nativeContinue = Self.item(
      id: "rss:7", title: "Native Show", category: .podcast, episodeID: "native-episode",
      episodeTitle: "Native Episode", progress: 20)
    let bookmark = PlaybackBookmark(
      serverItemId: "book", title: "Book", author: nil, durationSeconds: 600, positionSeconds: 30,
      isFinished: false)
    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity,
        continueListening: [book, nativeContinue],
        currentBookmark: bookmark,
        recentBooks: [book],
        recentEpisodes: [
          Self.episode(itemID: "book", episodeID: "book-episode", title: "ABS Episode"),
          Self.episode(itemID: "rss:7", episodeID: "native-episode", title: "Native Episode"),
        ],
        downloads: [Self.item(id: "download", title: "Downloaded", category: .audiobook, downloaded: true)]))

    func playable(_ section: CompanionCatalogueSection) -> [String: Bool] {
      let rows = snapshot.items(in: section)
      return Dictionary(uniqueKeysWithValues: rows.map { ($0.title, $0.capabilities.watchPlayable) })
    }
    #expect(playable(.continueListening) == ["Book": true, "Native Episode": false])
    #expect(playable(.recentBooks) == ["Book": true])
    #expect(playable(.recentEpisodes) == ["ABS Episode": true, "Native Episode": false])
    #expect(playable(.downloads) == ["Downloaded": true])
    #expect(snapshot.items(in: .continueListening).allSatisfy { !$0.capabilities.watchDownloaded })
  }

  @Test("drops malformed source, episode, and title rows")
  func excludesInvalidRows() {
    let invalidRows = [
      Self.item(id: "", title: "Empty identity", category: .audiobook),
      Self.item(id: "rss:not-a-feed", title: "Malformed native identity", category: .podcast),
      Self.item(id: "valid", title: "   ", category: .audiobook),
      Self.item(id: "valid", title: "Blank episode", category: .podcast, episodeID: "   "),
    ]
    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity,
        continueListening: invalidRows,
        recentEpisodes: [Self.episode(itemID: "rss:0", episodeID: "e", title: "Bad feed")],
        nativeDownloads: [
          RSSDownloadedFeed(
            id: 0, title: "Bad feed", sourceURL: URL(string: "https://private.example")!,
            episodes: [
              RSSDownloadedEpisode(
                id: "e", title: "Episode", state: .completed,
                actualBytes: 1, expectedBytes: 1, holdReason: nil)
            ])
        ]))

    #expect(snapshot.continueListening.isEmpty)
    #expect(snapshot.recentEpisodes.isEmpty)
    #expect(snapshot.downloads.isEmpty)
  }

  @Test("bounds title and subtitle text")
  func boundsText() {
    let longTitle = String(repeating: "T", count: CompanionCatalogueBuilder.maxTitleCharacters + 20)
    let longAuthor = String(repeating: "A", count: CompanionCatalogueBuilder.maxSubtitleCharacters + 20)
    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity,
        recentBooks: [
          Self.item(
            id: "book", title: longTitle, author: longAuthor, category: .audiobook)
        ]))

    #expect(snapshot.recentBooks.first?.title.count == CompanionCatalogueBuilder.maxTitleCharacters)
    #expect(snapshot.recentBooks.first?.subtitle?.count == CompanionCatalogueBuilder.maxSubtitleCharacters)
  }

  @Test("typed source mapping rejects a reserved ABS collision and deduplicates native identity")
  func sourceCollisionAndDeduplication() {
    let malformedABS = Self.item(id: "rss:7", title: "Pretend ABS", category: .audiobook)
    let older = Self.episode(itemID: "rss:7", episodeID: "e", title: "Older", date: 10)
    let newer = Self.episode(itemID: "rss:7", episodeID: "e", title: "Newer", date: 20)
    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity,
        recentBooks: [malformedABS],
        recentEpisodes: [older, newer]))

    #expect(snapshot.recentBooks.isEmpty)
    #expect(snapshot.recentEpisodes.map(\.title) == ["Newer"])
    #expect(snapshot.recentEpisodes.first?.id.source.source == .rss(feedId: 7))
  }

  @Test("native downloads are phone-only and incomplete rows are excluded")
  func nativeDownloadCapabilities() {
    let feed = RSSDownloadedFeed(
      id: 7, title: "Native Show", sourceURL: URL(string: "https://private.example")!,
      episodes: [
        RSSDownloadedEpisode(
          id: "complete", title: "Complete", state: .completed,
          actualBytes: 10, expectedBytes: 10, holdReason: nil),
        RSSDownloadedEpisode(
          id: "pending", title: "Pending", state: .pending,
          actualBytes: 1, expectedBytes: 10, holdReason: nil),
      ])
    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(accountIdentity: Self.identity, nativeDownloads: [feed]))

    #expect(snapshot.downloads.count == 1)
    #expect(snapshot.downloads[0].capabilities.phonePlayable)
    #expect(snapshot.downloads[0].capabilities.phoneDownloaded)
    #expect(snapshot.downloads[0].capabilities.watchPlayable == false)
    #expect(snapshot.downloads[0].capabilities.watchDownloaded == false)
  }

  @Test("rows carry the server date of the book or show whose cover they draw")
  func rowsCarryCoverServerUpdatedAt() {
    let updatedAt = Date(timeIntervalSince1970: 1_790_000_000.123)
    let book = HomeItem(
      serverItemId: "book", title: "Gilead", author: nil, category: .audiobook, durationSeconds: 60,
      progressSeconds: 10, isFinished: false, addedAt: nil, isDownloaded: false,
      serverUpdatedAt: updatedAt)
    let episode = HomePodcastEpisode(
      itemID: "show", showTitle: "Show", showAuthor: nil, episodeID: "ep", title: "Episode",
      subtitle: nil, publishedAt: Date(timeIntervalSince1970: 100), durationSeconds: 60,
      showServerUpdatedAt: updatedAt)

    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity, continueListening: [book], recentBooks: [book],
        recentEpisodes: [episode], downloads: [], nativeDownloads: []))

    #expect(snapshot.continueListening.map(\.serverUpdatedAt) == [updatedAt])
    #expect(snapshot.recentBooks.map(\.serverUpdatedAt) == [updatedAt])
    #expect(snapshot.recentEpisodes.map(\.serverUpdatedAt) == [updatedAt])
  }

  @Test("progress past the duration is clamped so the wire validator keeps the row")
  func progressIsClampedToDuration() {
    let book = HomeItem(
      serverItemId: "book", title: "Gilead", author: nil, category: .audiobook, durationSeconds: 60,
      progressSeconds: 60.4, isFinished: false, addedAt: nil, isDownloaded: false)

    let snapshot = CompanionCatalogueBuilder.build(
      CompanionCatalogueInput(
        accountIdentity: Self.identity, continueListening: [book], recentBooks: [],
        recentEpisodes: [], downloads: [], nativeDownloads: []))

    #expect(snapshot.continueListening.map(\.progressSeconds) == [60])
  }

  private static let identity = AccountIdentity(
    id: 12, clientUUID: "client", serverIdentityFingerprint: "server-fingerprint")

  private static func item(
    id: String,
    title: String,
    author: String? = nil,
    category: ItemMediaCategory,
    episodeID: String? = nil,
    episodeTitle: String? = nil,
    progress: Double = 0,
    downloaded: Bool = false
  ) -> HomeItem {
    HomeItem(
      serverItemId: id,
      title: title,
      author: author,
      category: category,
      durationSeconds: 1_000,
      progressSeconds: progress,
      isFinished: false,
      addedAt: nil,
      isDownloaded: downloaded,
      episodeID: episodeID,
      episodeTitle: episodeTitle,
      audioDownloaded: downloaded)
  }

  private static func episode(
    itemID: String,
    episodeID: String,
    title: String,
    date: TimeInterval = 100
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID,
      showTitle: "Show",
      showAuthor: nil,
      episodeID: episodeID,
      title: title,
      subtitle: nil,
      publishedAt: Date(timeIntervalSince1970: date),
      durationSeconds: 1_000)
  }
}
