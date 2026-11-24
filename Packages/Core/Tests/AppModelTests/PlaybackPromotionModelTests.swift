import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Playback promotion", .timeLimit(.minutes(1)))
struct PlaybackPromotionModelTests {
  private static let bookID = "book-promotion"
  private static let showID = "show-promotion"
  private static let episodeID = "episode-promotion"

  @Test("a completed podcast episode swaps to local playback and resumes a playing listener")
  func podcastEpisodePromotionResumesPlayback() async throws {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.showID, episodeID: Self.episodeID)
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.showID, episodeID: Self.episodeID, source: .local))

    harness.downloadReading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: Self.showID, episodeID: Self.episodeID): .completed
    ])
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.model.isStreamingSource == false }

    let load = try #require(Self.lastLoad(harness.player.intents))
    #expect(harness.model.isStreamingSource == false)
    #expect(load.item.isStreaming == false)
    #expect(load.item.episodeID == Self.episodeID)
    #expect(load.item.timeline.tracks.count == 1)
    #expect(harness.player.intents.last == .play)
  }

  @Test("a completed book swaps to local playback")
  func bookPromotionLoadsLocalTracks() async throws {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID)
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local, trackCount: 2))

    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.model.isStreamingSource == false }

    let load = try #require(Self.lastLoad(harness.player.intents))
    #expect(harness.model.isStreamingSource == false)
    #expect(load.item.isStreaming == false)
    #expect(load.item.timeline.tracks.count == 2)
  }

  @Test("a paused listener remains paused across promotion")
  func promotionDoesNotResumeAPausedListener() async throws {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID, intended: false, phase: .paused)
    let intentsBeforePromotion = harness.player.intents
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local))

    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.model.isStreamingSource == false }

    let newIntents = Array(harness.player.intents.dropFirst(intentsBeforePromotion.count))
    #expect(
      newIntents.contains {
        if case .load = $0 { return true }
        return false
      })
    #expect(newIntents.contains(.play) == false)
  }

  @Test("promotion uses the captured and then live player positions")
  func promotionPreservesLivePosition() async throws {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID, position: 42)
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local))
    harness.sync.holdPromotion()

    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.sync.parkedPromotionCount == 1 }
    harness.player.state.globalPosition = 57
    harness.sync.releasePromotion()
    await waitUntil { harness.model.isStreamingSource == false }

    let handedToCoordinator = try #require(Self.lastPromotionPosition(harness.sync.calls))
    let load = try #require(Self.lastLoad(harness.player.intents))
    #expect(handedToCoordinator == 42)
    #expect(load.initialGlobalPosition == 57)
  }

  /// No promotion is ever attempted from an ineligible phase. What happens afterwards differs:
  /// `.seeking` and `.preparing` hold the completion and promote once settled (proved here for
  /// seeking, and by the auto-advance test for preparing), while idle, ended, and the error phases
  /// drop it, since that listen is not continuing.
  @Test("no promotion is attempted while seeking, preparing, idle, ended, or failed")
  func promotionPhaseGating() async throws {
    let deferred = Self.makeHarness()
    await Self.startStreaming(deferred, itemID: Self.bookID)
    deferred.player.state.globalPosition = 23
    await Self.pushPhase(.seeking, to: deferred)
    deferred.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local))
    deferred.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForNoPromotion(deferred.sync)
    #expect(deferred.model.isStreamingSource)

    await Self.pushPhase(.playing, to: deferred)
    await Self.waitForPromotion(deferred.sync)
    await waitUntil { deferred.model.isStreamingSource == false }

    let phases: [PlaybackModel.Phase] = [
      .preparing, .idle, .ended, .recoverableError, .unrecoverableError,
    ]
    for phase in phases {
      let harness = Self.makeHarness()
      await Self.startStreaming(harness, itemID: Self.bookID)
      await Self.pushPhase(phase, to: harness)
      harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
      await Self.waitForNoPromotion(harness.sync)
      #expect(Self.promotionCallCount(harness.sync.calls) == 0)
    }
  }

  @Test("a different item or sibling episode cannot trigger promotion")
  func completedDifferentIdentityDoesNotPromote() async {
    let book = Self.makeHarness()
    await Self.startStreaming(book, itemID: Self.bookID)
    book.downloadReading.pushStatus(.completed, itemId: "other-book")
    await Self.waitForNoPromotion(book.sync)
    #expect(Self.promotionCallCount(book.sync.calls) == 0)

    let podcast = Self.makeHarness()
    await Self.startStreaming(podcast, itemID: Self.showID, episodeID: Self.episodeID)
    podcast.downloadReading.pushEpisodePresence([
      EpisodeDownloadKey(itemID: Self.showID, episodeID: "sibling-episode"): .completed
    ])
    await Self.waitForNoPromotion(podcast.sync)
    #expect(Self.promotionCallCount(podcast.sync.calls) == 0)
  }

  /// The boundary itself must stay seamless, since swapping the whole item mid-advance would put
  /// a gap where playback is currently gapless. The completion is held rather than lost, so the
  /// swap lands just after the advance.
  @Test("a track auto-advance stays gapless and the promotion waits until it settles")
  func trackAutoAdvanceDefersPromotionUntilAfterTheBoundary() async {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID)
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local, trackCount: 2))
    await Self.pushPhase(.preparing, to: harness, position: 100)
    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForNoPromotion(harness.sync)

    #expect(Self.promotionCallCount(harness.sync.calls) == 0)
    #expect(harness.model.isStreamingSource)

    await Self.pushPhase(.playing, to: harness, position: 100)
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.model.isStreamingSource == false }

    #expect(Self.promotionCallCount(harness.sync.calls) == 1)
    #expect(harness.model.isStreamingSource == false)
  }

  @Test("repeated completed presence promotes only once per playback generation")
  func repeatedCompletionDoesNotThrashPromotion() async {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID)
    harness.sync.stubPromoteStreamingSessionToLocalDownload(
      Self.prepared(itemID: Self.bookID, source: .local))

    for _ in 0..<5 {
      harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    }
    await Self.waitForPromotion(harness.sync)
    await waitUntil { harness.model.isStreamingSource == false }
    await Self.waitForNoMoreThanOnePromotion(harness.sync)

    #expect(Self.promotionCallCount(harness.sync.calls) == 1)
  }

  @Test("a nil download reader opens no observation and never promotes")
  func nilDownloadReaderDisablesPromotion() async {
    let harness = Self.makeHarness(promotionEnabled: false)
    await Self.startStreaming(harness, itemID: Self.bookID)
    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForNoPromotion(harness.sync)

    #expect(harness.downloadReading.presenceSubscriptionCount == 0)
    #expect(harness.downloadReading.episodePresenceSubscriptionCount == 0)
    #expect(Self.promotionCallCount(harness.sync.calls) == 0)
    #expect(harness.model.isStreamingSource)
  }

  @Test("a coordinator refusal leaves the streamed player untouched")
  func nilPromotionResultLeavesStreamingStateUnchanged() async {
    let harness = Self.makeHarness()
    await Self.startStreaming(harness, itemID: Self.bookID)
    let intentsBefore = harness.player.intents
    let generationBefore = harness.model.playbackGeneration
    harness.downloadReading.pushStatus(.completed, itemId: Self.bookID)
    await Self.waitForPromotion(harness.sync)
    await Self.waitForNoMoreThanOnePromotion(harness.sync)

    #expect(harness.model.isStreamingSource)
    #expect(harness.model.loadedItemID == Self.bookID)
    #expect(harness.model.activeItemID == Self.bookID)
    #expect(harness.model.playbackGeneration == generationBefore)
    #expect(harness.player.intents == intentsBefore)
  }

  private struct Harness {
    let model: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let downloadReading: FakeDownloadReading
  }

  private static func makeHarness(promotionEnabled: Bool = true) -> Harness {
    let downloadReading = FakeDownloadReading()
    let playback = PlaybackModelHarness(
      downloadReading: promotionEnabled ? downloadReading : nil)
    return Harness(
      model: playback.model, player: playback.player, sync: playback.sync,
      downloadReading: downloadReading)
  }

  private static func startStreaming(
    _ harness: Harness,
    itemID: String,
    episodeID: String? = nil,
    intended: Bool = true,
    phase: PlaybackModel.Phase = .playing,
    position: Double = 10
  ) async {
    harness.sync.stubStartSession(
      .success(Self.prepared(itemID: itemID, episodeID: episodeID, source: .streaming)))
    await harness.model.start(itemID: itemID, episodeID: episodeID)
    harness.player.isPlaybackIntended = intended
    harness.player.state.globalPosition = position
    await Self.pushPhase(phase, to: harness, position: position)
  }

  private static func pushPhase(
    _ phase: PlaybackModel.Phase, to harness: Harness, position: Double? = nil
  ) async {
    let playerPhase: PlayerPhase
    switch phase {
    case .idle: playerPhase = .idle
    case .preparing: playerPhase = .preparing
    case .buffering: playerPhase = .buffering
    case .stalled: playerPhase = .stalled
    case .playing: playerPhase = .playing
    case .paused: playerPhase = .paused
    case .seeking: playerPhase = .seeking
    case .recoverableError:
      playerPhase = .failed(AudioEngineFailure(isRecoverable: true, message: "transient"))
    case .unrecoverableError:
      playerPhase = .failed(AudioEngineFailure(isRecoverable: false, message: "permanent"))
    case .ended: playerPhase = .ended
    }
    if let position { harness.player.state.globalPosition = position }
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: harness.player.intents.count + 1,
        itemId: harness.model.loadedItemID ?? "",
        episodeID: harness.model.loadedEpisodeID,
        phase: playerPhase,
        currentTime: position ?? harness.player.state.globalPosition,
        listenedDelta: 0))
    await waitUntil { harness.model.phase == phase }
  }

  private static func prepared(
    itemID: String,
    episodeID: String? = nil,
    source: PreparedPlaybackSource,
    trackCount: Int = 1
  ) -> PreparedPlayback {
    let trackDuration = 100.0 / Double(trackCount)
    let tracks = (0..<trackCount).map { index in
      PlaybackFixture.track(
        index: index,
        startOffset: Double(index) * trackDuration,
        duration: trackDuration,
        url: URL(string: "https://example.test/\(itemID)/track-\(index).mp3")!,
        mimeType: "audio/mpeg",
        title: "Track \(index + 1)")
    }
    return PlaybackFixture.prepared(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: 0,
      duration: 100,
      tracks: tracks,
      chapters: [],
      source: source)
  }

  private static func lastLoad(_ intents: [PlayerIntent]) -> (
    item: PlayerItem, initialGlobalPosition: Double, rate: Double
  )? {
    for intent in intents.reversed() {
      if case .load(let item, let initialGlobalPosition, let rate, _) = intent {
        return (item: item, initialGlobalPosition: initialGlobalPosition, rate: rate)
      }
    }
    return nil
  }

  private static func lastPromotionPosition(
    _ calls: [FakePlaybackSyncing.RecordedCall]
  ) -> Double? {
    calls.reversed().compactMap { call in
      if case .promoteStreamingSessionToLocalDownload(
        _, _, let currentPosition, _
      ) = call {
        return currentPosition
      }
      return nil
    }.first
  }

  private nonisolated static func promotionCallCount(
    _ calls: [FakePlaybackSyncing.RecordedCall]
  ) -> Int {
    calls.reduce(into: 0) { count, call in
      if case .promoteStreamingSessionToLocalDownload = call { count += 1 }
    }
  }

  private static func waitForPromotion(_ sync: FakePlaybackSyncing) async {
    await sync.waitForCalls {
      Self.promotionCallCount($0) >= 1
    }
  }

  private static func waitForNoPromotion(_ sync: FakePlaybackSyncing) async {
    let result = await awaitQuiescence(
      "promotion call count", stableFor: 10, recordingIssue: false
    ) {
      String(Self.promotionCallCount(sync.calls))
    }
    #expect(result.isObserved)
  }

  private static func waitForNoMoreThanOnePromotion(_ sync: FakePlaybackSyncing) async {
    let result = await awaitQuiescence(
      "promotion call count", stableFor: 10, recordingIssue: false
    ) {
      String(Self.promotionCallCount(sync.calls))
    }
    #expect(result.isObserved)
    #expect(Self.promotionCallCount(sync.calls) <= 1)
  }
}
