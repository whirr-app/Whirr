import ABSApi
import AppModel
import DesignSystem
import MediaPlayer
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing
import UIKit

@testable import Whirr

extension NowPlayingMetadataTests {

  // MARK: - Artwork (loaded through the existing CoverImageClient)

  @Test("cover artwork loads through CoverImageClient and is published once fetched")
  func artworkLoadsThroughCoverImageClientAndIsPublished() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let transport = FakeCoverHTTPClient(imageData: onePixelPNGData)
    let coverImageClient = CoverImageClient(server: server, httpClient: transport)

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider, coverImageClient: coverImageClient,
      displayScale: 2)
    await adapter.waitForPendingArtworkForTesting()

    let artwork = sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
    #expect(artwork != nil)
  }

  @Test("switching items cancels the previous artwork request and ignores its stale result")
  func switchingItemsCancelsAndRejectsStaleArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(itemId: "item-a")
    let sink = FakeNowPlayingInfoSink()
    let loader = ControllableNowPlayingArtworkLoader()
    let client = try makeCoverImageClient()
    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      coverImageClient: client, displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) })
    await loader.waitUntilStarted(itemID: "item-a")

    player.state = Self.state(itemId: "item-b")
    player.emit(progressEvent(itemId: "item-b", phase: .playing, currentTime: 10))
    await loader.waitUntilStarted(itemID: "item-b")
    await loader.waitUntilCancelled(itemID: "item-a")

    let staleImage = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    await loader.finish(itemID: "item-a", image: staleImage)
    await loader.finish(itemID: "item-b", image: nil)
    await adapter.waitForPendingArtworkForTesting()

    #expect(adapter.retainedArtworkItemIDForTesting == nil)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
  }

  @Test("switching items replaces rather than accumulates retained artwork")
  func switchingItemsReplacesRetainedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(itemId: "item-a")
    let sink = FakeNowPlayingInfoSink()
    let loader = ControllableNowPlayingArtworkLoader()
    let client = try makeCoverImageClient()
    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      coverImageClient: client, displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) })

    await loader.waitUntilStarted(itemID: "item-a")
    await loader.finish(
      itemID: "item-a",
      image: UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
    await adapter.waitForPendingArtworkForTesting()
    #expect(adapter.retainedArtworkItemIDForTesting == "item-a")

    player.state = Self.state(itemId: "item-b")
    player.emit(progressEvent(itemId: "item-b", phase: .playing, currentTime: 10))
    await loader.waitUntilStarted(itemID: "item-b")
    await loader.finish(
      itemID: "item-b",
      image: UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
    await adapter.waitForPendingArtworkForTesting()

    #expect(adapter.retainedArtworkItemIDForTesting == "item-b")
    #expect(adapter.retainedArtworkCountForTesting == 1)
  }

  @Test("clear cancels pending artwork work and releases retained artwork")
  func clearCancelsAndReleasesArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(itemId: "item-a")
    let loader = ControllableNowPlayingArtworkLoader()
    let adapter = NowPlayingMetadataAdapter(
      sink: FakeNowPlayingInfoSink(), controller: player,
      itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) })
    await loader.waitUntilStarted(itemID: "item-a")

    adapter.clear()
    await loader.waitUntilCancelled(itemID: "item-a")

    #expect(adapter.retainedArtworkCountForTesting == 0)
    #expect(adapter.hasPendingArtworkForTesting == false)
  }

  @Test("no CoverImageClient injected means artwork is simply absent, not a crash")
  func noCoverImageClientMeansNoArtworkKey() {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()

    let adapter = makeAdapter(player: player, sink: sink, itemInfoProvider: itemInfoProvider)

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
    withExtendedLifetime(adapter) {}
  }

  // MARK: - Generated cover fallback

  @Test("an item the server has no cover for still publishes its generated cover as artwork")
  func missingServerCoverPublishesGeneratedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      // A completed fetch that proved the server has no artwork for this item.
      artworkImageLoader: { _, _ in .unavailable })
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    // Sized from the requested high-fidelity width, which marks generated art apart from
    // fetched images.
    #expect(artwork.bounds.size.width > 1)
    #expect(artwork.bounds.size.width == artwork.bounds.size.height)
    #expect(adapter.retainedArtworkItemIDForTesting == "item-1")
  }

  @Test("an RSS item uses generated artwork without invoking the ABS cover client")
  func rssItemNeverFetchesABSArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["rss:1"] = NowPlayingItemInfo(
      title: "Native Episode", author: "Native Show")
    let loader = ControllableNowPlayingArtworkLoader()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) })
    await adapter.waitForPendingArtworkForTesting()

    #expect(await loader.hasStarted(itemID: "rss:1") == false)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    #expect(adapter.retainedArtworkItemIDForTesting == "rss:1")
  }

  @Test("an RSS item with declared artwork routes its provider key into Now Playing")
  func rssItemLoadsDeclaredArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/show.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    itemInfoProvider.infoByItemID["rss:1"] = NowPlayingItemInfo(
      title: "Native Episode", author: "Native Show", artworkSource: .rss(source))
    let fetched = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let keys = NowPlayingArtworkKeyRecorder()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in
        await keys.record(key)
        return .image(fetched)
      })
    await adapter.waitForPendingArtworkForTesting()

    #expect(await keys.values.map(\.source) == [.rss(source)])
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
    #expect(adapter.retainedArtworkItemIDForTesting == "rss:1")
  }

  @Test("an episode image that is gone publishes the show's cover for good, not generated art")
  func unavailableEpisodeArtworkPublishesTheShowCover() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let fixture = try Self.episodeArtworkFixture()
    itemInfoProvider.infoByItemID["rss:1"] = fixture.info
    let showCover = UIGraphicsImageRenderer(size: CGSize(width: 7, height: 7)).image { _ in }
    let keys = NowPlayingArtworkKeyRecorder()
    let episodeSource = fixture.episode

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in
        await keys.record(key)
        return key.source == episodeSource ? .unavailable : .image(showCover)
      })
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(artwork.bounds.size == CGSize(width: 7, height: 7))
    #expect(await keys.values.map(\.source) == [fixture.episode, fixture.show])
    #expect(await keys.values[0].variant == keys.values[1].variant)
    #expect(adapter.retainedArtworkIsProvisionalForTesting == false)
  }

  @Test("an episode image that failed to load publishes the show's cover, still open to a retry")
  func failedEpisodeArtworkPublishesTheShowCoverProvisionally() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let fixture = try Self.episodeArtworkFixture()
    itemInfoProvider.infoByItemID["rss:1"] = fixture.info
    let showCover = UIGraphicsImageRenderer(size: CGSize(width: 7, height: 7)).image { _ in }
    let episodeSource = fixture.episode

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in key.source == episodeSource ? .failed : .image(showCover) })
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(artwork.bounds.size == CGSize(width: 7, height: 7))
    #expect(adapter.retainedArtworkIsProvisionalForTesting)
  }

  @Test("an episode image that loads never asks for the show's cover")
  func loadedEpisodeArtworkDoesNotFetchTheFallback() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let fixture = try Self.episodeArtworkFixture()
    itemInfoProvider.infoByItemID["rss:1"] = fixture.info
    let fetched = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let keys = NowPlayingArtworkKeyRecorder()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in
        await keys.record(key)
        return .image(fetched)
      })
    await adapter.waitForPendingArtworkForTesting()

    #expect(await keys.values.map(\.source) == [fixture.episode])
  }

  @Test("an episode image and its fallback both failing leaves the lock screen bare, as before")
  func episodeAndFallbackBothFailingPublishesNothing() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["rss:1"] = try Self.episodeArtworkFixture().info

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { _, _ in .failed })
    await adapter.waitForPendingArtworkForTesting()

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
    #expect(adapter.retainedArtworkItemIDForTesting == nil)
  }

  @Test("a changed RSS artwork URL reloads, while an unchanged URL does not refetch")
  func artworkURLChangesInvalidateRetainedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(
      phase: .playing, position: 10, itemId: "rss:1", episodeID: "episode-1")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let first = try #require(
      RSSArtworkSource(
        feedID: 1,
        artworkURL: URL(string: "https://img.test/first.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    let second = try #require(
      RSSArtworkSource(
        feedID: 1,
        artworkURL: URL(string: "https://img.test/second.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    itemInfoProvider.infoByItemID["rss:1"] = NowPlayingItemInfo(
      title: "Native Episode", author: "Native Show", artworkSource: .rss(first))
    let fetched = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let keys = NowPlayingArtworkKeyRecorder()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink,
      controller: player,
      itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(),
      displayScale: 2,
      artworkImageLoader: { key, _ in
        await keys.record(key)
        return .image(fetched)
      })
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.source) == [.rss(first)])

    itemInfoProvider.infoByItemID["rss:1"] = NowPlayingItemInfo(
      title: "Native Episode", author: "Native Show", artworkSource: .rss(second))
    player.state = Self.state(
      phase: .paused, position: 10, itemId: "rss:1", episodeID: "episode-1")
    player.emit(
      progressEvent(itemId: "rss:1", phase: .paused, currentTime: 10))
    await waitUntil { await keys.values.count == 2 }
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.source) == [.rss(first), .rss(second)])

    let writesBeforeUnchanged = sink.writeCount
    player.state = Self.state(
      phase: .playing, position: 10, itemId: "rss:1", episodeID: "episode-1")
    player.emit(
      progressEvent(itemId: "rss:1", phase: .playing, currentTime: 10))
    await waitUntil { sink.writeCount > writesBeforeUnchanged }
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.source) == [.rss(first), .rss(second)])
    withExtendedLifetime(adapter) {}
  }

  @Test("a replaced ABS cover reloads under its new revision, while an unchanged one does not")
  func artworkRevisionChangesInvalidateRetainedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let first = ArtworkRevision("1790000000000")
    let second = ArtworkRevision("1790000000123")
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(
      title: "Gilead", author: "Robinson", artworkRevision: first)
    let fetched = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let keys = NowPlayingArtworkKeyRecorder()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink,
      controller: player,
      itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(),
      displayScale: 2,
      artworkImageLoader: { key, _ in
        await keys.record(key)
        return .image(fetched)
      })
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.revision) == [first])

    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(
      title: "Gilead", author: "Robinson", artworkRevision: second)
    player.state = Self.state(phase: .paused, position: 10)
    player.emit(progressEvent(phase: .paused, currentTime: 10))
    await waitUntil { await keys.values.count == 2 }
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.revision) == [first, second])

    let writesBeforeUnchanged = sink.writeCount
    player.state = Self.state(phase: .playing, position: 10)
    player.emit(progressEvent(phase: .playing, currentTime: 10))
    await waitUntil { sink.writeCount > writesBeforeUnchanged }
    await adapter.waitForPendingArtworkForTesting()
    #expect(await keys.values.map(\.revision) == [first, second])
    withExtendedLifetime(adapter) {}
  }

  @Test("no cover and no title leaves artwork absent rather than drawing an empty tile")
  func missingServerCoverWithoutTitlePublishesNoArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: FakeNowPlayingItemInfoProviding(),
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { _, _ in .unavailable })
    await adapter.waitForPendingArtworkForTesting()

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
    #expect(adapter.retainedArtworkItemIDForTesting == nil)
  }

  @Test("a real server cover still wins over the generated fallback")
  func fetchedCoverTakesPrecedenceOverGeneratedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")
    let fetched = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { _, _ in .image(fetched) })
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(artwork.bounds.size == CGSize(width: 4, height: 4))
  }

  // MARK: - A transport failure is not evidence the item has no cover

  @Test("a failed artwork fetch leaves the lock screen bare rather than promoting generated art")
  func failedArtworkFetchDoesNotPublishGeneratedArtwork() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    // A title is present, so the generated-cover path is available. Only the failed fetch
    // withholds it here.
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { _, _ in .failed })
    await adapter.waitForPendingArtworkForTesting()

    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)
    // Nothing retained is the half that matters: it is what leaves the next boundary free to retry.
    #expect(adapter.retainedArtworkItemIDForTesting == nil)
  }

  @Test("a failed fetch is retried at the next boundary and the recovered cover is published")
  func failedArtworkFetchIsRetriedAtTheNextBoundary() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")
    let loader = ControllableNowPlayingArtworkLoader()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) })

    await loader.waitUntilStarted(itemID: "item-1")
    await loader.clearStarted(itemID: "item-1")
    await loader.finish(itemID: "item-1", outcome: .failed)
    await adapter.waitForPendingArtworkForTesting()
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] == nil)

    // Pausing is a semantic boundary, the same one a listener supplies by reaching for the lock
    // screen. The item gets another attempt without waiting for a new item.
    player.state = Self.state(phase: .paused, position: 10)
    player.emit(progressEvent(phase: .paused, currentTime: 10))
    await loader.waitUntilStarted(itemID: "item-1")

    let recovered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    await loader.finish(itemID: "item-1", outcome: .image(recovered))
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(artwork.bounds.size == CGSize(width: 4, height: 4))
    #expect(adapter.retainedArtworkItemIDForTesting == "item-1")
  }

  // MARK: - A completed "no artwork" answer expires rather than ending the session

  /// A 404 when playback starts is not a durable fact about a new item. The server may not have
  /// attached the cover yet. The generated fallback is published, but the slot stays open.
  @Test("an unavailable fetch publishes generated art without ending the item's chances")
  func unavailableArtworkIsRetriedAfterTheInterval() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")
    let loader = ControllableNowPlayingArtworkLoader()
    let clock = MutableClock()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) },
      now: clock.now)

    await loader.waitUntilStarted(itemID: "item-1")
    await loader.clearStarted(itemID: "item-1")
    await loader.finish(itemID: "item-1", outcome: .unavailable)
    await adapter.waitForPendingArtworkForTesting()

    let generated = try #require(
      sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(adapter.retainedArtworkItemIDForTesting == "item-1")

    // A boundary inside the interval must not spend a request. Nothing about the item has changed,
    // and a listener pausing and resuming twice a minute must not become a 404 every time.
    clock.advance(by: 30)
    let publishedBeforePause = sink.writeCount
    player.state = Self.state(phase: .paused, position: 10)
    player.emit(progressEvent(phase: .paused, currentTime: 10))
    // The adapter republishes from `controller.state` as it drains an event, and drops a snapshot
    // equal to the one published. Moving the player on before this boundary drains erases it: both
    // events would publish the playing snapshot already on the lock screen, dedupe away, and leave
    // the artwork gate unreached. `waitForPendingArtworkForTesting` cannot stand in: the boundary
    // starts no fetch, so it returns a nil task having awaited nothing.
    #expect(
      await awaitCondition(
        "paused boundary published",
        observing: { "writes=\(sink.writeCount)" },
        until: { sink.writeCount > publishedBeforePause }
      ).isObserved)
    await adapter.waitForPendingArtworkForTesting()
    #expect(await loader.hasStarted(itemID: "item-1") == false)
    // And the lock screen still shows what it was given: a provisional retention publishes.
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === generated)

    // Past the interval, the next boundary asks again.
    clock.advance(by: 31)
    player.state = Self.state(phase: .playing, position: 10)
    player.emit(progressEvent(phase: .playing, currentTime: 10))
    await loader.waitUntilStarted(itemID: "item-1")

    // The artwork must not be cleared while the retry is in flight, or the lock screen blinks back
    // to a bare tile on every attempt.
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork === generated)

    let recovered = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    await loader.finish(itemID: "item-1", outcome: .image(recovered))
    await adapter.waitForPendingArtworkForTesting()

    let artwork = try #require(
      sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    #expect(artwork.bounds.size == CGSize(width: 4, height: 4))
  }

  /// The bound that keeps a genuinely coverless item from paying for a request at every pause.
  @Test("a repeatedly unavailable item stops being asked after its attempt cap")
  func unavailableArtworkStopsAtTheAttemptCap() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-1"] = NowPlayingItemInfo(title: "Walden", author: "Thoreau")
    let loader = ControllableNowPlayingArtworkLoader()
    let clock = MutableClock()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) },
      now: clock.now)

    var phase = PlayerPhase.playing
    for attempt in 0..<NowPlayingMetadataAdapter.maximumProvisionalArtworkAttempts {
      await loader.waitUntilStarted(itemID: "item-1")
      await loader.clearStarted(itemID: "item-1")
      await loader.finish(itemID: "item-1", outcome: .unavailable)
      await adapter.waitForPendingArtworkForTesting()
      #expect(adapter.provisionalArtworkAttemptsForTesting == attempt + 1)

      clock.advance(by: 120)
      phase = phase == .playing ? .paused : .playing
      player.state = Self.state(phase: phase, position: 10)
      player.emit(progressEvent(phase: phase, currentTime: 10))
      await adapter.waitForPendingArtworkForTesting()
    }

    // The cap is spent, so this boundary buys nothing however long has passed.
    #expect(await loader.hasStarted(itemID: "item-1") == false)
    #expect(sink.nowPlayingInfo?[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
  }

  /// A different item is a different question: the cap must not follow the listener into the next
  /// book, or one coverless item would poison the rest of the session.
  @Test("the provisional attempt count resets when the item changes")
  func provisionalAttemptsResetOnItemChange() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(phase: .playing, itemId: "item-a")
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    itemInfoProvider.infoByItemID["item-a"] = NowPlayingItemInfo(title: "Walden")
    itemInfoProvider.infoByItemID["item-b"] = NowPlayingItemInfo(title: "Moby-Dick")
    let loader = ControllableNowPlayingArtworkLoader()
    let clock = MutableClock()

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider,
      coverImageClient: try makeCoverImageClient(), displayScale: 2,
      artworkImageLoader: { key, _ in await loader.load(key) },
      now: clock.now)

    await loader.waitUntilStarted(itemID: "item-a")
    await loader.finish(itemID: "item-a", outcome: .unavailable)
    await adapter.waitForPendingArtworkForTesting()
    #expect(adapter.provisionalArtworkAttemptsForTesting == 1)

    player.state = Self.state(phase: .playing, itemId: "item-b")
    player.emit(progressEvent(itemId: "item-b", phase: .playing, currentTime: 10))
    await loader.waitUntilStarted(itemID: "item-b")

    #expect(adapter.provisionalArtworkAttemptsForTesting == 0)
  }
}
