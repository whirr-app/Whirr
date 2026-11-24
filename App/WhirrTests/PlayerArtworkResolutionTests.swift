import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The bar and the page draw and tint from one resolution: the episode's own image, else the
/// followed show's, else the loaded item's.
@MainActor
@Suite("Player artwork resolution")
struct PlayerArtworkResolutionTests {
  private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!

  private static func rss(_ name: String, feedID: Int64 = 7) throws -> ArtworkSource {
    .rss(
      try #require(
        RSSArtworkSource(
          feedID: feedID, artworkURL: URL(string: "https://img.example.test/\(name).jpg")!,
          feedURL: feedURL)))
  }

  private static func key(_ source: ArtworkSource, revision: String = "r1") -> ArtworkKey {
    ArtworkKey(
      source: source, itemID: "rss:7", variant: .highFidelity(displaySize: 380, displayScale: 3),
      revision: ArtworkRevision(revision))
  }

  @Test("the episode's image wins, and the followed show's cover is the fallback")
  func episodeWins() throws {
    let episode = try Self.rss("episode")
    let show = try Self.rss("show")
    let loaded = try Self.rss("loaded")
    let resolution = PlayerArtworkResolution(
      episodeSource: episode, followedShowSource: show, loadedSource: loaded)

    #expect(resolution.source == episode)
    #expect(resolution.showSource == show)
    #expect(resolution.fallbackSource == show)
  }

  @Test("without an episode image the followed show's cover draws, then the loaded item's")
  func showThenLoaded() throws {
    let show = try Self.rss("show")
    let loaded = try Self.rss("loaded")

    let followed = PlayerArtworkResolution(
      episodeSource: nil, followedShowSource: show, loadedSource: loaded)
    #expect(followed.source == show)
    #expect(followed.fallbackSource == nil)

    let onlyLoaded = PlayerArtworkResolution(
      episodeSource: nil, followedShowSource: nil, loadedSource: loaded)
    #expect(onlyLoaded.source == loaded)
    #expect(onlyLoaded.showSource == loaded)
    #expect(onlyLoaded.fallbackSource == nil)

    let nothing = PlayerArtworkResolution(
      episodeSource: nil, followedShowSource: nil, loadedSource: nil)
    #expect(nothing.source == nil)
    #expect(nothing.fallbackSource == nil)
  }

  @Test("an episode image equal to the show's has no fallback")
  func sameImageHasNoFallback() throws {
    let show = try Self.rss("show")
    let resolution = PlayerArtworkResolution(
      episodeSource: show, followedShowSource: show, loadedSource: nil)

    #expect(resolution.source == show)
    #expect(resolution.fallbackSource == nil)
  }

  @Test("the episode's image tints from its own row, and the show's from the item's")
  func paletteIdentityFollowsTheDrawnImage() throws {
    let episode = try Self.rss("episode")
    let show = try Self.rss("show")
    let withEpisode = PlayerArtworkResolution(
      episodeSource: episode, followedShowSource: show, loadedSource: nil)
    let withoutEpisode = PlayerArtworkResolution(
      episodeSource: nil, followedShowSource: show, loadedSource: nil)

    let episodeIdentity = withEpisode.paletteIdentity(for: Self.key(episode), isProvisional: false)
    #expect(episodeIdentity.itemID == "rss:7")
    #expect(episodeIdentity.rowID == "rss-art:7|https://img.example.test/episode.jpg")
    let showIdentity = withoutEpisode.paletteIdentity(for: Self.key(show), isProvisional: true)
    #expect(showIdentity.rowID == "rss:7")
    #expect(showIdentity.isProvisional)
  }

  @Test("the stored image answers before the seed, and a seed answers only for its own episode")
  func observedBeatsSeedAndSeedIsIdentityChecked() throws {
    let episodeURL = URL(string: "https://img.example.test/episode.jpg")!
    let seeded = try Self.rss("seeded")
    let show = try Self.rss("show")
    let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "e1"))
    let seed = PlayerMetadataSeed(
      identity: identity, title: "T", author: nil, episodeArtworkSource: seeded)
    let artwork = PlayerEpisodeArtwork(reading: NoOpRSSEpisodeArtworkReading())

    func resolve(episodeID: String?, seed: PlayerMetadataSeed?) -> PlayerArtworkResolution {
      .resolve(
        itemID: "rss:7", episodeID: episodeID, followedShowSource: show, loadedSource: nil,
        seed: seed, episodeArtwork: artwork)
    }

    #expect(resolve(episodeID: "e1", seed: seed).source == seeded)
    #expect(resolve(episodeID: "e2", seed: seed).source == show)
    #expect(resolve(episodeID: "e1", seed: nil).source == show)

    artwork.track(itemID: "rss:7", episodeID: "e1")
    artwork.apply(episodeURL, for: .init(itemID: "rss:7", episodeID: "e1"))
    let observed = resolve(episodeID: "e1", seed: seed)
    #expect(
      observed.source
        == makeEpisodeArtworkSource(
          itemID: "rss:7", episodeArtworkURL: episodeURL, artworkFeedURL: Self.feedURL))
    #expect(observed.fallbackSource == show)
  }
}
