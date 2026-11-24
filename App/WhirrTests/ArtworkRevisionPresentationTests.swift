import ABSApi
import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// An ABS cover is addressed by its item's server `updatedAt`. Every surface that draws one item
/// must name the same revision, or the item's single palette row is re-derived each time a
/// different surface asks for it and a replaced cover shows on one screen and not another.
@Suite("Artwork revision presentation")
struct ArtworkRevisionPresentationTests {
  private static let updatedAt = Date(timeIntervalSince1970: 1_790_000_000.123)
  private static let revision = ArtworkRevision("1790000000123")
  private static let scope = ArtworkAccountScope("account-1")

  @Test("every projection of one item names the same revision")
  func projectionsAgree() {
    let summary = Self.book(serverUpdatedAt: Self.updatedAt)
    let home = HomeItem(
      serverItemId: "book-1", title: "Gilead", author: nil, category: .audiobook,
      durationSeconds: nil, progressSeconds: 0, isFinished: false, addedAt: nil,
      isDownloaded: false, serverUpdatedAt: Self.updatedAt)
    let row = SearchResultRow(
      kind: .book, entityID: "book-1", title: "Gilead", libraryID: "lib",
      serverUpdatedAt: Self.updatedAt)

    #expect(summary.artworkRevision == Self.revision)
    #expect(home.artworkRevision == Self.revision)
    #expect(row.artworkRevision == Self.revision)
    #expect(summary.washSubject.artworkRevision == Self.revision)
    #expect(home.washSubject.artworkRevision == Self.revision)
  }

  @Test("an item the server has not dated stays unversioned")
  func undatedItemIsUnversioned() {
    #expect(Self.book(serverUpdatedAt: nil).artworkRevision == .unversioned)
  }

