import AVFoundation
import PlayerCore
import Testing

@testable import Whirr

/// Covers `AVQueuePlayerAudioEngine` entirely over injected `AudioQueuePlayerControlling`/
/// `AudioPlayerItemHandle`/`AudioPlayerItemFactory` fakes. No real `AVPlayer`, no real hardware.
@MainActor
@Suite("AVQueuePlayerAudioEngine")
struct AVAudioEngineAdapterTests {

  private struct StreamError: Error, LocalizedError {
    var errorDescription: String? { "boom" }
  }

  private func makeSUT() -> (
    engine: AVQueuePlayerAudioEngine, queue: FakeQueuePlayer, factory: FakeItemFactory,
    session: FakeAudioSessionControlling
  ) {
    let queue = FakeQueuePlayer()
    let factory = FakeItemFactory()
    let session = FakeAudioSessionControlling()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: queue, itemFactory: factory, session: AudioSessionConfigurator(session: session))
    return (engine, queue, factory, session)
  }

  @Test("the player item factory gives AVFoundation the catalog MIME type")
  func playerItemFactoryOverridesAmbiguousLocalExtensionWithMIMEType() {
    let options = AVFoundationPlayerItemFactory.assetOptions(
      headers: [:], mimeType: "audio/mpeg")

    #expect(options[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mpeg")
  }

  // MARK: - load / replace-or-enqueue

  @Test("load without a configured URL emits an unrecoverable failure")
  func loadWithoutConfiguredURLFails() async {
    let (engine, _, _, _) = makeSUT()
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let event = await iterator.next()
    #expect(
      event
        == .failed(
          generation: 1,
          AudioEngineFailure(isRecoverable: false, message: "No stream URL configured for track 0")))
  }

  @Test("load resolves the configured URL, inserts a fresh item, and enqueues a lookahead")
  func loadInsertsFreshItemAndLookahead() {
    let (engine, queue, factory, _) = makeSUT()
    let url0 = URL(string: "https://example.com/0.mp3")!
    let url1 = URL(string: "https://example.com/1.mp3")!
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: url0), PlaybackTrackResource(trackIndex: 1, url: url1),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.5, generation: 1)

    #expect(queue.removeAllCallCount == 1)
    #expect(factory.madeItems.count == 2)
    #expect(factory.madeItems[0].url == url0)
    #expect(factory.madeItems[1].url == url1)
    #expect(queue.rate == 0, "load alone must not start playback - play() applies the rate")

    engine.play()
    #expect(queue.rate == 1.5, "the rate requested by load takes effect on play")
  }

  @Test(".timeDomain pitch algorithm is set on every item, including the lookahead")
  func timeDomainSetOnEveryItem() {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    #expect(factory.madeItems.allSatisfy { $0.timePitchAlgorithm == .timeDomain })
  }

  @Test("a streamed item buffers far ahead, so the radio sleeps between fetches")
  func streamedItemsGetALongForwardBuffer() {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    #expect(factory.madeItems.count == 2)
    #expect(
      factory.madeItems.allSatisfy {
        $0.preferredForwardBufferDuration == AVQueuePlayerAudioEngine.streamingForwardBufferDuration
      },
      "the lookahead item streams over the same radio as the current one")
  }

  @Test("a local file item leaves the forward buffer at AVFoundation's default")
  func localFileItemsKeepTheDefaultForwardBuffer() {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(fileURLWithPath: "/tmp/0.m4b"))
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    #expect(factory.madeItems.count == 1)
    #expect(
      factory.madeItems[0].preferredForwardBufferDuration == 0,
      "no radio to idle, and a long window is pure waste once a seek discards it")
  }

  @Test("load reuses an item AVQueuePlayer already auto-advanced to, instead of recreating it")
  func loadReusesAutoAdvancedItem() {
    let (engine, queue, factory, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    engine.play()
    let removeAllAfterFirstLoad = queue.removeAllCallCount

    // AVQueuePlayer drops the finished item and advances to the pre-buffered lookahead on its own.
    // PlayerReducer then issues a fresh `loadEngine` for the same track.
    queue.simulateAutoAdvance()
    engine.load(track: PlaybackTrack(index: 1, duration: 10), localOffset: 0, rate: 1.75, generation: 2)

    #expect(queue.removeAllCallCount == removeAllAfterFirstLoad, "reused the item - no teardown")
    #expect(factory.madeItems.count == 2, "no new item was created")
    #expect(queue.rate == 1.75, "rate restoration after track change")
  }

  @Test("load replaces an item when the same track and URL carry different headers")
  func loadReplacesItemWhenResourceHeadersChange() {
    let (engine, queue, factory, _) = makeSUT()
    let url = URL(string: "https://example.com/0.mp3")!
    let firstResource = PlaybackTrackResource(
      trackIndex: 0, url: url, headers: ["Authorization": "Bearer tok-1"])
    let secondResource = PlaybackTrackResource(
      trackIndex: 0, url: url, headers: ["Authorization": "Bearer tok-2"])

    engine.configure(tracks: [firstResource])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let removeAllAfterFirstLoad = queue.removeAllCallCount

    engine.configure(tracks: [secondResource])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(queue.removeAllCallCount == removeAllAfterFirstLoad + 1)
    #expect(factory.madeItems.count == 2)
    #expect(factory.madeHeaders.count == 2)
    #expect(factory.madeHeaders[0] != factory.madeHeaders[1])
    #expect(factory.madeHeaders.last == secondResource.headers)
  }

  @Test("load replaces an item that failed through its status observer")
  func loadReplacesStatusFailedItem() {
    let (engine, queue, factory, _) = makeSUT()
    let resource = PlaybackTrackResource(
      trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)
    engine.configure(tracks: [resource])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let failedItem = factory.madeItems[0]
    let removeAllAfterFirstLoad = queue.removeAllCallCount

    failedItem.simulateFailed(StreamError())
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(queue.removeAllCallCount == removeAllAfterFirstLoad + 1)
    #expect(factory.madeItems.count == 2)
    #expect(factory.madeItems[1] !== failedItem)
  }

  @Test("load replaces an item that failed to play to its end")
  func loadReplacesFailedToPlayToEndItem() {
    let (engine, queue, factory, _) = makeSUT()
    let resource = PlaybackTrackResource(
      trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)
    engine.configure(tracks: [resource])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let failedItem = factory.madeItems[0]
    let removeAllAfterFirstLoad = queue.removeAllCallCount

    failedItem.simulateFailedToPlayToEnd(StreamError())
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(queue.removeAllCallCount == removeAllAfterFirstLoad + 1)
    #expect(factory.madeItems.count == 2)
    #expect(factory.madeItems[1] !== failedItem)
  }

  @Test("reconfigure rebuilds a changed lookahead while retaining the current item")
  func reconfigureRebuildsChangedLookahead() {
    let (engine, queue, factory, _) = makeSUT()
    let currentResource = PlaybackTrackResource(
      trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)
    let oldNextResource = PlaybackTrackResource(
      trackIndex: 1, url: URL(string: "https://example.com/1-old.mp3")!)
    let newNextResource = PlaybackTrackResource(
      trackIndex: 1, url: URL(string: "https://example.com/1-new.mp3")!)
    engine.configure(tracks: [currentResource, oldNextResource])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let currentItem = factory.madeItems[0]
    let staleLookahead = factory.madeItems[1]

    engine.configure(tracks: [currentResource, newNextResource])

    #expect(queue.items().count == 1)
    #expect(queue.items().first === currentItem)
    #expect(!queue.items().contains { $0 === staleLookahead })

    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(factory.madeItems.count == 3)
    #expect(factory.madeItems[2].resource == newNextResource)
    #expect(queue.items().count == 2)
    #expect(queue.items()[0] === currentItem)
    #expect(queue.items()[1] === factory.madeItems[2])
  }

  /// Switching books reconfigures the adapter and loads the new book's track 0. The previous book's
  /// track 0 is still the front item, and the track index alone cannot tell them apart. Reusing it
  /// would keep the old book's audio playing under the new book's title and position.
  @Test("load replaces the queue when the front item's track index matches but its URL does not")
  func loadReplacesFrontItemFromADifferentItemsStream() {
    let (engine, queue, factory, _) = makeSUT()
    let firstBookTrack0 = URL(string: "https://example.com/book-a/0.mp3")!
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: firstBookTrack0)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    engine.play()
    let removeAllAfterFirstLoad = queue.removeAllCallCount

    let secondBookTrack0 = URL(string: "https://example.com/book-b/0.mp3")!
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: secondBookTrack0)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(queue.removeAllCallCount == removeAllAfterFirstLoad + 1, "the old book's item was torn down")
    #expect(factory.madeItems.count == 2, "a fresh item was built for the new book")
    #expect(factory.madeItems.last?.url == secondBookTrack0)
  }

  @Test("cross-track seek to a non-adjacent track replaces the queue")
  func crossTrackSeekReplacesQueue() {
    let (engine, queue, factory, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
      PlaybackTrackResource(trackIndex: 2, url: URL(string: "https://example.com/2.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let removeAllBefore = queue.removeAllCallCount

    engine.load(track: PlaybackTrack(index: 2, duration: 10), localOffset: 3, rate: 1.0, generation: 2)

    #expect(queue.removeAllCallCount == removeAllBefore + 1)
    #expect(factory.madeItems.last?.trackIndex == 2)
    #expect(factory.madeItems.last?.seekCalls == [3])
  }

  // MARK: - seek(toLocalOffset:) (same-track only)

  @Test("seek(toLocalOffset:) seeks the current item without replacing the queue")
  func seekWithinCurrentTrack() {
    let (engine, queue, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let removeAllBefore = queue.removeAllCallCount

    engine.seek(toLocalOffset: 5)

    #expect(factory.madeItems[0].seekCalls == [5])
    #expect(queue.removeAllCallCount == removeAllBefore)
  }

  @Test("seek(toLocalOffset:) requests a sample-accurate seek (zero tolerance)")
  func seekWithinCurrentTrackIsSampleAccurate() {
    // A bare `AVPlayerItem.seek(to:)` snaps to the nearest convenient decode point. For compressed
    // audiobook audio that can be seconds off (on device, a scrub to 25:00 landed near 28:00). The
    // adapter requests zero tolerance on both sides so the seek lands where the scrub released.
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    engine.seek(toLocalOffset: 5)

    #expect(factory.madeItems[0].seekRequests == [.init(offset: 5, toleranceBefore: .zero, toleranceAfter: .zero)])
  }

  @Test("seek(toLocalOffset:) never lands behind the offset it was asked for")
  func seekNeverRoundsBelowTheRequestedOffset() throws {
    // `CMTime(seconds:preferredTimescale: 600)` rounds to the nearest 1/600s tick, so 1234.567
    // becomes 1234.566667, a third of a millisecond short. That only shows at a chapter boundary,
    // which `PlaybackChapterMap` gives to the later chapter. Landing short reports the chapter the
    // listener just left. Rounding up costs at most 1/600s.
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 3600), localOffset: 0, rate: 1.0, generation: 1)

    engine.seek(toLocalOffset: 1234.567)

    let landed = try #require(factory.madeItems[0].seekCalls.first)
    #expect(landed >= 1234.567, "a seek must never land in the chapter it was asked to leave")
    #expect(landed - 1234.567 <= 1.0 / 600.0, "and no further past it than the timescale requires")
  }

  @Test("a cross-track load seeks to an offset it never lands behind either")
  func loadNeverRoundsItsOffsetBelowWhatWasRequested() throws {
    // Same rounding on the other path: a chapter start in a different track arrives as
    // `loadEngine`'s `localOffset`, not via `seek(toLocalOffset:)`.
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])

    engine.load(track: PlaybackTrack(index: 0, duration: 3600), localOffset: 812.339, rate: 1.0, generation: 1)

    let landed = try #require(factory.madeItems[0].seekCalls.first)
    #expect(landed >= 812.339)
    #expect(landed - 812.339 <= 1.0 / 600.0)
  }

  // MARK: - Event translation

  @Test("load emits ready once the item becomes ready")
  func loadEmitsReadyOnceItemBecomesReady() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateReady(duration: 42)

    // The extent is emitted before readiness. `PlayerReducer` seeks to the load position on
    // `.ready`, clamped to the timeline it holds then, so the corrected extent must arrive first.
    #expect(await iterator.next() == .durationObserved(generation: 1, localDuration: 42))
    #expect(await iterator.next() == .ready(generation: 1))
  }

  // MARK: - Observed duration

  @Test("a revised duration on the loaded item is forwarded with the active generation")
  func revisedDurationIsForwarded() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 4)
    factory.madeItems[0].simulateReady()
    _ = await iterator.next()  // the initial ready

    // A stream whose real extent resolves only after enough has loaded, well after the item became
    // playable on a declared duration that under-ran it.
    factory.madeItems[0].simulateDurationChanged(130)

    #expect(await iterator.next() == .durationObserved(generation: 4, localDuration: 130))
  }

  @Test("an item whose duration was already resolved when it became ready still reports it")
  func alreadyResolvedDurationIsReportedAtReady() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    // KVO delivers changes, not current values. Without reading at `ready`, an item that resolved
    // its duration before the observer attached would never report it.
    factory.madeItems[0].simulateReady(duration: 55)

    #expect(await iterator.next() == .durationObserved(generation: 1, localDuration: 55))
  }

  /// `nil` is not yet resolved, `indefinite` is a live stream, and `zero` is an item whose asset
  /// has not loaded. None is a measurement, so none is forwarded.
  @Test("an unresolved or nonsensical duration is never forwarded at ready")
  func unusableDurationsAreNotForwarded() async {
    let unusable: [CMTime?] = [nil, .indefinite, CMTime(seconds: 0, preferredTimescale: 600)]
    for duration in unusable {
      let (engine, _, factory, _) = makeSUT()
      engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
      var iterator = engine.events.makeAsyncIterator()
      engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
      factory.madeItems[0].duration = duration

      factory.madeItems[0].simulateReady()

      // `ready` must arrive first. The observed extent is emitted ahead of it, so a forwarded value
      // would show up before this.
      #expect(await iterator.next() == .ready(generation: 1))
    }
  }

  @Test("a superseded item's revised duration never reaches PlayerCore")
  func supersededItemDurationIsDropped() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let staleItem = factory.madeItems[0]

    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 5, url: URL(string: "https://example.com/5.mp3")!)])
    engine.load(track: PlaybackTrack(index: 5, duration: 10), localOffset: 0, rate: 1.0, generation: 2)
    var iterator = engine.events.makeAsyncIterator()

    // Applied to the current item, the stale 130 would grow its timeline by 120 seconds. The current
    // item's own 90 must be the first event delivered.
    staleItem.simulateDurationChanged(130)
    factory.madeItems.last?.simulateDurationChanged(90)

    #expect(await iterator.next() == .durationObserved(generation: 2, localDuration: 90))
  }

  @Test("player buffering toggles emit buffering, then ready again on recovery")
  func bufferingTogglesEmitEvents() async {
    let (engine, queue, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    factory.madeItems[0].simulateReady()
    _ = await iterator.next()  // the initial ready

    queue.simulateBuffering(true)
    let bufferingEvent = await iterator.next()
    #expect(bufferingEvent == .buffering(generation: 1))

    queue.simulateBuffering(false)
    let readyAgainEvent = await iterator.next()
    #expect(readyAgainEvent == .ready(generation: 1))
  }

  @Test("repeated identical buffering signals collapse to a single event (paused-flood fix)")
  func repeatedIdenticalBufferingSignalsDoNotFlood() async {
    // While fully paused, `timeControlStatus` churns between non-waiting states. Each
    // isWaiting=false re-emitted `.ready`, and the reducer amplified the storm into a flood that
    // pegged a core (device trace: `WHIRRENG emit=ready req=0 rate=0.00`). Only genuine buffering
    // transitions may surface, so a run of identical signals must collapse to nothing.
    let (engine, queue, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    factory.madeItems[0].simulateReady()
    _ = await iterator.next()  // the initial ready

    queue.simulateBuffering(true)
    #expect(await iterator.next() == .buffering(generation: 1))
    queue.simulateBuffering(false)
    #expect(await iterator.next() == .ready(generation: 1))

    // Further isWaiting=false notifications with no change. Each must be a no-op. A genuine
    // change is interposed and must be the next event delivered, since a stray `.ready` would
    // arrive first.
    queue.simulateBuffering(false)
    queue.simulateBuffering(false)
    queue.simulateBuffering(false)
    queue.simulateBuffering(true)

    #expect(await iterator.next() == .buffering(generation: 1))
  }

  @Test("the periodic time observer emits positionUpdated tagged with the active generation")
  func periodicTimeEmitsPositionUpdated() async {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 3)
    engine.play()

    queue.simulatePeriodicTime(CMTime(seconds: 2.5, preferredTimescale: 600))

    let event = await iterator.next()
    #expect(event == .positionUpdated(generation: 3, localOffset: 2.5))
  }

  @Test("crossing an armed boundary reports the position at once")
  func boundaryCrossingEmitsPositionUpdated() async {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 2)
    engine.play()

    engine.setBoundary(atLocalOffset: 30)
    #expect(queue.boundary?.times == [CMTime(value: 18_000, timescale: 600)])
    queue.simulateBoundaryCrossing(at: CMTime(seconds: 30, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 2, localOffset: 30))
  }

  @Test("a new boundary replaces the old one, and nil or a load clears it")
  func boundaryIsReplacedAndCleared() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 1)

    engine.setBoundary(atLocalOffset: 30)
    engine.setBoundary(atLocalOffset: 70)
    #expect(queue.addBoundaryCallCount == 2)
    #expect(queue.removeBoundaryCallCount == 1)
    #expect(queue.boundary?.times == [CMTime(value: 42_000, timescale: 600)])

    engine.setBoundary(atLocalOffset: nil)
    #expect(queue.boundary == nil)

    engine.setBoundary(atLocalOffset: 30)
    engine.load(track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 2)
    #expect(queue.boundary == nil)
    #expect(queue.removeObserverCallCount == 0)
  }

  @Test("a crossing while paused is not reported")
  func pausedBoundaryCrossingIsSuppressed() async {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 1)
    engine.setBoundary(atLocalOffset: 30)

    // Paused: nothing to report.
    queue.simulateBoundaryCrossing(at: CMTime(seconds: 30, preferredTimescale: 600))
    engine.play()
    queue.simulatePeriodicTime(CMTime(seconds: 31, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 1, localOffset: 31))
  }

  @Test("a tick before the load's own seek lands is not reported as a position")
  func periodicTimeBeforeTheLoadSeekLandsIsSuppressed() async {
    let (engine, queue, factory, _) = makeSUT()
    factory.deferSeekCompletions = true
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    // A cold resume enqueues the item and seeks to the saved position. The seek takes time to land,
    // and the item's clock reads zero until it does.
    engine.load(track: PlaybackTrack(index: 0, duration: 36_960), localOffset: 14_784, rate: 1.0, generation: 3)
    engine.play()

    queue.simulatePeriodicTime(CMTime(seconds: 0, preferredTimescale: 600))
    queue.simulatePeriodicTime(CMTime(seconds: 0, preferredTimescale: 600))
    factory.madeItems[0].completePendingSeeks()
    queue.simulatePeriodicTime(CMTime(seconds: 14_784.5, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 3, localOffset: 14_784.5))
  }

  @Test("the load's own seek completion reports readiness, as every other seek path does")
  func theLoadSeekCompletionEmitsReady() async {
    let (engine, _, factory, _) = makeSUT()
    factory.deferSeekCompletions = true
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 36_960), localOffset: 14_784, rate: 1.0, generation: 3)
    // Ready before the seek resolves, the streaming order this guard exists for. Readiness alone
    // does not mean positioned.
    factory.madeItems[0].simulateReady()
    #expect(await iterator.next() == .ready(generation: 3))

    factory.madeItems[0].completePendingSeeks()

    #expect(await iterator.next() == .ready(generation: 3), "the landing is its own readiness signal")
  }

  @Test("a load that starts at the beginning reports its ticks immediately")
  func periodicTimeIsNotSuppressedForALoadAtTheStart() async {
    let (engine, queue, factory, _) = makeSUT()
    factory.deferSeekCompletions = true
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 3)
    engine.play()

    queue.simulatePeriodicTime(CMTime(seconds: 0.5, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 3, localOffset: 0.5))
  }

  @Test("a superseded load's seek completion cannot unblock its successor's ticks")
  func aSupersededSeekCompletionDoesNotUnblockTheNextLoad() async {
    let (engine, queue, factory, _) = makeSUT()
    factory.deferSeekCompletions = true
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
    ])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 36_960), localOffset: 14_784, rate: 1.0, generation: 3)
    engine.load(track: PlaybackTrack(index: 1, duration: 36_960), localOffset: 900, rate: 1.0, generation: 4)
    engine.play()

    factory.madeItems[0].completePendingSeeks()
    queue.simulatePeriodicTime(CMTime(seconds: 0, preferredTimescale: 600))
    factory.madeItems.last?.completePendingSeeks()
    queue.simulatePeriodicTime(CMTime(seconds: 900.5, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 4, localOffset: 900.5))
  }

  @Test("periodic stop-time and queued callbacks cannot advance position after pause")
  func periodicTimeAfterPauseIsIgnoredUntilPlaybackResumes() async {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 3)
    engine.play()
    engine.pause()

    queue.simulatePeriodicTime(CMTime(seconds: 4, preferredTimescale: 600))
    engine.play()
    queue.simulatePeriodicTime(CMTime(seconds: 4.5, preferredTimescale: 600))

    let event = await iterator.next()
    #expect(event == .positionUpdated(generation: 3, localOffset: 4.5))
  }

  // MARK: - Position observation cadence

  @Test("position observation starts at the foreground cadence")
  func positionObservationStartsAtForegroundCadence() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    #expect(queue.observedIntervals == [AVQueuePlayerAudioEngine.foregroundPositionInterval])
  }

  @Test("backgrounding re-installs the observer at the slower cadence")
  func backgroundingSlowsPositionObservation() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    engine.setPositionCadence(.background)

    #expect(queue.removeObserverCallCount == 1, "the old, faster observer must be torn down")
    #expect(
      queue.observedIntervals == [
        AVQueuePlayerAudioEngine.foregroundPositionInterval,
        AVQueuePlayerAudioEngine.backgroundPositionInterval,
      ])
  }

  @Test("returning to the foreground restores the fast cadence")
  func foregroundingRestoresFastPositionObservation() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    engine.setPositionCadence(.background)
    engine.setPositionCadence(.foreground)

    #expect(queue.observedIntervals.last == AVQueuePlayerAudioEngine.foregroundPositionInterval)
    #expect(queue.addObserverCallCount == 3)
  }

  @Test("a repeated cadence signal does not churn the observer")
  func repeatedCadenceSignalIsIgnored() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    engine.setPositionCadence(.background)
    engine.setPositionCadence(.background)

    #expect(queue.addObserverCallCount == 2)
    #expect(queue.removeObserverCallCount == 1)
  }

  @Test("a cadence set before any load applies to the observer that load installs")
  func cadenceSetBeforeLoadAppliesOnFirstObservation() {
    let (engine, queue, _, _) = makeSUT()
    engine.setPositionCadence(.background)
    #expect(queue.addObserverCallCount == 0, "nothing is playing yet - no observer to re-install")

    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    #expect(queue.observedIntervals == [AVQueuePlayerAudioEngine.backgroundPositionInterval])
  }

  @Test("the slower cadence still delivers position updates")
  func backgroundCadenceStillEmitsPositionUpdates() async {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 7)
    engine.play()
    engine.setPositionCadence(.background)

    queue.simulatePeriodicTime(CMTime(seconds: 12, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 7, localOffset: 12))
  }

  @Test("an item playing to its end emits trackFinished tagged with its generation")
  func itemFinishingEmitsTrackFinished() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateDidPlayToEnd()

    let event = await iterator.next()
    #expect(event == .trackFinished(generation: 1))
  }

  @Test("an item failing to play to its end emits a recoverable failure")
  func itemFailedToPlayToEndEmitsRecoverableFailure() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateFailedToPlayToEnd(StreamError())

    guard case .failed(_, let failure) = await iterator.next() else {
      Issue.record("expected a failure event")
      return
    }
    #expect(failure.isRecoverable)
  }

  @Test("failed-to-play-to-end preserves its error and error-log authentication status")
  func itemFailedToPlayToEndPreservesErrorAndAuthenticationStatus() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let error = NSError(
      domain: "NotificationError", code: 17,
      userInfo: [NSLocalizedDescriptionKey: "mid-play failure"])

    factory.madeItems[0].simulateFailedToPlayToEnd(error, responseStatusCode: 401)

    guard case .failed(_, let failure) = await iterator.next() else {
      Issue.record("expected a failure event")
      return
    }
    #expect(failure.message == "mid-play failure")
    #expect(failure.isAuthenticationFailure)
    #expect(failure.isRecoverable)
  }

  @Test("failed-to-play-to-end without an error still emits a failure")
  func itemFailedToPlayToEndWithoutErrorEmitsFailure() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateFailedToPlayToEnd()

    guard case .failed(_, let failure) = await iterator.next() else {
      Issue.record("expected a failure event")
      return
    }
    #expect(failure.isRecoverable)
  }

  @Test("a displaced item's failed-to-play-to-end does not emit an event")
  func displacedItemFailedToPlayToEndEmitsNothing() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let staleItem = factory.madeItems[0]

    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 5, url: URL(string: "https://example.com/5.mp3")!)])
    engine.load(track: PlaybackTrack(index: 5, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    var iterator = engine.events.makeAsyncIterator()
    staleItem.simulateFailedToPlayToEnd(StreamError())
    factory.madeItems[1].simulateReady()

    #expect(await iterator.next() == .ready(generation: 2))
  }

  @Test("normal end and failed-to-play-to-end remain distinct on the same item")
  func normalEndRemainsDistinctFromFailedToPlayToEnd() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let item = factory.madeItems[0]

    item.simulateDidPlayToEnd()
    #expect(await iterator.next() == .trackFinished(generation: 1))

    item.simulateFailedToPlayToEnd(StreamError())
    guard case .failed(_, let failure) = await iterator.next() else {
      Issue.record("expected a failure event after the distinct normal-end event")
      return
    }
    #expect(failure.isRecoverable)
  }

  @Test("an item failure translates to a recoverable AudioEngineFailure")
  func itemFailureTranslatesToRecoverableFailure() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateFailed(StreamError())

    let event = await iterator.next()
    #expect(event == .failed(generation: 1, AudioEngineFailure(isRecoverable: true, message: "boom")))
  }

  /// A `domain=NSURLErrorDomain code=-1013` failure must be flagged as an authentication failure.
  /// That flag alone separates a failure worth renewing credentials for from one worth plain
  /// retrying.
  @Test("an unauthenticated stream failure is flagged as an authentication failure")
  func unauthenticatedStreamFailureIsFlaggedForRenewal() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)

    factory.madeItems[0].simulateFailed(
      NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired))

    guard case .failed(_, let failure) = await iterator.next() else {
      Issue.record("expected a failure event")
      return
    }
    #expect(failure.isAuthenticationFailure)
    #expect(failure.isRecoverable)
  }

  // MARK: - Cancellation / observer removal

  @Test("replacing the current item cancels its stale callbacks")
  func replacingItemCancelsStaleCallbacks() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let staleItem = factory.madeItems[0]

    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 5, url: URL(string: "https://example.com/5.mp3")!)])
    engine.load(track: PlaybackTrack(index: 5, duration: 10), localOffset: 0, rate: 1.0, generation: 2)

    #expect(staleItem.onReady == nil)
    #expect(staleItem.onFailed == nil)
    #expect(staleItem.onFailedToPlayToEnd == nil)
    #expect(staleItem.onDidPlayToEnd == nil)
    #expect(staleItem.onDurationChanged == nil)

    var iterator = engine.events.makeAsyncIterator()
    staleItem.simulateReady(duration: 99)  // a late arrival from the item this load displaced
    factory.madeItems.last?.simulateReady()  // the real, current item

    let event = await iterator.next()
    #expect(event == .ready(generation: 2))
  }

  @Test("stop tears down items, clears the queue, and removes the time observer")
  func stopTearsDown() {
    let (engine, queue, factory, session) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    let item = factory.madeItems[0]
    let removeAllAfterLoad = queue.removeAllCallCount

    engine.stop()

    #expect(item.onReady == nil)
    #expect(item.onFailed == nil)
    #expect(item.onFailedToPlayToEnd == nil)
    #expect(item.onDidPlayToEnd == nil)
    #expect(queue.removeObserverCallCount == 1)
    #expect(queue.pauseCallCount == 1)
    #expect(queue.removeAllCallCount == removeAllAfterLoad + 1)
    #expect(session.setActiveCalls.last?.active == false)
  }

  // MARK: - Audio session lifecycle

  @Test("play configures and activates the audio session before starting playback")
  func playConfiguresAndActivatesSession() {
    let (engine, queue, _, session) = makeSUT()
    engine.play()
    #expect(session.setCategoryCalls.last?.category == .playback)
    #expect(session.setCategoryCalls.last?.mode == .spokenAudio)
    #expect(session.setActiveCalls.last?.active == true)
    #expect(queue.playCallCount == 1)
    #expect(engine.lastSessionActivation?.configurationSucceeded == true)
    #expect(engine.lastSessionActivation?.activationSucceeded == true)
  }

  @Test("play still starts the queue when the OS refuses the session")
  func playProceedsWhenSessionRefuses() {
    let (engine, queue, _, session) = makeSUT()
    session.shouldThrow = true
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.5, generation: 1)

    engine.play()

    #expect(
      queue.playCallCount == 1,
      "AVFoundation activates implicitly for a starting player, and an exclusive owner is usually transient")
    #expect(queue.rate == 1.5)
    #expect(engine.lastSessionActivation?.generation == 1)
    #expect(engine.lastSessionActivation?.configurationSucceeded == false)
    #expect(engine.lastSessionActivation?.activationSucceeded == false)
  }

  @Test("a successful retry replaces a refused activation and stop clears it")
  func sessionActivationOutcomeDoesNotLeakIntoAnotherAttempt() {
    let (engine, _, _, session) = makeSUT()
    session.shouldThrow = true
    engine.play()
    #expect(engine.lastSessionActivation?.activationSucceeded == false)
    session.shouldThrow = false
    engine.play()
    #expect(engine.lastSessionActivation?.configurationSucceeded == true)
    #expect(engine.lastSessionActivation?.activationSucceeded == true)
    engine.stop()
    #expect(engine.lastSessionActivation == nil)
  }

  @Test("loading another generation invalidates the prior activation outcome")
  func loadClearsSessionActivationOutcome() {
    let (engine, _, _, _) = makeSUT()
    engine.play()
    #expect(engine.lastSessionActivation != nil)
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1, generation: 9)
    #expect(engine.lastSessionActivation == nil)
  }

  // MARK: - Deferred session handshake

  /// An engine whose session handshake waits for `work.runNext()`, as on a real device.
  private func makeDeferredSUT() -> (
    engine: AVQueuePlayerAudioEngine, queue: FakeQueuePlayer, session: FakeAudioSessionControlling,
    work: ManualAudioSessionWork
  ) {
    let queue = FakeQueuePlayer()
    let session = FakeAudioSessionControlling()
    let work = ManualAudioSessionWork()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: queue, itemFactory: FakeItemFactory(),
      session: AudioSessionConfigurator(session: session, work: work))
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.5, generation: 1)
    return (engine, queue, session, work)
  }

  @Test("play returns before the session handshake runs and starts the queue once it has")
  func playStartsQueueAfterHandshake() {
    let (engine, queue, session, work) = makeDeferredSUT()

    engine.play()

    #expect(session.setActiveCalls.isEmpty, "the blocking activation must not run inside play()")
    #expect(queue.playCallCount == 0)
    #expect(engine.lastSessionActivation == nil)

    work.runNext()

    #expect(session.setActiveCalls.map(\.active) == [true])
    #expect(queue.playCallCount == 1)
    #expect(queue.rate == 1.5)
    #expect(engine.lastSessionActivation?.generation == 1)
    #expect(engine.lastSessionActivation?.activationSucceeded == true)
  }

  @Test("a pause that arrives during the handshake keeps the queue paused")
  func pauseDuringHandshakeWins() {
    let (engine, queue, _, work) = makeDeferredSUT()

    engine.play()
    engine.pause()
    work.runNext()

    #expect(queue.playCallCount == 0)
    #expect(queue.rate == 0)
  }

  @Test("only the latest play starts the queue when taps outrun the handshake")
  func latestPlayWinsDuringHandshake() {
    let (engine, queue, _, work) = makeDeferredSUT()

    engine.play()
    engine.pause()
    engine.play()
    work.runNext()
    #expect(queue.playCallCount == 0, "the first play was superseded by the pause")

    work.runNext()
    #expect(queue.playCallCount == 1)
    #expect(queue.rate == 1.5)
  }

  @Test("a stop that arrives during the handshake stays stopped and deactivates after the activation")
  func stopDuringHandshakeWins() {
    let (engine, queue, session, work) = makeDeferredSUT()

    engine.play()
    engine.stop()
    work.runNext()
    work.runNext()

    #expect(queue.playCallCount == 0)
    #expect(session.setActiveCalls.map(\.active) == [true, false])
    #expect(engine.lastSessionActivation == nil)
  }

  @Test("a load that arrives during the handshake still plays, at the new load's rate and generation")
  func loadDuringHandshakeStillPlays() {
    let (engine, queue, _, work) = makeDeferredSUT()

    engine.play()
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 2.0, generation: 2)
    work.runNext()

    #expect(queue.playCallCount == 1)
    #expect(queue.rate == 2.0)
    #expect(engine.lastSessionActivation?.generation == 2)
  }

  @Test("the session-failure trace names the stage and carries no free text")
  func sessionFailureTraceRecordsStageAndCode() {
    let error = NSError(
      domain: NSOSStatusErrorDomain, code: 561_017_449,
      userInfo: [
        NSLocalizedDescriptionKey: "The operation couldn’t be completed",
        NSUnderlyingErrorKey: NSError(domain: "AVAudioSessionErrorDomain", code: 17),
      ])

    let message = AVQueuePlayerAudioEngine.sessionFailureTraceMessage(stage: .activate, error: error)

    #expect(message.contains("WHIRRENG session stage=activate"))
    #expect(message.contains("domain=\(NSOSStatusErrorDomain)"))
    #expect(message.contains("code=561017449"))
    #expect(message.contains("underlyingDomain=AVAudioSessionErrorDomain"))
    #expect(message.contains("underlyingCode=17"))
    #expect(
      !message.contains("couldn’t be completed"),
      "device trace lines are public - no unbounded foreign string may enter one")
  }

  @Test("pause stops the queue without touching the audio session")
  func pauseDoesNotTouchSession() {
    let (engine, queue, _, session) = makeSUT()
    engine.pause()
    #expect(queue.pauseCallCount == 1)
    #expect(session.setActiveCalls.isEmpty)
  }

  @Test("play reasserts the current rate over AVPlayer's implicit reset to its default rate")
  func playReassertsCurrentRate() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 2.0, generation: 1)
    engine.play()
    #expect(queue.rate == 2.0, "rate from load survives play")

    engine.setRate(1.5)
    engine.pause()
    engine.play()
    #expect(queue.rate == 1.5, "rate from setRate survives pause/play")
  }

  @Test("a cross-track load while paused replaces the queue without starting playback")
  func crossTrackLoadWhilePausedDoesNotResume() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
      PlaybackTrackResource(trackIndex: 2, url: URL(string: "https://example.com/2.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    engine.play()
    engine.pause()
    #expect(queue.rate == 0, "paused AVPlayer sits at rate 0")

    // A paused cross-track seek from the expanded player. PlayerReducer issues a fresh `loadEngine`
    // while the phase is still paused (`intendedPlaying == false`).
    engine.load(track: PlaybackTrack(index: 2, duration: 10), localOffset: 3, rate: 1.0, generation: 2)
    #expect(queue.rate == 0, "loading while paused must not start playback")

    engine.play()
    #expect(queue.rate == 1.0, "resume plays at the rate the load requested")
  }

  /// Changing the trim map mid-play reloads the playing track. The reducer reasserts `.play` once
  /// the reload is ready, and playback must resume at the rate in force.
  @Test("a reload of the playing track plays again at its rate once play is reasserted")
  func reloadOfPlayingTrackResumesOnPlay() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.25, generation: 1)
    engine.play()
    #expect(queue.rate == 1.25)

    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 5, rate: 1.25, generation: 2)
    engine.play()

    #expect(queue.rate == 1.25, "the reloaded track plays at the rate the load requested")
  }

  private static let trimURL = URL(string: "https://example.com/0.mp3")!
  private static let trimMap = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 10, end: 12)])

  /// A trimmed engine with a composition prepared for `trimMap` and the item already loaded.
  private func makeTrimmedSUT(offset: Double = 0) -> (
    engine: AVQueuePlayerAudioEngine, queue: FakeQueuePlayer, factory: FakeItemFactory, asset: AVAsset
  ) {
    let (engine, queue, factory, _) = makeSUT()
    let asset = AVMutableComposition()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: Self.trimURL)])
    engine.configureTrimmed(fileURL: Self.trimURL, map: Self.trimMap, asset: asset)
    engine.load(
      track: PlaybackTrack(index: 0, duration: 100), localOffset: offset, rate: 1.0, generation: 1,
      trim: Self.trimMap)
    return (engine, queue, factory, asset)
  }

  @Test("a load given a prepared map plays the prepared asset and does not decline it")
  func loadWithPreparedMapPlaysComposition() async {
    let (engine, _, factory, asset) = makeTrimmedSUT()
    var iterator = engine.events.makeAsyncIterator()
    factory.madeItems[0].simulateDidPlayToEnd()

    #expect(factory.madeItems.count == 1)
    #expect(factory.madeItems[0].preparedAsset === asset)
    #expect(factory.madeItems[0].trim == Self.trimMap)
    #expect(factory.madeItems[0].url == Self.trimURL)
    #expect(await iterator.next() == .trackFinished(generation: 1))
  }

  @Test("a load with no prepared asset plays the plain item and declines the map")
  func loadWithoutPreparedAssetDeclinesMap() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: Self.trimURL)])
    var iterator = engine.events.makeAsyncIterator()

    engine.load(
      track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1,
      trim: Self.trimMap)
    // A known later event, so a missing decline fails the test instead of hanging it.
    factory.madeItems[0].simulateDidPlayToEnd()

    #expect(await iterator.next() == .trimDeclined(generation: 1))
    #expect(factory.madeItems.count == 1)
    #expect(factory.madeItems[0].preparedAsset == nil)
    #expect(factory.madeItems[0].trim == nil)
  }

  @Test("a prepared asset for a different map is not played, and the map is declined")
  func loadWithDifferentMapDeclines() async {
    let (engine, _, factory, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: Self.trimURL)])
    engine.configureTrimmed(fileURL: Self.trimURL, map: Self.trimMap, asset: AVMutableComposition())
    var iterator = engine.events.makeAsyncIterator()
    let other = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 20, end: 21)])

    engine.load(
      track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 4,
      trim: other)
    factory.madeItems[0].simulateDidPlayToEnd()

    #expect(await iterator.next() == .trimDeclined(generation: 4))
    #expect(factory.madeItems[0].preparedAsset == nil)
  }

  @Test("stop drops the prepared assets")
  func stopDropsPreparedAssets() async {
    let (engine, _, factory, _) = makeTrimmedSUT()
    engine.stop()
    var iterator = engine.events.makeAsyncIterator()

    engine.load(
      track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 2,
      trim: Self.trimMap)
    factory.madeItems[1].simulateDidPlayToEnd()

    #expect(await iterator.next() == .trimDeclined(generation: 2))
  }

  @Test("a load offset in source time seeks the composition at its played time")
  func loadOffsetIsMappedToPlayedTime() {
    let (_, _, factory, _) = makeTrimmedSUT(offset: 20)
    #expect(factory.madeItems[0].seekCalls == [18])
  }

  @Test("a reused trimmed front item is seeked at the played time")
  func reusedFrontItemSeekIsMapped() {
    let (engine, _, factory, _) = makeTrimmedSUT()
    engine.load(
      track: PlaybackTrack(index: 0, duration: 100), localOffset: 20, rate: 1.0, generation: 2,
      trim: Self.trimMap)

    #expect(factory.madeItems.count == 1)
    #expect(factory.madeItems[0].seekCalls == [18])
  }

  @Test("a seek in source time seeks the composition at its played time")
  func seekIsMappedToPlayedTime() {
    let (engine, _, factory, _) = makeTrimmedSUT()
    engine.seek(toLocalOffset: 30)
    #expect(factory.madeItems[0].seekCalls == [28])
  }

  @Test("a periodic tick at played 18 reports source 20")
  func periodicTickIsMappedToSourceTime() async {
    let (engine, queue, _, _) = makeTrimmedSUT()
    var iterator = engine.events.makeAsyncIterator()
    engine.play()

    queue.simulatePeriodicTime(CMTime(seconds: 18, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 1, localOffset: 20))
  }

  @Test("the boundary is armed at the played time and reports source time when crossed")
  func boundaryIsArmedAtPlayedTime() async {
    let (engine, queue, _, _) = makeTrimmedSUT()
    var iterator = engine.events.makeAsyncIterator()
    engine.play()

    engine.setBoundary(atLocalOffset: 30)
    #expect(queue.boundary?.times == [CMTime(value: 28 * 600, timescale: 600)])
    queue.simulateBoundaryCrossing(at: CMTime(seconds: 28, preferredTimescale: 600))

    #expect(await iterator.next() == .positionUpdated(generation: 1, localOffset: 30))
  }

  @Test("an observed composition duration maps back to source time")
  func observedDurationIsMappedToSourceTime() async {
    let (engine, _, factory, _) = makeTrimmedSUT()
    var iterator = engine.events.makeAsyncIterator()

    factory.madeItems[0].simulateDurationChanged(98)

    #expect(await iterator.next() == .durationObserved(generation: 1, localDuration: 100))
  }

  @Test("a different map on the same resource replaces the front item")
  func differentMapReplacesFrontItem() {
    let (engine, queue, factory, _) = makeTrimmedSUT()
    engine.load(
      track: PlaybackTrack(index: 0, duration: 100), localOffset: 0, rate: 1.0, generation: 2)

    #expect(factory.madeItems.count == 2)
    #expect(factory.madeItems[1].trim == nil)
    #expect(queue.items().first === factory.madeItems[1])
  }

  @Test("a load that reuses the front item while paused does not start playback")
  func reusedFrontItemLoadWhilePausedDoesNotResume() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!),
      PlaybackTrackResource(trackIndex: 1, url: URL(string: "https://example.com/1.mp3")!),
    ])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.5, generation: 1)
    engine.play()
    queue.simulateAutoAdvance()
    engine.pause()
    #expect(queue.rate == 0, "paused AVPlayer sits at rate 0")

    // The track 1 lookahead is already the front item, so this load takes the reuse path rather
    // than replacing the queue. It must not restart the paused player either.
    engine.load(track: PlaybackTrack(index: 1, duration: 10), localOffset: 0, rate: 1.5, generation: 2)
    #expect(queue.rate == 0, "reusing the front item while paused must not start playback")

    engine.play()
    #expect(queue.rate == 1.5, "resume plays at the rate the load requested")
  }

  @Test("setRate while paused stays paused; the new rate takes effect on the next play")
  func setRateWhilePausedDoesNotResumePlayback() {
    let (engine, queue, _, _) = makeSUT()
    engine.configure(tracks: [PlaybackTrackResource(trackIndex: 0, url: URL(string: "https://example.com/0.mp3")!)])
    engine.load(track: PlaybackTrack(index: 0, duration: 10), localOffset: 0, rate: 1.0, generation: 1)
    engine.play()
    engine.pause()
    #expect(queue.rate == 0, "paused AVPlayer sits at rate 0")

    engine.setRate(1.5)
    #expect(queue.rate == 0, "changing speed while paused must not start playback")

    engine.play()
    #expect(queue.rate == 1.5, "resume plays at the rate chosen while paused")
  }

  @Test("setVolume reaches the queue, clamps, and stays paused")
  func setVolumeWhilePausedClampsWithoutStartingPlayback() {
    let (engine, queue, _, _) = makeSUT()

    engine.setVolume(0.35)
    #expect(queue.volume == 0.35)
    #expect(queue.rate == 0, "volume changes must not start playback")

    engine.setVolume(2)
    #expect(queue.volume == 1)
    #expect(queue.rate == 0)

    engine.setVolume(-1)
    #expect(queue.volume == 0)
    #expect(queue.rate == 0)
  }

  @Test("failure trace carries fixed fields only, never an error description or comment text")
  func failureTraceMessageIsBoundedToValidatedFields() {
    let canary = "canary-secret-comment"
    let underlying = NSError(
      domain: "CoreMediaErrorDomain", code: -12_660,
      userInfo: [NSLocalizedDescriptionKey: canary])
    let error = NSError(
      domain: "AVFoundationErrorDomain", code: -11_828,
      userInfo: [NSLocalizedDescriptionKey: canary, NSUnderlyingErrorKey: underlying])

    let message = RealAudioPlayerItemHandle.failureTraceMessage(
      isLocal: false,
      isCredentialled: true,
      path: "/hls/session/output.m3u8",
      statusCode: 404,
      error: error,
      hasErrorComment: true)

    #expect(message.contains(canary) == false, "no free-form error text may enter the trace")
    #expect(message.contains("source=stream"))
    #expect(message.contains("credentialled=1"))
    #expect(message.contains("path=/hls/session/output.m3u8"))
    #expect(message.contains("status=404"))
    #expect(message.contains("domain=AVFoundationErrorDomain"))
    #expect(message.contains("code=-11828"))
    #expect(message.contains("underlyingDomain=CoreMediaErrorDomain"))
    #expect(message.contains("underlyingCode=-12660"))
    #expect(message.contains("commentPresent=1"))
  }

  @Test("failure trace renders absent path and comment as placeholders")
  func failureTraceMessageHandlesAbsentEventFields() {
    let message = RealAudioPlayerItemHandle.failureTraceMessage(
      isLocal: true,
      isCredentialled: false,
      path: nil,
      statusCode: 0,
      error: StreamError(),
      hasErrorComment: false)

    #expect(message.contains("source=local"))
    #expect(message.contains("path=- "))
    #expect(message.contains("underlyingDomain=- "))
    #expect(message.contains("commentPresent=0"))
  }
}
