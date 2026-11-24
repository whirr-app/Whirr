import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

@Suite("Followed show artwork warm pass", .timeLimit(.minutes(1)))
@MainActor
struct FollowedShowArtworkWarmPassTests {
  @Test("snapshot diff selects a new show and changed artwork, but not an unchanged show")
  func snapshotDiff() throws {
    var policy = FollowedShowArtworkWarmPass.Policy()
    let unchanged = try #require(Self.show(id: "rss:1", artwork: "one.jpg"))
    let changed = try #require(Self.show(id: "rss:2", artwork: "old.jpg"))
    let changedAgain = try #require(Self.show(id: "rss:2", artwork: "new.jpg"))
    let first = NativePodcastShowsSnapshot(mode: .alphabetical, shows: [unchanged, changed])
    let second = NativePodcastShowsSnapshot(
      mode: .alphabetical, shows: [unchanged, changedAgain])

    #expect(policy.candidates(from: first).map(\.itemID) == ["rss:1", "rss:2"])
    #expect(policy.candidates(from: second).map(\.itemID) == ["rss:2"])
  }

  @Test("a constrained network defers work until the constraint clears")
  func constrainedNetworkSkips() async throws {
    let provider = WarmArtworkProvider()
    let network = FakeNetworkConditions(isConstrainedOrCellular: true)
    let pass = Self.makePass(provider: provider, network: network)
    let show = try #require(Self.show(id: "rss:1", artwork: "one.jpg"))

    _ = await awaitCondition("the pass observes the network", until: { network.subscriberCount > 0 })
    pass.receive(.init(mode: .alphabetical, shows: [show]))
    await Task.yield()
    #expect(await provider.fetchCount == 0)

    network.simulateChange(isConstrainedOrCellular: false)
    _ = await awaitCondition("unconstrained warm fetch", until: { await provider.fetchCount == 1 })
    #expect(await provider.fetchCount == 1)
  }

  @Test("background suspends work and foreground resumes it")
  func backgroundSuspendsAndForegroundResumes() async throws {
    let provider = WarmArtworkProvider()
    let lifecycle = FakeAppLifecycle()
    let pass = Self.makePass(provider: provider, lifecycle: lifecycle)
    let show = try #require(Self.show(id: "rss:1", artwork: "one.jpg"))

    _ = await awaitCondition(
      "the pass observes the lifecycle", until: { lifecycle.lifecycleSubscriberCount > 0 })
    lifecycle.simulateBackground()
    pass.receive(.init(mode: .alphabetical, shows: [show]))
    await Task.yield()
    #expect(await provider.fetchCount == 0)

    lifecycle.simulateForeground()
    _ = await awaitCondition("foreground warm fetch", until: { await provider.fetchCount == 1 })
    #expect(await provider.fetchCount == 1)
  }

  @Test("a matching evidence record and held bytes require no transfer")
  func matchingEvidenceIsIdempotent() async throws {
    let provider = WarmArtworkProvider()
    let records = FakeCoverPaletteRecordStoring()
    let show = try #require(Self.show(id: "rss:1", artwork: "one.jpg"))
    let source = try #require(show.providerArtworkSource)
    let key = Self.key(for: show, source: source)
    await provider.seed(Data([1]), for: key)
    await records.seed(
      CoverPaletteRecord(
        itemId: show.serverItemId,
        artworkKey: CoverPaletteWriter.recordIdentity(for: key),
        accentHue: nil,
        accentSaturation: nil,
        accentBrightness: nil,
        averageRed: 0.2,
        averageGreen: 0.3,
        averageBlue: 0.4,
        extractedAt: Date()))
    let pass = Self.makePass(provider: provider, records: records)

    pass.receive(.init(mode: .alphabetical, shows: [show]))
    _ = await awaitCondition("idempotent record read", until: { await records.batchFetchCount == 1 })
    await Task.yield()

    #expect(await provider.fetchCount == 0)
    #expect(await records.batchFetchCount == 1)
  }

