import ABSApi
import AppModel
import Foundation
import Persistence
import Testing
import WidgetProtocol

@testable import Whirr

@Suite("Widget snapshot assembly")
struct WidgetSnapshotAssemblyTests {
  @Test("a book row draws its title, author, progress and remaining time, and asks for its cover")
  func bookRow() throws {
    let updated = Date(timeIntervalSince1970: 1_700_000_000)
    let assembly = Self.assembly(absContinue: [
      Self.book("book-a", title: "Book A", progress: 30, duration: 120, updatedAt: updated)
    ])

    let publication = try #require(assembly.makePublication())
    let item = try #require(publication.snapshot.continueListening.first)
    #expect(item.kind == .book)
    #expect(item.title == "Book A")
    #expect(item.subtitle == "Author")
    #expect(item.progressFraction == 0.25)
    #expect(item.remainingSeconds == 90)
    #expect(item.isDownloaded == false)
    // No cover is on disk yet, so the row names none.
    #expect(item.coverFileName == nil)
    let request = try #require(publication.coverRequests.first)
    #expect(request.key.source == Self.absSource)
    #expect(request.key.itemID == "book-a")
    #expect(request.key.revision == ArtworkRevision(serverUpdatedAt: updated))
    #expect(request.key.variant == .homeCard(pixelWidth: 420))
    #expect(publication.selections[item.token]?.itemID == "book-a")
  }

  @Test("stats reach the snapshot as given, and their absence leaves the field empty")
  func statsPassThrough() throws {
    let stats = try WidgetStats(
      days: [try WidgetStats.Day(date: "2026-03-10", seconds: 600)], streakDaysBeforeWindow: 2,
      totalSeconds: 9_000, fetchedAt: Date(timeIntervalSince1970: 5))
    var assembly = Self.assembly()
    #expect(try #require(assembly.makePublication()).snapshot.stats == nil)

    assembly.stats = stats
    #expect(try #require(assembly.makePublication()).snapshot.stats == stats)
  }

  @Test("a row names its cover once the exported file exists")
  func exportedCoverIsNamed() throws {
    let first = try #require(Self.assembly(absContinue: [Self.book("book-a")]).makePublication())
    let fileName = try #require(first.coverRequests.first?.fileName)

    var assembly = Self.assembly(absContinue: [Self.book("book-a")])
    assembly.exportedCovers = [fileName]
    let item = try #require(assembly.makePublication()?.snapshot.continueListening.first)

    #expect(item.coverFileName == fileName)
  }

  @Test("a server episode draws the episode title over its show")
  func serverEpisodeRow() throws {
    let episode = HomeItem(
      serverItemId: "show-a", title: "Show A", author: "Host", category: .podcast,
      durationSeconds: 100, progressSeconds: 0, isFinished: false, addedAt: nil, isDownloaded: true,
      episodeID: "episode-1", episodeTitle: "Episode One")

    let item = try #require(
      Self.assembly(absContinue: [episode]).makePublication()?.snapshot.continueListening.first)

