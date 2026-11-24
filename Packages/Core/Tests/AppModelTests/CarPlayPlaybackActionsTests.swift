import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The car's action boundary: every command carries the runtime generation its row was built in,
/// and only an exact, current, account-owned selection reaches the player.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayPlaybackActionsTests {

  @Test func playStartsTheExactAudiobook() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    let result = await harness.actions.play(identity: identity, generation: 3)

    #expect(result == .accepted)
    #expect(harness.playback.isLoaded(itemID: "book-1", episodeID: nil))
  }

  @Test func playingAQueuedChapterStartsAtTheChapterAndArmsItsEnd() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    let result = await harness.actions.play(
      identity: identity,
      chapter: ListeningQueueRowChapter(rowID: 4, chapter: ListeningQueueChapter(start: 20, end: 60, title: "Two")),
      generation: 3)

    #expect(result == .accepted)
    #expect(harness.player.intents.contains(.setSegment(start: 20, end: 60)))
    guard case .load(_, let position, _, _) = harness.player.intents.first else {
      Issue.record("expected a load")
      return
    }
    #expect(position == 20)
  }

  @Test func playStartsTheExactNativeEpisode() async throws {
    let harness = Self.makeHarness()
    let identity = try #require(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "ep-1"))
    harness.sync.stubStartSession(
      .success(Self.preparedPlayback(itemID: identity.itemID, episodeID: "ep-1")))

    let result = await harness.actions.play(identity: identity, generation: 3)

    #expect(result == .accepted)
    #expect(harness.playback.isLoaded(itemID: identity.itemID, episodeID: "ep-1"))
  }

  @Test func rowFromAnEarlierGenerationIsRejectedWithoutStarting() async throws {
    let harness = Self.makeHarness()
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    let result = await harness.actions.play(identity: identity, generation: 2)

    #expect(result == .rejected(.staleGeneration))
    #expect(Self.startCalls(harness.sync).isEmpty)
  }

  @Test func facadeOfAReplacedGraphRejectsEveryAction() async throws {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    let intents = harness.player.intents
    harness.lease.current = 4
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    let chapter = try #require(harness.player.state.item?.chapters.chapters.first)

    #expect(await harness.actions.play(identity: identity, generation: 3) == .rejected(.staleGeneration))
    #expect(await harness.actions.resumeLastPlayed() == .rejected(.staleGeneration))
    #expect(
      harness.actions.selectChapter(chapter, itemID: "item-1", episodeID: nil, generation: 3)
        == .rejected(.staleGeneration))
    #expect(harness.actions.setRate(1.5, generation: 3) == .rejected(.staleGeneration))
    #expect(harness.player.intents == intents)
  }

  @Test func graphReplacedDuringPreparationIsNotAccepted() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "book-1")))
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    harness.playback.authorizePlaybackStart = { _, _ in
      harness.lease.current = 4
      return .allowed(position: nil)
    }

    let result = await harness.actions.play(identity: identity, generation: 3)

    #expect(result == .rejected(.staleGeneration))
  }

  @Test func signedOutAccountIsRejected() async throws {
    let harness = Self.makeHarness(isAuthenticated: false)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    #expect(await harness.actions.play(identity: identity, generation: 3) == .rejected(.accountUnavailable))
    #expect(await harness.actions.resumeLastPlayed() == .rejected(.accountUnavailable))
    #expect(Self.startCalls(harness.sync).isEmpty)
  }

  @Test func failedPreparationIsReportedAndNothingElseIsStarted() async throws {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("book-1")))
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-1"))

    let result = await harness.actions.play(identity: identity, generation: 3)

    #expect(result == .rejected(.preparationFailed))
    #expect(Self.startCalls(harness.sync).count == 1)
    #expect(harness.player.intents.contains(.play) == false)
  }

  @Test func resumeStartsTheBookmarkWithoutWaitingForObservation() async {
    let harness = Self.makeHarness()
    harness.bookmarks.stubFetchBookmark(
      PlaybackBookmark(
        serverItemId: "item-1", title: "Title", author: "Author", durationSeconds: 100,
        positionSeconds: 10, isFinished: false))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-1")))

    #expect(await harness.actions.resumeLastPlayed() == .accepted)
    #expect(harness.playback.isLoaded(itemID: "item-1", episodeID: nil))
  }

  @Test func resumeWithNothingToResumeSaysSo() async {
    let harness = Self.makeHarness()

    #expect(await harness.actions.resumeLastPlayed() == .rejected(.nothingToResume))
    #expect(Self.startCalls(harness.sync).isEmpty)
  }

  @Test func selectingAChapterOfTheLoadedItemSendsThatChapter() async throws {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    let chapter = try #require(harness.player.state.item?.chapters.chapters.last)

    let result = harness.actions.selectChapter(chapter, itemID: "item-1", episodeID: nil, generation: 3)

    #expect(result == .accepted)
    #expect(harness.player.intents.last == .selectChapter(chapter))
  }

  @Test func chapterRowOfAnotherItemIsRejected() async throws {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    let intents = harness.player.intents
    let chapter = try #require(harness.player.state.item?.chapters.chapters.first)

    #expect(
      harness.actions.selectChapter(chapter, itemID: "other", episodeID: nil, generation: 3)
        == .rejected(.noActivePlayback))
    #expect(
      harness.actions.selectChapter(
        PlaybackChapter(id: "9", title: "Elsewhere", start: 400, end: 500),
        itemID: "item-1", episodeID: nil, generation: 3) == .rejected(.invalidChapter))
    #expect(harness.player.intents == intents)
  }

  @Test func rateIsValidatedAndAppliedToTheLoadedItem() async {
    let harness = Self.makeHarness()
    #expect(harness.actions.setRate(1.5, generation: 3) == .rejected(.noActivePlayback))
    await Self.loadPlayback(harness)

    #expect(harness.actions.setRate(.nan, generation: 3) == .rejected(.invalidRate))
    #expect(harness.actions.setRate(1.5, generation: 3) == .accepted)
    #expect(harness.player.intents.last == .setRate(1.5))
  }

  @MainActor
  private final class Lease {
    var current = 3
  }

  private struct Harness {
    let actions: CarPlayPlaybackActions
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let bookmarks: FakePlaybackBookmarkStoring
    let lease: Lease
  }

  private static func makeHarness(isAuthenticated: Bool = true) -> Harness {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = isAuthenticated
    let bookmarks = FakePlaybackBookmarkStoring()
    let playback = PlaybackModelHarness(account: account, bookmarkStore: bookmarks)
    let lease = Lease()
    let actions = CarPlayPlaybackActions(
      generation: 3, currentGeneration: { lease.current },
      playback: playback.model, player: playback.player, account: account,
      bookmarkStore: bookmarks)
    return Harness(
      actions: actions, playback: playback.model, player: playback.player, sync: playback.sync,
      bookmarks: bookmarks, lease: lease)
  }

  private static func loadPlayback(_ harness: Harness) async {
    harness.sync.stubStartSession(
      .success(
        preparedPlayback(
          itemID: "item-1",
          chapters: [
            PreparedPlaybackChapter(id: 1, start: 0, end: 50, title: "One"),
            PreparedPlaybackChapter(id: 2, start: 50, end: 100, title: "Two"),
          ])))
    await harness.playback.start(itemID: "item-1")
    if case .load(let item, let initialGlobalPosition, let rate, _) = harness.player.intents.first {
      harness.player.state = PlayerState(
        phase: .playing, item: item, currentTrackIndex: 0,
        globalPosition: initialGlobalPosition, rate: rate, isPlaybackIntended: true)
    }
  }

  private static func preparedPlayback(
    itemID: String, episodeID: String? = nil, chapters: [PreparedPlaybackChapter] = []
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg",
          title: "Track")
      ], chapters: chapters)
  }

  private static func startCalls(_ sync: FakePlaybackSyncing) -> [FakePlaybackSyncing.RecordedCall] {
    sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }
  }
}
