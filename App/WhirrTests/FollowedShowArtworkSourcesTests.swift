import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

@MainActor
struct FollowedShowArtworkSourcesTests {
  @Test("a followed-show snapshot primes its RSS artwork source")
  func snapshotPrimesSource() throws {
    let resolver = FollowedShowArtworkSources(reading: NoOpNativePodcastShowsReading())
    let show = try #require(Self.show(artworkURL: "https://cdn.example.com/first.jpg"))

    resolver.apply(NativePodcastShowsSnapshot(mode: .alphabetical, shows: [show]))

    #expect(resolver.source(for: show.serverItemId) == show.providerArtworkSource)
  }

  /// The new source is a different identity, so it cannot be answered with the old colour.
  @Test("a changed artwork URL re-keys the show and invokes the palette owner hook")
  func changedArtworkDropsOwnerPaletteEntry() async throws {
    var changedItemIDs: [String] = []
    let samples = CoverPaletteSamples(
      average: CoverRGBA(red: 0.2, green: 0.3, blue: 0.4),
      dominant: [CoverRGBA(red: 0.2, green: 0.3, blue: 0.4)])
    let paletteService = CoverPaletteService(
      extraction: .init(samples: { _ in samples }))
    let resolver = FollowedShowArtworkSources(
      reading: NoOpNativePodcastShowsReading(),
      onSourceChanged: { itemID in
        changedItemIDs.append(itemID)
        paletteService.sourceChanged(for: itemID)
      })
    let first = try #require(Self.show(artworkURL: "https://cdn.example.com/first.jpg"))
    let second = try #require(Self.show(artworkURL: "https://cdn.example.com/second.jpg"))

    func identity(_ show: ItemSummary) throws -> CoverPaletteIdentity {
      CoverPaletteIdentity(
        accountScope: try #require(show.providerArtworkSource).cacheScope,
        itemID: show.serverItemId, revision: .unversioned)
    }

    resolver.apply(NativePodcastShowsSnapshot(mode: .alphabetical, shows: [first]))
    await paletteService.show(try identity(first), bytes: .init(cached: { Data([1]) }, awaitArrival: {}))
    #expect(paletteService.palette(forItem: first.serverItemId) != nil)
    changedItemIDs.removeAll()
    resolver.apply(NativePodcastShowsSnapshot(mode: .alphabetical, shows: [second]))

    #expect(resolver.source(for: second.serverItemId) == second.providerArtworkSource)
    #expect(changedItemIDs == [second.serverItemId])
    #expect(paletteService.palette(for: try identity(second)) == nil)
  }

  @Test("server-owned items have no followed-show artwork source")
  func serverItemAnswersNil() {
    let resolver = FollowedShowArtworkSources(reading: NoOpNativePodcastShowsReading())
    let serverItem = ItemSummary(
      serverItemId: "server-item", mediaKind: "podcast", title: "Server show", author: nil,
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://cdn.example.com/server.jpg"),
      artworkFeedURL: URL(string: "https://cdn.example.com/server.xml"))

    resolver.apply(NativePodcastShowsSnapshot(mode: .alphabetical, shows: [serverItem]))

    #expect(resolver.source(for: serverItem.serverItemId) == nil)
  }

  @Test("player and warm-pass keys share the provider artwork identity")
  func playerAndWarmPassRecordIdentitiesMatch() throws {
    let resolver = FollowedShowArtworkSources(reading: NoOpNativePodcastShowsReading())
    let show = try #require(Self.show(artworkURL: "https://cdn.example.com/show.jpg"))
    resolver.apply(NativePodcastShowsSnapshot(mode: .alphabetical, shows: [show]))
    let source = try #require(resolver.source(for: show.serverItemId))
    let server = try ABSServerConfig(url: URL(string: "https://server.example.com")!)
    let coverClient = CoverImageClient(server: server)

    let playerKey = CoverPaletteService.artworkKey(
      itemID: show.serverItemId, coverClient: coverClient, source: source,
      displaySize: 64, displayScale: 2, role: .libraryThumbnail, revision: .unversioned)
    let warmPassKey = CoverPaletteService.artworkKey(
      itemID: show.serverItemId, coverClient: coverClient,
      source: show.providerArtworkSource,
      displaySize: 140, displayScale: 2, role: .homeCard, revision: .unversioned)

    #expect(
      CoverPaletteWriter.recordIdentity(for: playerKey)
        == CoverPaletteWriter.recordIdentity(for: warmPassKey))
  }

  private static func show(artworkURL: String) -> ItemSummary? {
    ItemSummary.fixture(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Followed show", author: "Author",
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: artworkURL),
      artworkFeedURL: URL(string: "https://cdn.example.com/feed.xml"))
  }
}