  @Test("the cover key carries the revision into the cover URL")
  func coverKeyCarriesRevision() throws {
    let client = CoverImageClient(
      server: try ABSServerConfig(url: #require(URL(string: "https://server.example.com"))))
    let key = CoverImageView.artworkKey(
      itemID: "book-1", client: client, source: nil, displaySize: 140, displayScale: 2,
      role: .highFidelity, revision: Self.revision)

    #expect(key.revision == Self.revision)
    let request = try key.coverRequest()
    #expect(request.revision == Self.revision)
  }

  @Test("an episode, its card, and its show's Home shelf all use the show's revision")
  func episodesUseTheShowsRevision() {
    let episodes = ["a", "b"].map { episodeID in
      HomePodcastEpisode(
        itemID: "show-1", showTitle: "Show", showAuthor: nil, episodeID: episodeID,
        title: "Episode \(episodeID)", subtitle: nil, publishedAt: Self.updatedAt, durationSeconds: 60,
        showServerUpdatedAt: Self.updatedAt)
    }

    #expect(episodes.allSatisfy { $0.artworkRevision == Self.revision })
    #expect(episodes[0].washSubject.artworkRevision == Self.revision)
    #expect(
      HomeArtworkPrefetching.revisionsByID(for: .podcastEpisodes(episodes))
        == ["show-1": Self.revision])
  }

  @Test("an RSS episode opens its show with the feed artwork")
  func episodeShowSummaryCarriesFeedArtwork() throws {
    let artwork = try #require(URL(string: "https://cdn.example.com/cover.jpg"))
    let feed = try #require(URL(string: "https://example.com/feed.xml"))
    let episode = HomePodcastEpisode(
      itemID: "rss:7", showTitle: "Show", showAuthor: "Author", episodeID: "ep-1",
      title: "Episode", subtitle: nil, publishedAt: Self.updatedAt, durationSeconds: 60,
      artworkURL: artwork, artworkFeedURL: feed)

    let summary = episode.showSummary
    #expect(summary.serverItemId == "rss:7")
    #expect(summary.mediaKind == "podcast")
    #expect(summary.title == "Show")
    #expect(summary.author == "Author")
    #expect(summary.durationSeconds == nil)
    #expect(summary.artworkURL == artwork)
    #expect(summary.artworkFeedURL == feed)
    #expect(summary.providerArtworkSource == episode.providerArtworkSource)
  }

  @Test("Home shelf revisions are keyed exactly like the shelf's ordered cover IDs")
  func homeShelfRevisionsMatchOrderedIDs() {
    let items = [
      Self.homeItem("one", serverUpdatedAt: Self.updatedAt),
      Self.homeItem("two", serverUpdatedAt: nil),
    ]
    let content = HomeViewPresentation.Section.Content.items(items)

    #expect(
      Set(HomeArtworkPrefetching.revisionsByID(for: content).keys)
        == Set(HomeArtworkPrefetching.orderedIDs(for: content)))
    #expect(
      HomeArtworkPrefetching.revisionsByID(for: content)
        == ["one": Self.revision, "two": .unversioned])
  }

  @Test("search keys an episode row's cover by its show, with the show's revision")
  func searchEpisodeRowsUseTheShowsRevision() {
    let show = SearchResultRow(
      kind: .podcast, entityID: "show-1", title: "Show", libraryID: "lib",
      serverUpdatedAt: Self.updatedAt)
    let episode = SearchResultRow(
      kind: .episode, entityID: "ep-1", parentItemID: "show-1", title: "Episode",
      libraryID: "lib", serverUpdatedAt: Self.updatedAt)
    let author = SearchResultRow(kind: .author, entityID: "author-1", title: "A", libraryID: "lib")
    let sections = [
      SearchSection(kind: .podcast, rows: [show], hasMore: false),
      SearchSection(kind: .episode, rows: [episode], hasMore: false),
      SearchSection(kind: .author, rows: [author], hasMore: false),
    ]

    #expect(SearchViewPresentation.coverRevisionsByID(sections) == ["show-1": Self.revision])
  }

  @Test("a series tile draws its first book's cover, so it carries that book's revision")
  func entityGroupUsesItsCoverItemsRevision() {
    let group = LibraryEntityGroup(
      entity: AuthorSeriesEntity(kind: .series, entityID: "s-1", name: "Series", libraryID: "lib"),
      items: [
        Self.book(id: "first", serverUpdatedAt: Self.updatedAt),
        Self.book(id: "second", serverUpdatedAt: nil),
      ],
      isFiltered: false)

    #expect(group.coverItemID == "first")
    #expect(group.coverRevision == Self.revision)
    #expect([group].coverRevisionsByID == ["first": Self.revision])
  }

  @Test("the item-detail preflight keys by the tapped row's revision; a deep link stays unversioned")
  func detailPreflightUsesTheSeedsRevision() {
    let seed = Self.book(serverUpdatedAt: Self.updatedAt)

    let seeded = LibraryShellPresentation.detailArtworkPreflightKey(
      for: .itemDetail(itemID: "book-1", seed: seed), source: .audiobookshelf(Self.scope),
      displayScale: 2)
    let seedless = LibraryShellPresentation.detailArtworkPreflightKey(
      for: .itemDetail(itemID: "book-1"), source: .audiobookshelf(Self.scope), displayScale: 2)

    #expect(seeded?.revision == Self.revision)
    #expect(seedless?.revision == .unversioned)
    // The preflight exists to join the hero's own request, so the two must be the same key.
    #expect(
      seeded
        == ArtworkKey(
          accountScope: Self.scope, itemID: "book-1", variant: .highFidelity(pixelWidth: 768),
          revision: seed.artworkRevision))
  }

  private static func book(id: String = "book-1", serverUpdatedAt: Date?) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "book", title: "Gilead", author: nil, durationSeconds: nil,
      category: .audiobook, serverUpdatedAt: serverUpdatedAt)
  }

  private static func homeItem(_ id: String, serverUpdatedAt: Date?) -> HomeItem {
    HomeItem(
      serverItemId: id, title: id, author: nil, category: .audiobook, durationSeconds: nil,
      progressSeconds: 0, isFinished: false, addedAt: nil, isDownloaded: false,
      serverUpdatedAt: serverUpdatedAt)
  }
}