  /// The pass keys its rows on the player's scale and revision. Without the revision, a show with
  /// a real revision saves a row the player never reads.
  @Test("the warmed key is the player's card key, under the player's identity")
  func warmedKeyIsThePlayersCardKey() throws {
    var policy = FollowedShowArtworkWarmPass.Policy()
    let show = try #require(
      Self.show(id: "rss:1", artwork: "one.jpg", updatedAt: Date(timeIntervalSince1970: 1_000)))
    let source = try #require(show.providerArtworkSource)
    let candidate = try #require(
      policy.candidates(from: .init(mode: .alphabetical, shows: [show])).first)

    let key = FollowedShowArtworkWarmPass.key(for: candidate)
    let playerKey = ExpandedPlayerView.paletteArtworkKey(
      itemID: show.serverItemId, coverClient: WarmArtworkProvider(), source: source, displayScale: 3,
      revision: show.artworkRevision)

    #expect(show.artworkRevision != .unversioned)
    #expect(key == CoverPaletteSource.cardKey(for: playerKey))
    #expect(
      CoverPaletteWriter.recordIdentity(for: key) == CoverPaletteWriter.recordIdentity(for: playerKey))
  }

  @Test("only one transfer is active while the next candidate waits")
  func transferCapIsOne() async throws {
    let provider = WarmArtworkProvider(blockFetch: true)
    let pass = Self.makePass(provider: provider)
    let first = try #require(Self.show(id: "rss:1", artwork: "one.jpg"))
    let second = try #require(Self.show(id: "rss:2", artwork: "two.jpg"))

    pass.receive(.init(mode: .alphabetical, shows: [first, second]))
    _ = await awaitCondition("first warm fetch", until: { await provider.fetchCount == 1 })
    await Task.yield()
    #expect(await provider.fetchCount == 1)

    await provider.releaseFetch()
    _ = await awaitCondition("second warm fetch", until: { await provider.fetchCount == 2 })
    #expect(await provider.fetchCount == 2)
  }

  private static func makePass(
    provider: WarmArtworkProvider,
    records: FakeCoverPaletteRecordStoring = FakeCoverPaletteRecordStoring(),
    network: FakeNetworkConditions = FakeNetworkConditions(),
    lifecycle: FakeAppLifecycle = FakeAppLifecycle()
  ) -> FollowedShowArtworkWarmPass {
    let artwork = ProviderArtworkClient(abs: provider, rss: provider)
    return FollowedShowArtworkWarmPass(
      reading: FakeNativePodcastShowsReading(), artworkClient: artwork,
      service: CoverPaletteService(recordStore: records, coverClient: artwork),
      networkConditions: network, lifecycle: lifecycle)
  }

  private static func key(for show: ItemSummary, source: ArtworkSource) -> ArtworkKey {
    FollowedShowArtworkWarmPass.key(
      for: .init(itemID: show.serverItemId, source: source, revision: show.artworkRevision))
  }

  private static func show(id: String, artwork: String, updatedAt: Date? = nil) -> ItemSummary? {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "podcast", title: id, author: nil, durationSeconds: nil,
      category: .podcast, artworkURL: URL(string: "https://cdn.example.com/\(artwork)"),
      artworkFeedURL: URL(string: "https://feed.example.com/feed.xml"), serverUpdatedAt: updatedAt)
  }
}

private actor WarmArtworkProvider: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource? = nil
  private var bytes: [ArtworkKey: Data] = [:]
  private(set) var fetchCount = 0
  private var blockFetches: Bool
  private var fetchContinuation: CheckedContinuation<Void, Never>?

  init(blockFetch: Bool = false) {
    blockFetches = blockFetch
  }

  func seed(_ data: Data, for key: ArtworkKey) {
    bytes[key] = data
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetchCount += 1
    if blockFetches {
      await withCheckedContinuation { fetchContinuation = $0 }
    }
    let data = bytes[key] ?? Data([1])
    bytes[key] = data
    return CoverImageResult(data: data, contentType: "image/png")
  }

  func data(for key: ArtworkKey) async -> Data? {
    bytes[key]
  }

  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }

  func releaseFetch() {
    fetchContinuation?.resume()
    fetchContinuation = nil
    blockFetches = false
  }
}
