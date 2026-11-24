import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct CompanionPlaybackActionsTests {

  @Test func signedOutAccountRejectsWithoutStarting() async throws {
    let harness = Self.makeHarness(isAuthenticated: false)
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))

    #expect(
      await harness.actions.start(.init(source: selection))
        == .rejected(.accountUnavailable))
    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(harness.player.intents.isEmpty)
  }

  @Test func cancellationIsRejectedBeforeAnySourceRouterCall() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    let task = Task { @MainActor in
      await harness.actions.start(.init(source: selection))
    }
    task.cancel()

    #expect(await task.value == .rejected(.cancelled))
    #expect(Self.startCalls(harness.sync).isEmpty)
  }

  @Test func acceptedMeansPreparedIdentityOnlyAndDoesNotClaimPlaying() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))

    let result = await harness.actions.start(.init(source: selection))

    #expect(result == .accepted)
    #expect(harness.playback.isLoaded(itemID: "book-1", episodeID: nil))
    // The fake records the play intent but does not claim that the engine reached `.playing`.
    #expect(harness.player.state.phase != .playing)
    #expect(harness.player.intents.contains(.play))
  }

  @Test func deniedRestartOfLoadedSelectionIsRejectedAndCanRetry() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: selection)) == .accepted)
    let intents = harness.player.intents
    let starts = Self.startCalls(harness.sync)
    harness.playback.authorizePlaybackStart = { _, _ in .denied(message: "Ownership unavailable") }

    #expect(await harness.actions.start(.init(source: selection)) == .rejected(.preparationFailed))
    #expect(harness.player.intents == intents)
    #expect(Self.startCalls(harness.sync) == starts)
    #expect(harness.playback.startFailureMessage == "Ownership unavailable")

    harness.playback.authorizePlaybackStart = { _, _ in .allowed(position: nil) }
    #expect(await harness.actions.start(.init(source: selection)) == .accepted)
    #expect(harness.playback.startFailure == nil)
  }

  @Test func failedPreparationIsRejectedAndNeverSendsPlayerControl() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("book-1")))

    let result = await harness.actions.start(.init(source: selection))

    #expect(result == .rejected(.preparationFailed))
    #expect(harness.playback.isLoaded(itemID: "book-1", episodeID: nil) == false)
    #expect(harness.player.intents.contains(.play) == false)
  }

  @Test func nativeEpisodeUsesRSSRouteAndNeverCallsABS() async throws {
    let abs = FakePlaybackSyncing()
    abs.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("rss:7")))
    let rss = FakePlaybackSyncing()
    let feed = try #require(PodcastSourceIdentity.rss(feedId: 7))
    rss.stubStartSession(.success(Self.preparedPlayback(itemID: feed.itemId, episodeID: "ep-1")))
    let player = FakePlaybackControlling()
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let routing = RoutingPlaybackSyncing(abs: abs, rss: rss)
    let playback = PlaybackModel(
      sync: routing, player: player, account: account, appLifecycle: FakeAppLifecycle())
    let actions = CompanionPlaybackActions(playback: playback, player: player, account: account)

    let result = await actions.start(.init(source: feed, episodeID: "ep-1"))

    #expect(result == .accepted)
    #expect(Self.startCalls(abs).isEmpty)
    #expect(Self.startCalls(rss) == [.startSession(itemID: feed.itemId, episodeID: "ep-1")])
  }

  @Test func rssSelectionWithoutEpisodeIsRejectedBeforeRouting() async throws {
    let harness = Self.makeHarness()
    let feed = try #require(PodcastSourceIdentity.rss(feedId: 7))

    let result = await harness.actions.start(.init(source: feed))
    #expect(result == .rejected(.invalidSelection))
    #expect(harness.sync.calls.isEmpty)
  }

  @Test func pauseResumeSeekAndRateAreIdempotentAndValidated() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: selection)) == .accepted)

    #expect(harness.actions.pause() == .accepted)
    #expect(harness.actions.pause() == .accepted)
    #expect(harness.actions.resume() == .accepted)
    #expect(harness.actions.resume() == .accepted)
    #expect(harness.actions.seek(toGlobalOffset: 12.5) == .accepted)
    #expect(harness.actions.seek(toGlobalOffset: -.infinity) == .rejected(.invalidPosition))
    #expect(harness.actions.setRate(1.5) == .accepted)
    #expect(harness.actions.setRate(.infinity) == .rejected(.invalidRate))
    #expect(harness.player.intents.contains(.pause))
    #expect(harness.player.intents.contains(.play))
    #expect(harness.player.intents.contains(.seek(toGlobalOffset: 12.5)))
    #expect(harness.player.intents.contains(.setRate(1.5)))
  }

  @Test func controlsRejectWhenNothingIsLoaded() {
    let harness = Self.makeHarness()

    #expect(harness.actions.pause() == .rejected(.noActivePlayback))
    #expect(harness.actions.resume() == .rejected(.noActivePlayback))
    #expect(harness.actions.seek(toGlobalOffset: 10) == .rejected(.noActivePlayback))
    #expect(harness.actions.setRate(1.0) == .rejected(.noActivePlayback))
    #expect(harness.player.intents.isEmpty)
  }

  /// The delta is bounded here, the target is not. Clamping a target to the timeline here would
  /// stop the Watch card finishing an item by skipping off its end, so the relative intent is
  /// forwarded and PlayerCore owns that rule for every surface.
  @Test func relativeSkipBoundsItsInputAndForwardsTheRelativeIntent() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: selection)) == .accepted)
    harness.player.state.globalPosition = 170
    #expect(harness.actions.skip(by: 30) == .accepted)
    #expect(harness.player.intents.last == .skip(by: 30))
    harness.player.state.globalPosition = 10
    #expect(harness.actions.skip(by: -30) == .accepted)
    #expect(harness.player.intents.last == .skip(by: -30))
    #expect(harness.actions.skip(by: 301) == .rejected(.invalidPosition))
    #expect(harness.actions.skip(by: .nan) == .rejected(.invalidPosition))
    #expect(harness.actions.skip(by: 0) == .rejected(.invalidPosition))
  }

  /// A live position the phone has not resolved yet cannot be skipped from: the far side would add
  /// the delta to a non-finite position and produce a target that is not a time at all.
  @Test func relativeSkipRejectsANonFiniteLivePosition() async throws {
    let harness = Self.makeHarness()
    let selection = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: selection)) == .accepted)
    let intentsBefore = harness.player.intents.count

    harness.player.state.globalPosition = .nan

    #expect(harness.actions.skip(by: 30) == .rejected(.invalidPosition))
    #expect(harness.player.intents.count == intentsBefore)
  }

  @Test func companionChapterProgressUsesMatchingLiveItemAndBoundary() async throws {
    let harness = Self.makeHarness()
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: source)) == .accepted)
    let timeline = try PlaybackTimeline(tracks: [.init(index: 0, startOffset: 0, duration: 100)])
    harness.player.state.item = PlayerItem(
      id: "book-1", timeline: timeline,
      chapters: .init(chapters: [.init(start: 0, end: 30), .init(start: 30, end: 100)]))
    harness.player.state.globalPosition = 35
    #expect(harness.playback.companionPlaybackProgress?.position == 35)
    #expect(harness.playback.companionPlaybackProgress?.chapter?.start == 30)
    #expect(harness.playback.companionPlaybackProgress?.chapter?.title == "Chapter 2")
    harness.player.state.globalPosition = 30
    #expect(harness.playback.companionPlaybackProgress?.chapter?.start == 30)
    harness.player.state.globalPosition = 29
    #expect(harness.playback.companionPlaybackProgress?.chapter?.start == 0)
    harness.playback.setActive(itemID: "other", episodeID: nil)
    #expect(harness.playback.companionPlaybackProgress == nil)
  }

  /// The Watch's focus rule weighs the phone's own last listen to its loaded title. Loading
  /// it or a tick with nothing heard does not count, and the stamp never names another title.
  @Test func companionLastListenedFollowsThePhonesOwnListening() async throws {
    let harness = Self.makeHarness()
    let source = try #require(PodcastSourceIdentity.abs(itemId: "book-1"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    #expect(await harness.actions.start(.init(source: source)) == .accepted)
    #expect(harness.playback.companionLastListenedAt == nil)

    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "book-1", episodeID: nil, phase: .paused, currentTime: 5, listenedDelta: 0))
    await waitUntil { harness.playback.currentTime == 5 }
    #expect(harness.playback.companionLastListenedAt == nil)

    let before = Date()
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "book-1", episodeID: nil, phase: .playing, currentTime: 6, listenedDelta: 1))
    await waitUntil { harness.playback.currentTime == 6 }
    let stamp = try #require(harness.playback.companionLastListenedAt)
    #expect(stamp >= before && stamp <= Date())

    harness.playback.setActive(itemID: "other", episodeID: nil)
    #expect(harness.playback.companionLastListenedAt == nil)
  }

  private struct Harness {
    let actions: CompanionPlaybackActions
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
  }

  private static func makeHarness(isAuthenticated: Bool = true) -> Harness {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = isAuthenticated
    let playback = PlaybackModelHarness(account: account)
    let actions = CompanionPlaybackActions(
      playback: playback.model, player: playback.player, account: account)
    return Harness(
      actions: actions, playback: playback.model, player: playback.player, sync: playback.sync)
  }

  private static func preparedPlayback(itemID: String, episodeID: String? = nil) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg",
          title: "Track")
      ], chapters: [])
  }

  private static func startCalls(
    _ sync: FakePlaybackSyncing
  ) -> [FakePlaybackSyncing.RecordedCall] {
    sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
  }
}
