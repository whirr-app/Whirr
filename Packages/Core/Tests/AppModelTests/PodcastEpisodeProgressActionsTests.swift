import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("Podcast episode progress actions")
struct PodcastEpisodeProgressActionsTests {
  @Test("marking the active episode stops before its progress write")
  func markAsFinishedStopsBeforeWritingActiveEpisode() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: 100)

    #expect(await harness.progress.playerIntentsAtMarkAsFinished.last == .stop)
    #expect(await harness.progress.actions == [.finish("show", "episode-a", 100)])
  }

  @Test("marking a sibling episode does not stop playback")
  func markAsFinishedLeavesSiblingPlaybackAlone() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-b", duration: 100)

    #expect(harness.player.intents == baseline)
    #expect(await harness.progress.actions == [.finish("show", "episode-b", 100)])
  }

  @Test("marking an episode with nothing playing still writes progress")
  func markAsFinishedWritesWithNothingPlaying() async {
    let harness = Self.makeHarness()

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: nil)

    #expect(harness.player.intents.isEmpty)
    #expect(await harness.progress.actions == [.finish("show", "episode-a", nil)])
  }

  @Test("resetting the active episode seeks after its progress reset")
  func resetProgressSeeksAfterResettingActiveEpisode() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    await harness.actions.resetProgress(itemID: "show", episodeID: "episode-a")

    #expect(await harness.progress.playerIntentsAtReset == baseline)
    #expect(harness.player.intents.last == .seek(toGlobalOffset: 0))
    #expect(await harness.progress.actions == [.reset("show", "episode-a")])
  }

  @Test("resetting a sibling episode does not seek playback")
  func resetProgressLeavesSiblingPlaybackAlone() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    await harness.actions.resetProgress(itemID: "show", episodeID: "episode-b")

    #expect(harness.player.intents == baseline)
    #expect(await harness.progress.actions == [.reset("show", "episode-b")])
  }

  /// Book surfaces (swipes, menus, multi-select) pass no episode ID; a book's session has none
  /// either, so the same identity check covers them.
  @Test("marking the active book stops before its progress write")
  func markAsFinishedStopsBeforeWritingActiveBook() async {
    let harness = Self.makeHarness()
    await harness.start(itemID: "book", episodeID: nil)

    await harness.actions.markAsFinished(itemID: "book", episodeID: nil, duration: 100)

    #expect(await harness.progress.playerIntentsAtMarkAsFinished.last == .stop)
    #expect(await harness.progress.actions == [.finish("book", nil, 100)])
  }

  @Test("resetting the active book seeks after its progress reset")
  func resetProgressSeeksAfterResettingActiveBook() async {
    let harness = Self.makeHarness()
    await harness.start(itemID: "book", episodeID: nil)
    let baseline = harness.player.intents

    await harness.actions.resetProgress(itemID: "book", episodeID: nil, category: .audiobook)

    #expect(await harness.progress.playerIntentsAtReset == baseline)
    #expect(harness.player.intents.last == .seek(toGlobalOffset: 0))
    #expect(await harness.progress.actions == [.reset("book", nil)])
  }

  @Test("marking a book leaves another item's playback alone")
  func markAsFinishedLeavesOtherItemPlaybackAlone() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(itemID: "book", episodeID: nil, duration: 100)

    #expect(harness.player.intents == baseline)
    #expect(await harness.progress.actions == [.finish("book", nil, 100)])
  }

  /// Book rows share this helper through `ItemSwipeActions`, so an eBook's reset has to reach
  /// the eBook position rather than the audio one.
  @Test("resetting an eBook resets its reading position")
  func resetProgressReachesEbookPosition() async {
    let harness = Self.makeHarness()

    await harness.actions.resetProgress(itemID: "book", episodeID: nil, category: .ebook)

    #expect(await harness.progress.actions == [.resetEbook("book")])
  }

  @Test("a failed finish keeps the error on ItemActionsModel after the required stop")
  func failedFinishUsesExistingErrorChannelWithoutHalfDisturbingPlayback() async {
    let harness = Self.makeHarness(fails: true)
    await harness.start(episodeID: "episode-a")

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: 100)

    #expect(harness.itemActions.actionErrorMessage == "Couldn't update progress. Try again.")
    #expect(harness.player.intents.last == .stop)
    #expect(harness.playback.activeItemID == nil)
    #expect(harness.playback.activeEpisodeID == nil)
  }

  @Test("the interlocked intents report the progress write's result")
  func interlockedIntentsReportResults() async {
    let harness = Self.makeHarness()
    #expect(
      await harness.actions.markAsFinished(itemID: "book", episodeID: nil, duration: 100)
        == .succeeded)
    #expect(await harness.actions.resetProgress(itemID: "book", episodeID: nil) == .succeeded)

    let failing = Self.makeHarness(fails: true)
    #expect(
      await failing.actions.markAsFinished(itemID: "book", episodeID: nil, duration: 100)
        == .failed)
    #expect(await failing.actions.resetProgress(itemID: "book", episodeID: nil) == .failed)
  }

  // MARK: - Continuation after a finish

  @Test("finishing the active episode with nothing queued stops it and leaves presence cleared")
  func finishingActiveEpisodeWithEmptyQueueClearsPresence() async {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    harness.bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", isFinished: true))

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: 100)

    #expect(harness.player.intents.contains(.stop))
    #expect(harness.playback.activeItemID == nil)
    #expect(harness.playback.loadedItemID == nil)
    #expect(await harness.progress.actions == [.finish("show", "episode-a", 100)])
    #expect(await harness.queue.peekCount == 1, "the empty queue is peeked once by the preparation")
    #expect(await harness.queue.removed.count == 1)
    #expect(await waitUntil { harness.playback.nowPlayingIdentity == nil })
  }

  @Test("finishing the active episode prepares the next queued row paused, never playing")
  func finishingActiveEpisodePreparesTheNextRowPaused() async throws {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.row(1, next)])
    harness.sync.stubStartSession(.success(Harness.prepared(itemID: "book-2", episodeID: nil)))
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: 100)

    let sent = Array(harness.player.intents.dropFirst(baseline.count))
    #expect(sent.contains(.play) == false, "finishing the title must not resume audio")
    #expect(sent.contains { if case .load = $0 { true } else { false } })
    #expect(harness.playback.loadedItemID == "book-2")
    #expect(harness.playback.loadedEpisodeID == nil)
    #expect(harness.playback.startFailure == nil)
    #expect(
      await harness.queue.removed
        == [try #require(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))])
    #expect(await harness.queue.identities.isEmpty, "the prepared row is consumed")
  }

  @Test("finishing an inactive episode stops nothing and prepares nothing")
  func finishingInactiveEpisodeLeavesTheQueueAlone() async throws {
    let harness = Self.makeHarness()
    await harness.start(episodeID: "episode-a")
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.row(1, next)])
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-b", duration: 100)

    #expect(harness.player.intents == baseline)
    #expect(await harness.queue.peekCount == 0)
    #expect(await harness.queue.removed.isEmpty)
    #expect(await harness.queue.identities == [next])
    #expect(await harness.progress.actions == [.finish("show", "episode-b", 100)])
  }

  /// A failed write leaves the title unfinished and retained, so presence stays and nothing else
  /// may be prepared over it.
  @Test("a failed finish prepares nothing and keeps the title presented")
  func failedFinishPreparesNothingAndKeepsTheTitlePresented() async throws {
    let harness = Self.makeHarness(fails: true)
    await harness.start(episodeID: "episode-a")
    harness.bookmarks.push(Self.bookmark(itemID: "show", episodeID: "episode-a", isFinished: false))
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-a"))
    await waitUntil { harness.playback.nowPlayingIdentity == identity }
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.row(1, next)])
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(
      itemID: "show", episodeID: "episode-a", duration: 100)

    #expect(Array(harness.player.intents.dropFirst(baseline.count)) == [.stop])
    #expect(await harness.queue.peekCount == 0)
    #expect(await harness.queue.identities == [next])
    #expect(harness.playback.nowPlayingIdentity == identity)
  }

  /// Book rows pass no episode ID, so the prepared identity is the book's own.
  @Test("finishing the active book prepares the next queued row paused")
  func finishingActiveBookPreparesTheNextRowPaused() async throws {
    let harness = Self.makeHarness()
    await harness.start(itemID: "book", episodeID: nil)
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.row(1, next)])
    harness.sync.stubStartSession(.success(Harness.prepared(itemID: "book-2", episodeID: nil)))
    let baseline = harness.player.intents

    await harness.actions.markAsFinished(itemID: "book", episodeID: nil, duration: 100)

    #expect(Array(harness.player.intents.dropFirst(baseline.count)).contains(.play) == false)
    #expect(harness.playback.loadedItemID == "book-2")
    #expect(await harness.queue.removed == [try #require(ListeningIdentity.audiobook(itemID: "book"))])
    #expect(await harness.progress.actions == [.finish("book", nil, 100)])
  }

  // MARK: - Harness

  private static func makeHarness(
    fails: Bool = false,
    bookmarks: FakePlaybackBookmarkStoring = FakePlaybackBookmarkStoring(),
    queue: RecordingListeningQueue = RecordingListeningQueue()
  ) -> Harness {
    let playbackHarness = PlaybackModelHarness(bookmarkStore: bookmarks, listeningQueue: queue)
    let player = playbackHarness.player
    let sync = playbackHarness.sync
    let playback = playbackHarness.model
    let progress = RecordingItemProgressIntents(player: player, fails: fails)
    let actions = ItemActionsModel(
      downloadStatus: DownloadStatusStore(downloadReading: NoOpDownloadReading()),
      downloadIntents: NoOpDownloadIntents(), progressIntents: progress,
      extrasAccess: NoOpItemDetailExtrasAccess())
    return Harness(
      actions: PodcastEpisodeProgressActions(actions: actions, playback: playback),
      itemActions: actions, playback: playback, player: player, sync: sync, progress: progress,
      bookmarks: bookmarks, queue: queue)
  }

  private static func row(_ id: Int64, _ identity: ListeningIdentity) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: false,
      chapter: nil)
  }

  private static func bookmark(
    itemID: String, episodeID: String?, isFinished: Bool
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, episodeID: episodeID, episodeTitle: episodeID,
      showTitle: episodeID.map { _ in itemID }, title: itemID, author: nil,
      durationSeconds: 100, positionSeconds: isFinished ? 100 : 40, isFinished: isFinished)
  }

  private struct Harness {
    let actions: PodcastEpisodeProgressActions
    let itemActions: ItemActionsModel
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let progress: RecordingItemProgressIntents
    let bookmarks: FakePlaybackBookmarkStoring
    let queue: RecordingListeningQueue

    func start(itemID: String = "show", episodeID: String?) async {
      sync.stubStartSession(.success(Self.prepared(itemID: itemID, episodeID: episodeID)))
      await playback.start(itemID: itemID, episodeID: episodeID)
    }

    static func prepared(itemID: String, episodeID: String?) -> PreparedPlayback {
      PlaybackFixture.prepared(
        itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
        tracks: [
          PlaybackFixture.track(
            index: 0, startOffset: 0, duration: 100,
            url: URL(string: "https://example.test/episode.mp3")!,
            mimeType: "audio/mpeg", title: episodeID ?? itemID)
        ], chapters: [])
    }
  }
}