    #expect(item.kind == .serverEpisode)
    #expect(item.title == "Episode One")
    #expect(item.subtitle == "Show A")
    #expect(item.isDownloaded)
  }

  @Test("RSS rows appear only while native subscriptions are enabled, with their own artwork")
  func rssRowsFollowTheNativePreference() throws {
    let feedArtwork = try #require(URL(string: "https://feeds.example.com/art.jpg"))
    let feedURL = try #require(URL(string: "https://feeds.example.com/feed.xml"))
    let rss = HomeItem(
      serverItemId: "rss:7", title: "Feed Show", author: nil, category: .podcast,
      durationSeconds: 60, progressSeconds: 6, isFinished: false, addedAt: nil, isDownloaded: false,
      episodeID: "guid-1", episodeTitle: "Feed Episode", artworkURL: feedArtwork,
      artworkFeedURL: feedURL)

    var disabled = Self.assembly(nativeContinue: [rss])
    disabled.nativeEnabled = false
    #expect(try #require(disabled.makePublication()).snapshot.continueListening.isEmpty)

    var enabled = Self.assembly(nativeContinue: [rss])
    enabled.nativeEnabled = true
    let publication = try #require(enabled.makePublication())
    let item = try #require(publication.snapshot.continueListening.first)
    #expect(item.kind == .feedEpisode)
    #expect(item.title == "Feed Episode")
    let request = try #require(publication.coverRequests.first)
    guard case .rss = request.key.source else {
      Issue.record("an RSS row must draw its feed's artwork, not a server cover")
      return
    }
  }

  @Test("an RSS row with no declared artwork asks for no cover")
  func rssRowWithoutArtworkHasNoCover() throws {
    let rss = HomeItem(
      serverItemId: "rss:7", title: "Feed Show", author: nil, category: .podcast,
      durationSeconds: 60, progressSeconds: 6, isFinished: false, addedAt: nil, isDownloaded: false,
      episodeID: "guid-1", episodeTitle: "Feed Episode")
    var assembly = Self.assembly(nativeContinue: [rss])
    assembly.nativeEnabled = true

    let publication = try #require(assembly.makePublication())

    #expect(publication.snapshot.continueListening.count == 1)
    #expect(publication.coverRequests.isEmpty)
  }

  @Test("the bookmark's row on the shelf is marked current and keeps its cover revision")
  func bookmarkOnTheShelfKeepsItsRow() throws {
    let updated = Date(timeIntervalSince1970: 1_700_000_000)
    var assembly = Self.assembly(absContinue: [
      Self.book("book-a", updatedAt: updated), Self.book("book-b"),
    ])
    assembly.bookmark = Self.bookmark("book-b")
    assembly.isPlaying = true

    let publication = try #require(assembly.makePublication())
    let shelf = publication.snapshot.continueListening
    #expect(shelf.map(\.title) == ["Book book-a", "Book book-b"])
    let nowPlaying = try #require(publication.snapshot.nowPlaying)
    #expect(nowPlaying.isPlaying)
    #expect(nowPlaying.token == shelf[1].token)
    // The shelf row, not the bookmark, supplied the cover: it carries the server revision.
    #expect(
      publication.coverRequests.first { $0.key.itemID == "book-a" }?.key.revision
        == ArtworkRevision(serverUpdatedAt: updated))
    #expect(publication.coverRequests.first { $0.key.itemID == "book-b" }?.key.revision != .unversioned)
  }

  @Test("a bookmark missing from the shelf leads it, and the shelf keeps its limit")
  func bookmarkMissingFromTheShelfLeads() throws {
    var assembly = Self.assembly(absContinue: (1...4).map { Self.book("book-\($0)") })
    assembly.bookmark = Self.bookmark("new-book")

    let publication = try #require(assembly.makePublication())
    let shelf = publication.snapshot.continueListening

    #expect(shelf.count == WidgetSnapshotLimits.maxItemsPerShelf)
    #expect(shelf.first?.title == "Bookmarked new-book")
    #expect(publication.snapshot.nowPlaying?.token == shelf.first?.token)
    #expect(publication.selections[try #require(shelf.first?.token)]?.itemID == "new-book")
  }

  @Test("a finished bookmark is not added, and a loaded title off every shelf has no token")
  func loadedTitleOffTheShelf() throws {
    var assembly = Self.assembly(absContinue: [Self.book("book-a")])
    assembly.bookmark = PlaybackBookmark(
      serverItemId: "elsewhere", title: "Elsewhere", author: nil, durationSeconds: 10,
      positionSeconds: 10, isFinished: true)
    assembly.loaded = CompanionSelection(source: try #require(PodcastSourceIdentity(itemId: "elsewhere")))
    assembly.isPlaying = true

    let publication = try #require(assembly.makePublication())

    #expect(publication.snapshot.continueListening.map(\.title) == ["Book book-a"])
    #expect(publication.snapshot.nowPlaying?.token == nil)
    #expect(publication.snapshot.nowPlaying?.isPlaying == true)
  }

  @Test("latest episodes come from the merged shelf as episode rows")
  func latestEpisodes() throws {
    let episode = HomePodcastEpisode(
      itemID: "show-a", showTitle: "Show A", showAuthor: "Host", episodeID: "e1", title: "New One",
      subtitle: nil, publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 300)
    var assembly = Self.assembly()
    assembly.absLatest = HomeLatestPodcastEpisodesSnapshot(all: [episode], nativePreferred: [episode])

    let item = try #require(assembly.makePublication()?.snapshot.latestEpisodes.first)

    #expect(item.kind == .serverEpisode)
    #expect(item.title == "New One")
    #expect(item.subtitle == "Show A")
    #expect(item.remainingSeconds == 300)
  }

  @Test("no server identifier reaches the snapshot file")
  func tokensHideServerIdentifiers() throws {
    // Titles that do not repeat the ID, so only an identifier could put it in the file.
    var assembly = Self.assembly(absContinue: [Self.book("li_secret-server-id", title: "Book A")])
    assembly.bookmark = PlaybackBookmark(
      serverItemId: "li_secret-server-id", title: "Book A", author: "Author", durationSeconds: 100,
      positionSeconds: 10, isFinished: false)
    assembly.loaded = CompanionSelection(
      source: try #require(PodcastSourceIdentity(itemId: "li_secret-server-id")))
    let publication = try #require(assembly.makePublication())

    let encoded = try WidgetSnapshotCodec.encode(publication.snapshot)

    #expect(String(decoding: encoded, as: UTF8.self).contains("li_secret-server-id") == false)
    #expect(publication.selections.values.contains { $0.itemID == "li_secret-server-id" })
  }

  @Test("tokens are stable for one salt and differ across salts")
  func tokenStability() throws {
    let selection = CompanionSelection(source: try #require(PodcastSourceIdentity(itemId: "book-a")))
    let token = WidgetSnapshotAssembly.token(for: selection, salt: "one")

    #expect(token == WidgetSnapshotAssembly.token(for: selection, salt: "one"))
    #expect(token != WidgetSnapshotAssembly.token(for: selection, salt: "two"))
  }

  @Test("drawn text loses control characters, URL and path shapes, and anything over the limit")
  func drawableText() {
    #expect(WidgetSnapshotAssembly.drawableText("  Line\none\t ") == "Line one")
    #expect(WidgetSnapshotAssembly.drawableText("https://example.com/book") == nil)
    #expect(WidgetSnapshotAssembly.drawableText("/var/mobile/file") == nil)
    #expect(WidgetSnapshotAssembly.drawableText("   ") == nil)
    let long = String(repeating: "é", count: 400)
    let cut = WidgetSnapshotAssembly.drawableText(long)
    #expect((cut?.utf8.count ?? 0) <= WidgetSnapshotLimits.maxTextBytes)
    #expect(cut?.isEmpty == false)
  }

  @Test("a row whose title cannot be drawn is dropped, not the publication")
  func undrawableTitleDropsTheRow() throws {
    let assembly = Self.assembly(absContinue: [
      Self.book("book-a", title: "https://example.com"), Self.book("book-b"),
    ])

    let publication = try #require(assembly.makePublication())

    #expect(publication.snapshot.continueListening.map(\.title) == ["Book book-b"])
  }

  static let absSource = ArtworkSource.audiobookshelf(ArtworkAccountScope("abs-scope"))

  static func assembly(
    absContinue: [HomeItem] = [], nativeContinue: [HomeItem] = []
  ) -> WidgetSnapshotAssembly {
    WidgetSnapshotAssembly(
      accountStamp: try! WidgetAccountStamp(
        accountIdentityHash: String(repeating: "a", count: 64),
        serverIdentityHash: String(repeating: "b", count: 64)),
      tokenSalt: "salt", nativeEnabled: false, absContinue: absContinue,
      nativeContinue: nativeContinue, absLatest: nil, nativeLatest: [], bookmark: nil, loaded: nil,
      isPlaying: false, skipBackSeconds: 15, generatedAt: Date(timeIntervalSince1970: 1),
      absArtworkSource: absSource, coverPixelWidth: 420, exportedCovers: [])
  }

  static func book(
    _ id: String, title: String? = nil, progress: Double = 10, duration: Double = 100,
    updatedAt: Date? = nil
  ) -> HomeItem {
    HomeItem(
      serverItemId: id, title: title ?? "Book \(id)", author: "Author", category: .audiobook,
      durationSeconds: duration, progressSeconds: progress, isFinished: false, addedAt: nil,
      isDownloaded: false, serverUpdatedAt: updatedAt ?? Date(timeIntervalSince1970: 1_600_000_000))
  }

  static func bookmark(_ id: String) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: id, title: "Bookmarked \(id)", author: "Author", durationSeconds: 100,
      positionSeconds: 10, isFinished: false)
  }
}
