import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Rule 2 of the playback position plan: the playhead reaches a screen only through
/// `PlaybackModel.currentTime`, for the identity PlayerCore has loaded, and one resolver decides
/// the position any row prints. The retained bookmark's position is published apart from its
/// identity and metadata, so a save does not rebuild readers that never print a position.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlaybackDisplayedPositionTests {

  // MARK: - Retained bookmark split

  @Test func aSaveOfTheRetainedItemMovesItsPositionButNotTheBookmark() async {
    let (model, _, _, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 10))
    await waitUntil { model.displayedItem != nil }

    let itemInvalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.displayedItem
    } onChange: {
      itemInvalidations.count += 1
    }
    let positionInvalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.displayedItemPositionSeconds
    } onChange: {
      positionInvalidations.count += 1
    }

    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 90))
    await waitUntil { model.displayedItemPositionSeconds == 90 }

    #expect(itemInvalidations.count == 0)
    #expect(positionInvalidations.count == 1)
  }

  @Test(arguments: [
    BookmarkChange.otherItem, .otherEpisode, .finished, .title, .duration,
  ])
  func anyChangeBesidesPositionRepublishesTheBookmark(_ change: BookmarkChange) async {
    let (model, _, _, bookmarks) = Self.makeModel()
    let original = Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 10)
    bookmarks.push(original)
    await waitUntil { model.displayedItem == original }

    let changed = change.apply(to: original)
    bookmarks.push(changed)
    await waitUntil { model.displayedItem == changed }

    #expect(model.displayedItemPositionSeconds == changed.positionSeconds)
  }

  @Test func clearingTheBookmarkResetsItsPosition() async {
    let (model, _, _, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 40))
    await waitUntil { model.displayedItemPositionSeconds == 40 }

    bookmarks.push(nil)
    await waitUntil { model.displayedItem == nil }

    #expect(model.displayedItemPositionSeconds == 0)
  }

  // MARK: - Resolver

  @Test func theLoadedIdentityShowsTheLivePlayhead() async {
    let (model, player, sync, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 10))
    await waitUntil { model.displayedItem != nil }
    sync.stubStartSession(
      .success(Self.prepared(itemID: "show", episodeID: "episode-a", startPosition: 10)))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .playing, currentTime: 12.5,
        listenedDelta: 0.5))
    await waitUntil { model.currentTime == 12.5 }

    #expect(model.displayedPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 12.5)
  }

  @Test func theRetainedIdentityShowsItsSavedPosition() async {
    let (model, _, _, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 40))
    await waitUntil { model.displayedItemPositionSeconds == 40 }

    #expect(model.displayedPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 40)
  }

  @Test func anyOtherIdentityShowsItsPersistedPosition() async {
    let (model, player, sync, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 40))
    await waitUntil { model.displayedItem != nil }
    sync.stubStartSession(
      .success(Self.prepared(itemID: "show", episodeID: "episode-a", startPosition: 40)))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .playing, currentTime: 812,
        listenedDelta: 0.5))
    await waitUntil { model.currentTime == 812 }

    #expect(model.displayedPositionSeconds(itemID: "show", episodeID: "episode-b", persisted: 3) == 3)
    #expect(model.displayedPositionSeconds(itemID: "show", episodeID: nil, persisted: 4) == 4)
    #expect(model.displayedPositionSeconds(itemID: "book", episodeID: nil, persisted: 5) == 5)
  }

  @Test func aBookUsesTheSameResolverAsAnEpisode() async {
    let (model, _, _, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 70))
    await waitUntil { model.displayedItemPositionSeconds == 70 }

    #expect(model.displayedPositionSeconds(itemID: "book-1", episodeID: nil, persisted: 3) == 70)
    #expect(model.displayedPositionSeconds(itemID: "book-1", episodeID: "episode", persisted: 3) == 3)
  }

  @Test func aRowThatIsNeitherLoadedNorRetainedIsNotADependentOfThePlayhead() async {
    let (model, player, sync, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 10))
    await waitUntil { model.displayedItem != nil }
    sync.stubStartSession(
      .success(Self.prepared(itemID: "show", episodeID: "episode-a", startPosition: 10)))
    await model.start(itemID: "show", episodeID: "episode-a")

    let invalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.displayedPositionSeconds(itemID: "show", episodeID: "episode-b", persisted: 0)
    } onChange: {
      invalidations.count += 1
    }
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .playing, currentTime: 11,
        listenedDelta: 0.5))
    await waitUntil { model.currentTime == 11 }
    bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", positionSeconds: 25))
    await waitUntil { model.displayedItemPositionSeconds == 25 }

    #expect(invalidations.count == 0)
  }

  // MARK: - List cadence

  @Test func listPositionIgnoresTicksWithinAMinuteThenMovesOnce() async {
    let (model, player, _) = await Self.startPlaying(startPosition: 100)
    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 100)

    let invalidations = InvalidationCounter()
    withObservationTracking {
      _ = model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3)
    } onChange: {
      invalidations.count += 1
    }
    for (index, time) in stride(from: 100.5, through: 159.5, by: 0.5).enumerated() {
      player.pushProgress(Self.tick(sequence: 2 + index, phase: .playing, at: time))
    }
    await waitUntil { model.currentTime == 159.5 }
    #expect(invalidations.count == 0)
    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 100)

    player.pushProgress(Self.tick(sequence: 500, phase: .playing, at: 160))
    await waitUntil { model.currentTime == 160 }
    #expect(invalidations.count == 1)
    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 160)
  }

  @Test func pausingSettlesTheListPositionOnTheExactPlayhead() async {
    let (model, player, _) = await Self.startPlaying(startPosition: 100)
    player.pushProgress(Self.tick(sequence: 2, phase: .playing, at: 112))
    await waitUntil { model.currentTime == 112 }
    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 100)

    player.pushProgress(Self.tick(sequence: 3, phase: .paused, at: 113))
    await waitUntil { model.currentTime == 113 }
    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-a", persisted: 3) == 113)
  }

  @Test func loadingAnotherIdentityWhilePlayingSettlesTheListPosition() async {
    let (model, player, sync) = await Self.startPlaying(startPosition: 100)
    player.pushProgress(Self.tick(sequence: 2, phase: .playing, at: 101))
    await waitUntil { model.currentTime == 101 }

    sync.stubStartSession(
      .success(Self.prepared(itemID: "show", episodeID: "episode-b", startPosition: 130)))
    await model.start(itemID: "show", episodeID: "episode-b")

    #expect(model.listPositionSeconds(itemID: "show", episodeID: "episode-b", persisted: 3) == 130)
  }

  @Test func listPositionResolvesOtherIdentitiesLikeTheDisplayedPosition() async {
    let (model, _, _, bookmarks) = Self.makeModel()
    bookmarks.push(Self.bookmark(itemID: "book-1", positionSeconds: 70))
    await waitUntil { model.displayedItemPositionSeconds == 70 }

    #expect(model.listPositionSeconds(itemID: "book-1", episodeID: nil, persisted: 3) == 70)
    #expect(model.listPositionSeconds(itemID: "book-2", episodeID: nil, persisted: 3) == 3)
  }

  // MARK: - Fixtures

  private static func startPlaying(startPosition: Double) async -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing
  ) {
    let (model, player, sync, _) = makeModel()
    sync.stubStartSession(
      .success(prepared(itemID: "show", episodeID: "episode-a", startPosition: startPosition)))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(tick(sequence: 1, phase: .playing, at: startPosition))
    await waitUntil { model.phase == .playing }
    return (model, player, sync)
  }

  private static func tick(
    sequence: Int, phase: PlayerPhase, at time: Double, episodeID: String = "episode-a"
  ) -> PlaybackProgressEvent {
    PlaybackProgressEvent(
      sequence: sequence, itemId: "show", episodeID: episodeID, phase: phase, currentTime: time,
      listenedDelta: 0.5)
  }

  enum BookmarkChange: CaseIterable, Sendable {
    case otherItem, otherEpisode, finished, title, duration

    func apply(to bookmark: PlaybackBookmark) -> PlaybackBookmark {
      PlaybackBookmark(
        serverItemId: self == .otherItem ? "other-show" : bookmark.serverItemId,
        episodeID: self == .otherEpisode ? "episode-b" : bookmark.episodeID,
        episodeTitle: bookmark.episodeTitle, showTitle: bookmark.showTitle,
        title: self == .title ? "Renamed" : bookmark.title, author: bookmark.author,
        durationSeconds: self == .duration ? 200 : bookmark.durationSeconds,
        positionSeconds: bookmark.positionSeconds + 5,
        isFinished: self == .finished ? true : bookmark.isFinished)
    }
  }

  private static func makeModel() -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing, FakePlaybackBookmarkStoring
  ) {
    let bookmarks = FakePlaybackBookmarkStoring()
    let playback = PlaybackModelHarness(bookmarkStore: bookmarks)
    return (playback.model, playback.player, playback.sync, bookmarks)
  }

  private static func bookmark(
    itemID: String, episodeID: String? = nil, positionSeconds: Double
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, episodeID: episodeID, title: "Title \(itemID)", author: "Author",
      durationSeconds: 100, positionSeconds: positionSeconds, isFinished: false)
  }

  private static func prepared(
    itemID: String, episodeID: String?, startPosition: Double
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: startPosition, duration: 1_000,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 1_000,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg",
          title: "Track 1")
      ],
      chapters: [], source: .streaming)
  }
}

private final class InvalidationCounter: @unchecked Sendable {
  var count = 0
}
