import ABSApi
import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// An RSS episode's own cover is addressed under its show's `rss:<feedID>` identity and feed URL,
/// and a row with no episode image of its own keeps drawing the show's.
@Suite("Episode artwork sources")
struct ArtworkSourcePresentationEpisodeTests {
  private static let showURL = URL(string: "https://images.example.test/show.jpg")!
  private static let episodeURL = URL(string: "https://images.example.test/episode-1.jpg")!
  private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
  private static let itemID = "rss:7"

  private static func source(_ url: URL, feedID: Int64 = 7) throws -> ArtworkSource {
    .rss(try #require(RSSArtworkSource(feedID: feedID, artworkURL: url, feedURL: feedURL)))
  }

  @Test("the helper keys the episode URL under the show's feed identity and feed URL")
  func helperUsesTheShowsFeedIdentity() throws {
    #expect(
      makeEpisodeArtworkSource(
        itemID: Self.itemID, episodeArtworkURL: Self.episodeURL, artworkFeedURL: Self.feedURL)
        == (try Self.source(Self.episodeURL)))
    #expect(
      makeEpisodeArtworkSource(
        itemID: Self.itemID, episodeArtworkURL: Self.episodeURL, artworkFeedURL: Self.feedURL)
        != (try Self.source(Self.showURL)))
  }

  @Test("the helper has no source without an episode image, a feed URL or an RSS item")
  func helperNeedsAnEpisodeImageAndAnRSSItem() {
    #expect(
      makeEpisodeArtworkSource(
        itemID: Self.itemID, episodeArtworkURL: nil, artworkFeedURL: Self.feedURL) == nil)
    #expect(
      makeEpisodeArtworkSource(
        itemID: Self.itemID, episodeArtworkURL: Self.episodeURL, artworkFeedURL: nil) == nil)
    #expect(
      makeEpisodeArtworkSource(
        itemID: "li_server", episodeArtworkURL: Self.episodeURL, artworkFeedURL: Self.feedURL)
        == nil)
  }

  @Test("the episode card draws its own image, the show's when it has none")
  func cardEpisodeSourceFallsBackToTheShow() throws {
    func card(episodeArtworkURL: URL?) -> PodcastEpisodeCardPresentation {
      PodcastEpisodeCardPresentation(
        context: PodcastEpisodeContext(
          episode: PodcastEpisodeSummary(
            id: "e1", title: "Episode", subtitle: nil, episodeDescription: nil,
            seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 1_800,
            sizeBytes: nil, publishedAt: nil, progressSeconds: 0, isPlayed: false,
            isFinished: false, downloadStatus: .notDownloaded, isAvailableOnServer: true),
          showTitle: "Show", showAuthor: "Creator", artworkURL: Self.showURL,
          artworkFeedURL: Self.feedURL, episodeArtworkURL: episodeArtworkURL))
    }

    let withArt = card(episodeArtworkURL: Self.episodeURL)

    #expect(withArt.episodeArtworkURL == Self.episodeURL)
    #expect(withArt.episodeArtworkSource(for: Self.itemID) == (try Self.source(Self.episodeURL)))
    #expect(withArt.providerArtworkSource(for: Self.itemID) == (try Self.source(Self.showURL)))
    #expect(
      card(episodeArtworkURL: nil).episodeArtworkSource(for: Self.itemID)
        == (try Self.source(Self.showURL)))
  }

  @Test("an Up Next episode row carries its episode image and keeps the show's as the fallback")
  func queueRowEpisodeSource() throws {
    func row(episodeArtworkURL: URL?) throws -> ListeningQueueViewPresentation.Row {
      let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "e1"))
      let rows = ListeningQueueViewPresentation.rows([
        ListeningQueueItem(
          id: 1, position: 0, identity: identity,
          primaryTitle: "Episode", secondaryTitle: "Show", category: .podcast,
          isTombstone: false, artworkURL: Self.showURL, artworkFeedURL: Self.feedURL,
          episodeArtworkURL: episodeArtworkURL)
      ])
      return try #require(rows.first)
    }
    let withArt = try row(episodeArtworkURL: Self.episodeURL)

    #expect(withArt.episodeArtworkURL == Self.episodeURL)
    #expect(withArt.episodeArtworkSource == (try Self.source(Self.episodeURL)))
    #expect(withArt.providerArtworkSource == (try Self.source(Self.showURL)))
    #expect(try row(episodeArtworkURL: nil).episodeArtworkSource == (try Self.source(Self.showURL)))
  }

  @Test("opening the player from an Up Next row seeds its episode image and the show's cover")
  @MainActor
  func queueRowSeedsTheEpisodeImage() throws {
    func seed(episodeArtworkURL: URL?) throws -> PlayerMetadataSeed {
      let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "e1"))
      let row = try #require(
        ListeningQueueViewPresentation.rows([
          ListeningQueueItem(
            id: 1, position: 0, identity: identity,
            primaryTitle: "Episode", secondaryTitle: "Show", category: .podcast,
            isTombstone: false, artworkURL: Self.showURL, artworkFeedURL: Self.feedURL,
            episodeArtworkURL: episodeArtworkURL)
        ]).first)
      return ListeningQueueSheetPresentation.playerSeed(for: row)
    }
    let withArt = try seed(episodeArtworkURL: Self.episodeURL)

    #expect(withArt.identity.itemID == Self.itemID)
    #expect(withArt.episodeArtworkSource == (try Self.source(Self.episodeURL)))
    #expect(withArt.artworkSource == (try Self.source(Self.showURL)))
    #expect(
      PlayerArtworkResolution.seededEpisodeSource(withArt, itemID: Self.itemID, episodeID: "e1")
        == (try Self.source(Self.episodeURL)))
    #expect(
      PlayerArtworkResolution.seededEpisodeSource(withArt, itemID: Self.itemID, episodeID: "e2")
        == nil)
    // No episode image: the row's own fallback is the show's cover, which the resolution then
    // treats as the show and so draws without a fallback.
    #expect(
      try seed(episodeArtworkURL: nil).episodeArtworkSource == (try Self.source(Self.showURL)))
  }
}
