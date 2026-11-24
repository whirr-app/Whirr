import ABSApi
import Foundation
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// Mints a real `PlaybackStreamAuthorization` the only way production can: there is no public
/// initializer, by design (see `SECURITY.md`).
private func makeStreamAuthorization(accessToken: String) async throws -> PlaybackStreamAuthorization {
  let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let store = InMemoryTokenStore()
  try store.save(TokenPair(accessToken: accessToken, refreshToken: "refresh"), for: account)
  // Minting is a pure token-store read that takes no gate permit and sends nothing, so the
  // production client is safe here.
  let client = ABSClient.production(server: server, tokenStore: store)
  return try await client.makePlaybackStreamAuthorization(account: account)
}

/// `StreamConfiguringPlaybackSyncing` is the `PlaybackSyncing` conformance `AppEnvironment` wires,
/// wrapping `PlaybackSessionCoordinator`. Every method it does not specialise must forward its
/// arguments unchanged; a dropped one only shows on device as the server resetting progress.
/// `episodeID` matters most: a tick that never reaches the coordinator cannot match the episode
/// session's foreign key, so nothing is persisted or synced.
@MainActor
@Suite("StreamConfiguringPlaybackSyncing")
struct StreamConfiguringPlaybackSyncingTests {

  private func makeSUT() -> (sut: StreamConfiguringPlaybackSyncing, underlying: FakePlaybackSyncing) {
    let underlying = FakePlaybackSyncing()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: FakeItemFactory(),
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    return (StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine), underlying)
  }

  @Test("a streamed session's Bearer header reaches every configured track resource")
  func startSessionConfiguresTracksWithTheSessionsStreamAuthorization() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let url = URL(string: "https://books.example.test/api/items/item-1/file/101")!
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: url, mimeType: "audio/mpeg", title: nil)
      ],
      chapters: [], source: .streaming,
      streamAuthorization: try await makeStreamAuthorization(accessToken: "tok-1"))
    underlying.stubStartSession(.success(prepared))

    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)
    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 0, rate: 1,
      generation: 1)

    let made = try #require(factory.madeItems.last)
    #expect(made.url == url)
    #expect(factory.madeHeaders.last == ["Authorization": "Bearer tok-1"])
  }

  /// After a promotion the engine must hold the local file resources, or `PlaybackModel`'s
  /// following `.load` would replay the stream it just left.
  @Test("a promotion reconfigures the engine with the downloaded file's URL and no headers")
  func promotionConfiguresTheEngineWithTheLocalTracks() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let streamedURL = URL(string: "https://books.example.test/api/items/item-1/file/101")!
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: streamedURL, mimeType: "audio/mpeg",
          title: nil)
      ],
      chapters: [], source: .streaming,
      streamAuthorization: try await makeStreamAuthorization(accessToken: "tok-1"))
    underlying.stubStartSession(.success(prepared))
    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)

    let localURL = URL(fileURLWithPath: "/tmp/whirr-tests/item-1-track-1.m4b")
    let local = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 42, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: localURL, mimeType: "audio/mp4", title: nil)
      ],
      chapters: [], source: .local, streamAuthorization: nil)
    underlying.stubPromoteStreamingSessionToLocalDownload(local)

    let promoted = await sut.promoteStreamingSessionToLocalDownload(
      itemID: "item-1", episodeID: nil, currentPosition: 42, streamedDuration: nil)
    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 42, rate: 1,
      generation: 2)

    #expect(promoted?.source == .local)
    let made = try #require(factory.madeItems.last)
    #expect(made.url == localURL)
    #expect(factory.madeHeaders.last == [:])
  }

  @Test("a local session's file URLs are configured with no headers at all")
  func startSessionConfiguresLocalTracksWithoutHeaders() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let url = URL(fileURLWithPath: "/tmp/whirr-tests/track-1.m4b")
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: url, mimeType: "audio/mp4", title: nil)
      ],
      chapters: [], source: .local, streamAuthorization: nil)
    underlying.stubStartSession(.success(prepared))

    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)
    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 0, rate: 1,
      generation: 1)

    #expect(factory.madeHeaders.last == [:])
    #expect(factory.madeMIMETypes.last == "audio/mp4")
  }

  /// `PlayerController` asks this decorator for fresh credentials. The proof they arrived is the
  /// next item the engine builds carrying the rotated Bearer, not merely a `true` return.
  @Test("a renewal re-stamps the same track URLs with the rotated Bearer")
  func renewalReconfiguresTheEngineWithTheRotatedBearer() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let queue = FakeQueuePlayer()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: queue, itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let url = URL(string: "https://books.example.test/api/items/item-1/file/101")!
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: url, mimeType: "audio/mpeg", title: nil)
      ],
      chapters: [], source: .streaming,
      streamAuthorization: try await makeStreamAuthorization(accessToken: "tok-1"))
    underlying.stubStartSession(.success(prepared))
    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)
    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 0, rate: 1,
      generation: 1)
    let oldHeaders = try #require(factory.madeHeaders.last)
    factory.madeItems[0].simulateFailed(AudioEngineAdapterError.unknownPlaybackFailure)
    #expect(factory.madeItems[0].isUnusable)
    underlying.stubRenewStreamAuthorization(
      try await makeStreamAuthorization(accessToken: "tok-2"))

    #expect(await sut.renewStreamAuthorizationAndReconfigure())

    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 0, rate: 1,
      generation: 1)
    #expect(factory.madeItems.last?.url == url)
    let renewedHeaders = try #require(factory.madeHeaders.last)
    let renewedItem = try #require(factory.madeItems.last)
    #expect(factory.madeItems.count == 2)
    #expect(oldHeaders == ["Authorization": "Bearer tok-1"])
    #expect(renewedHeaders == ["Authorization": "Bearer tok-2"])
    #expect(queue.items().first === renewedItem)
    #expect(renewedItem.resource.headers == renewedHeaders)
  }

  /// A renewal builds a new item through the engine's ordinary load path, so Voice Boost must
  /// reach it the way it reaches any other new item.
  @Test("a renewed item carries Voice Boost's tap while the switch is on")
  func renewedItemCarriesVoiceBoost() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let voiceBoost = VoiceBoostTapFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()), voiceBoost: voiceBoost)
    engine.setVoiceBoostEnabled(true)
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let url = URL(string: "https://books.example.test/api/items/item-1/file/101")!
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: url, mimeType: "audio/mpeg", title: nil)
      ],
      chapters: [], source: .streaming,
      streamAuthorization: try await makeStreamAuthorization(accessToken: "tok-1"))
    underlying.stubStartSession(.success(prepared))
    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)
    let track = PlaybackTrack(index: 1, startOffset: 0, duration: 100)
    engine.load(track: track, localOffset: 0, rate: 1, generation: 1)
    factory.madeItems[0].simulateFailed(AudioEngineAdapterError.unknownPlaybackFailure)
    underlying.stubRenewStreamAuthorization(try await makeStreamAuthorization(accessToken: "tok-2"))

    #expect(await sut.renewStreamAuthorizationAndReconfigure())
    engine.load(track: track, localOffset: 0, rate: 1, generation: 2)

    let renewedItem = try #require(factory.madeItems.last)
    #expect(factory.madeItems.count == 2)
    #expect(renewedItem.attachedProcessor === voiceBoost)
    #expect(voiceBoost.isEnabled)
  }

  /// With nothing renewable (no session yet, or a coordinator that answered `nil`), report
  /// failure rather than reconfigure the engine with an empty header set. That would strip the
  /// Bearer from a stream that only had a transient problem.
  @Test("a renewal with nothing to renew reports failure and leaves the engine alone")
  func renewalWithoutARenewableSessionReportsFailure() async throws {
    let underlying = FakePlaybackSyncing()
    let factory = FakeItemFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: factory,
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    let sut = StreamConfiguringPlaybackSyncing(underlying: underlying, engine: engine)
    let url = URL(string: "https://books.example.test/api/items/item-1/file/101")!
    let prepared = PreparedPlayback(
      itemID: "item-1", episodeID: nil, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 1, startOffset: 0, duration: 100, url: url, mimeType: "audio/mpeg", title: nil)
      ],
      chapters: [], source: .streaming,
      streamAuthorization: try await makeStreamAuthorization(accessToken: "tok-1"))
    underlying.stubStartSession(.success(prepared))
    _ = try await sut.startSession(itemID: "item-1", episodeID: nil)

    #expect(await sut.renewStreamAuthorizationAndReconfigure() == false)

    engine.load(
      track: PlaybackTrack(index: 1, startOffset: 0, duration: 100), localOffset: 0, rate: 1,
      generation: 1)
    #expect(factory.madeHeaders.last == ["Authorization": "Bearer tok-1"])
  }

  @Test("a podcast tick reaches the underlying sync with its episode id intact")
  func recordProgressTickForwardsEpisodeIdentity() async {
    let (sut, underlying) = makeSUT()

    await sut.recordProgressTick(
      itemID: "item-podcast", episodeID: "episode-7", currentTime: 42, listenedDelta: 5,
      isFinished: false, isSeek: false)

    #expect(
      underlying.progressTicks == [
        FakePlaybackSyncing.ProgressTick(
          itemID: "item-podcast", episodeID: "episode-7", currentTime: 42, listenedDelta: 5,
          isFinished: false, isSeek: false)
      ])
  }

  @Test("a book tick still forwards a nil episode id plus every other argument")
  func recordProgressTickForwardsItemOnlyIdentity() async {
    let (sut, underlying) = makeSUT()

    await sut.recordProgressTick(
      itemID: "item-book", episodeID: nil, currentTime: 3_600, listenedDelta: 15, isFinished: true,
      isSeek: true)

    #expect(
      underlying.progressTicks == [
        FakePlaybackSyncing.ProgressTick(
          itemID: "item-book", episodeID: nil, currentTime: 3_600, listenedDelta: 15,
          isFinished: true, isSeek: true)
      ])
  }

  @Test("a sleep-timer marker reaches the underlying sync")
  func recordProgressTickForwardsSleepTimerMarker() async {
    let (sut, underlying) = makeSUT()

    await sut.recordProgressTick(
      itemID: "item-book", episodeID: nil, currentTime: 3_600, listenedDelta: 15,
      isFinished: false, isSeek: false, sleepTimerExpired: true)

    #expect(underlying.progressTicks.first?.sleepTimerExpired == true)
  }

  @Test("the start announcement reaches the underlying sync with its item id")
  func willStartPlaybackForwardsItsItemID() async {
    let (sut, underlying) = makeSUT()

    sut.willStartPlayback(itemID: "rss:7")

    #expect(underlying.willStartPlaybackItemIDs == ["rss:7"])
  }
}
