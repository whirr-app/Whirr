import ABSApi
import Foundation
import Persistence
import Testing
import UIKit

@testable import Whirr

@Suite("Podcasts root arrival warm-up", .timeLimit(.minutes(1)))
@MainActor
struct PodcastsRootArrivalWarmupTests {
  @Test("the warm-up picks the root's curated preview, in the root's order")
  func previewMatchesRootCuratedPreview() {
    let server = (1...10).map { Self.show(id: "server-\($0)", title: "Show \($0)") }

    let preview = PodcastsRootArrivalWarming.previewShows(
      nativeShows: [], nativeMode: .alphabetical,
      serverShows: server, serverMode: .alphabetical,
      nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true)

    #expect(
      preview.map(\.serverItemId)
        == PodcastsViewPresentation.showsSectionShows(
          nativeShows: [], nativeMode: .alphabetical,
          serverShows: server, serverMode: .alphabetical,
          nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: true,
          limit: PodcastsViewPresentation.previewLimit
        ).map(\.serverItemId))
    #expect(preview.count == PodcastsViewPresentation.previewLimit)
  }

  @Test("an excluded server library contributes nothing to warm")
  func excludedServerLibraryIsNotWarmed() {
    let preview = PodcastsRootArrivalWarming.previewShows(
      nativeShows: [], nativeMode: .alphabetical,
      serverShows: [Self.show(id: "server-1")], serverMode: .alphabetical,
      nativeSubscriptionsEnabled: true, hasIncludedPodcastLibrary: false)

    #expect(preview.isEmpty)
  }

  @Test("warming leaves each tile's first-frame cover in the prepared cache")
  func warmFillsPreparedCacheAtTheTileKey() async {
    let fixtures = EditorialWashTestFixtures()
    let cache = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: ImmediateArtworkDecoder(image: image))
    let client = ArrivalArtworkProvider(scope: fixtures.accountScope)
    let show = Self.show(id: fixtures.itemID)

    await PodcastsRootArrivalWarming.warm(
      [show], displayScale: 3, client: client, service: fixtures.service(),
      pipeline: pipeline)

    let tileKey = CoverImageView.artworkKey(
      itemID: show.serverItemId, client: client, source: show.providerArtworkSource,
      displaySize: PodcastsView.cardSize, displayScale: 3, role: .homeCard,
      revision: show.artworkRevision)
    #expect(cache.image(for: tileKey) === image)
  }

  @Test("warming leaves each tile's stored wash in service memory for a first-frame seed")
  func warmFillsCoordinatorMemory() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let service = fixtures.service()
    let cache = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: ImmediateArtworkDecoder(image: image))
    let show = Self.show(id: fixtures.itemID)

    await PodcastsRootArrivalWarming.warm(
      [show], displayScale: 3,
      client: ArrivalArtworkProvider(scope: fixtures.accountScope),
      service: service, pipeline: pipeline)

    let provider = HomeWashProvider(
      service: service, displaySize: PodcastsView.cardSize, displayScale: 3)
    provider.seedCachedWashes([show.washSubject])
    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
  }

  @Test("a followed show with no artwork source is skipped rather than fetched as generated art")
  func sourcelessFollowedShowIsSkipped() async {
    let fixtures = EditorialWashTestFixtures()
    let cache = PreparedArtworkCache(totalCostLimit: 10_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: ImmediateArtworkDecoder(image: image))
    let client = ArrivalArtworkProvider(scope: fixtures.accountScope)

    await PodcastsRootArrivalWarming.warm(
      [Self.show(id: "rss:7")], displayScale: 3, client: client,
      service: fixtures.service(), pipeline: pipeline)

    #expect(await client.fetchCount == 0)
  }

  private static func show(id: String, title: String? = nil) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "podcast", title: title ?? "Show \(id)", author: "Publisher",
      durationSeconds: nil, category: .podcast)
  }
}

private actor ArrivalArtworkProvider: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource?
  private(set) var fetchCount = 0

  init(scope: ArtworkAccountScope) {
    defaultSource = .audiobookshelf(scope)
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetchCount += 1
    return CoverImageResult(data: Data([1]), contentType: "image/png")
  }

  func data(for key: ArtworkKey) async -> Data? { nil }

  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }
}

private struct ImmediateArtworkDecoder: CoverImageDecoding {
  let image: UIImage

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    .image(image)
  }
}