private actor RecordingItemProgressIntents: ItemProgressIntents {
  enum Action: Equatable {
    case reset(String, String?)
    case resetEbook(String)
    case finish(String, String?, Double?)
    case continueListeningVisibility(String, String?, Bool)
  }

  private(set) var actions: [Action] = []
  private(set) var playerIntentsAtReset: [PlayerIntent] = []
  private(set) var playerIntentsAtMarkAsFinished: [PlayerIntent] = []
  private(set) var playerIntentsAtVisibilityChange: [PlayerIntent] = []

  private let player: FakePlaybackControlling
  private let fails: Bool

  init(player: FakePlaybackControlling, fails: Bool = false) {
    self.player = player
    self.fails = fails
  }

  private struct Failure: Error {}

  func resetProgress(itemID: String, episodeID: String?) async throws {
    actions.append(.reset(itemID, episodeID))
    playerIntentsAtReset = player.intents
    if fails { throw Failure() }
  }

  func resetEbookProgress(itemID: String) async throws {
    actions.append(.resetEbook(itemID))
  }

  func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {
    actions.append(.continueListeningVisibility(itemID, episodeID, isHidden))
    playerIntentsAtVisibilityChange = player.intents
    if fails { throw Failure() }
  }

  func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {
    actions.append(.finish(itemID, episodeID, duration))
    playerIntentsAtMarkAsFinished = player.intents
    if fails { throw Failure() }
  }

  func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {}
}
