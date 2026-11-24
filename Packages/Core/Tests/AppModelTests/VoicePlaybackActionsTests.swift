import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite(.timeLimit(.minutes(1))) struct VoicePlaybackActionsTests {

  @Test func signedOutAccountOwnsNoVoicePlaybackAction() async {
    let harness = Self.makeHarness(isAuthenticated: false)
    harness.bookmarks.stubFetchBookmark(Self.bookmark(title: "Private title"))

    #expect(
      await harness.actions.resumeLastPlayed()
        == .unavailable(.accountUnavailable))
    #expect(harness.actions.pausePlayback() == .unavailable(.accountUnavailable))
    #expect(
      await harness.actions.skip(by: 30)
        == .unavailable(.accountUnavailable))
    #expect(
      harness.actions.setSleepTimer(.fifteenMinutes)
        == .unavailable(.accountUnavailable))
    #expect(
      await harness.actions.play(selection: Self.selection())
        == .unavailable(.accountUnavailable))
    #expect(harness.actions.extendSleepTimer(by: 900) == .unavailable(.accountUnavailable))
    #expect(harness.bookmarks.fetchBookmarkCallCount == 0)
    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(harness.player.intents.isEmpty)
  }

  @Test func logoutQuiescenceRejectsActionsEvenWhileTheLifecycleStillReportsAuthenticated() async {
    let harness = Self.makeHarness()
    await harness.playback.prepareForLogout()
    let intentCountAfterQuiescence = harness.player.intents.count
    harness.bookmarks.stubFetchBookmark(Self.bookmark())

    #expect(
      await harness.actions.resumeLastPlayed()
        == .unavailable(.accountUnavailable))
    #expect(harness.actions.pausePlayback() == .unavailable(.accountUnavailable))
    #expect(
      await harness.actions.skip(by: -30)
        == .unavailable(.accountUnavailable))
    #expect(
      harness.actions.setSleepTimer(.thirtyMinutes)
        == .unavailable(.accountUnavailable))
    #expect(
      await harness.actions.play(selection: Self.selection())
        == .unavailable(.accountUnavailable))
    #expect(harness.actions.extendSleepTimer(by: 900) == .unavailable(.accountUnavailable))
    #expect(harness.bookmarks.fetchBookmarkCallCount == 0)
    #expect(harness.player.intents.count == intentCountAfterQuiescence)
  }

  @Test func resumeReportsNoBookmarkWithoutStartingPlayback() async {
    let harness = Self.makeHarness()
    harness.bookmarks.stubFetchBookmark(nil)

    #expect(
      await harness.actions.resumeLastPlayed()
        == .unavailable(.noBookmark))
    #expect(harness.bookmarks.fetchBookmarkCallCount == 1)
    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(harness.player.intents.isEmpty)
  }

  @Test func coldResumeUsesTheBookmarkIdentityAndTrustsTheMergedPreparedPosition() async {
    let harness = Self.makeHarness()
    let bookmark = Self.bookmark(position: 42)
    harness.bookmarks.stubFetchBookmark(bookmark)
    harness.sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 5)))

    let result = await harness.actions.resumeLastPlayed()

    #expect(result == .performed)
    #expect(harness.playback.displayedItem == nil, "the live observation was deliberately never pushed")
    #expect(Self.startCalls(harness.sync) == [.startSession(itemID: "item-1", episodeID: nil)])
    #expect(harness.player.intents.last == .play)
    #expect(Self.seekOffsets(harness.player).isEmpty)
  }

  /// This crosses the production merged-bookmark route and the real voice action rather than
  /// stopping after proving that the route can spell an RSS id. It pins the identity handed to
  /// `PlaybackModel`, including the episode component required for a cold native resume.
  @Test func coldRSSResumeTraversesTheMergedBookmarkRouteIntoPlaybackStart() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try database.write { db in
      var feed = RSSFeedRecord(
        feedURL: "https://feeds.example.test/siri.xml", title: "Siri Show",
        author: "Siri Host", subscribedAt: Date())
      try feed.insert(db)
      let id = try #require(feed.id)
      var episode = RSSEpisodeRecord(
        feedId: id, identityKey: "episode-1", title: "Siri Episode",
        enclosureURL: "https://cdn.example.test/siri.mp3", lastSeenGeneration: 1)
      try episode.insert(db)
      return id
    }
    let rssBookmarks = RSSPlaybackBookmarkStore(database: database)
    try await rssBookmarks.setBookmark(feedId: feedID, episodeID: "episode-1")
    let bookmarks = RoutingPlaybackBookmarkStoring(
      abs: NoOpPlaybackBookmarkStoring(), rss: rssBookmarks,
      reads: MergedPlaybackBookmarkReading(database: database))
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    let sync = FakePlaybackSyncing()
    sync.stubStartSession(
      .success(
        Self.preparedPlayback(
          startPosition: 5, itemID: itemID, episodeID: "episode-1")))
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let playback = PlaybackModelHarness(
      sync: sync, account: account, bookmarkStore: bookmarks)
    let player = playback.player
    let actions = VoicePlaybackActions(
      playback: playback.model, player: playback.player, account: account,
      bookmarkStore: bookmarks)

    let result = await actions.resumeLastPlayed()

    #expect(result == .performed)
    #expect(
      Self.startCalls(sync) == [
        .startSession(itemID: itemID, episodeID: "episode-1")
      ])
    #expect(player.intents.last == .play)
  }

  @Test func coldResumeReportsStartFailedWithoutLeakingTheBookmark() async {
    let harness = Self.makeHarness()
    harness.bookmarks.stubFetchBookmark(Self.bookmark(title: "Private title"))
    harness.sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))

    let result = await harness.actions.resumeLastPlayed()

    #expect(result == .unavailable(.startFailed))
    #expect(String(describing: result).contains("Private title") == false)
    #expect(harness.player.intents.isEmpty)
  }

  @Test func resumeOfAnActiveItemDoesNotConsultTheBookmarkAndSendsPlay() async {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    let previousStartCount = Self.startCalls(harness.sync).count
    harness.bookmarks.stubFetchBookmark(Self.bookmark(itemID: "stale-item"))

    let result = await harness.actions.resumeLastPlayed()

    #expect(result == .performed)
    #expect(Self.startCalls(harness.sync).count == previousStartCount)
    #expect(harness.bookmarks.fetchBookmarkCallCount == 0)
    #expect(harness.player.intents.last == .play)
  }

  @Test func pauseRequiresActivePlaybackAndUsesExplicitPauseRatherThanToggle() async {
    let idle = Self.makeHarness()
    #expect(idle.actions.pausePlayback() == .unavailable(.noActivePlayback))
    #expect(idle.player.intents.isEmpty)

    let active = Self.makeHarness()
    await Self.loadPlayback(active)

    #expect(active.actions.pausePlayback() == .performed)
    #expect(active.player.intents.last == .pause)
    #expect(active.player.intents.contains(.toggle) == false)
  }

  @Test func coldSkipUsesTheMergedPreparedPositionRatherThanTheOlderBookmarkPosition() async {
    let harness = Self.makeHarness()
    harness.bookmarks.stubFetchBookmark(Self.bookmark(position: 10))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 80)))
    // The production PlayerController adopts `.load` synchronously. This lightweight fake only
    // records intents, so seed the post-load state the voice facade reads after `start` returns.
    harness.player.state.globalPosition = 80

    let result = await harness.actions.skip(by: -30)

    #expect(result == .performed)
    #expect(harness.playback.displayedItem == nil, "the action must not rely on observation timing")
    #expect(Self.startCalls(harness.sync) == [.startSession(itemID: "item-1", episodeID: nil)])
    #expect(harness.player.intents.last == .seek(toGlobalOffset: 50))
  }

  @Test func activeSkipUsesTheLoadedSessionWithoutConsultingTheBookmark() async {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 50,
        listenedDelta: 0))
    await waitUntil { harness.playback.currentTime == 50 }
    let previousStartCount = Self.startCalls(harness.sync).count

    let result = await harness.actions.skip(by: 30)

    #expect(result == .performed)
    #expect(Self.startCalls(harness.sync).count == previousStartCount)
    #expect(harness.bookmarks.fetchBookmarkCallCount == 0)
    #expect(harness.player.intents.last == .skip(by: 30))
  }

  @Test func activeSkipNormalizesANonFiniteDeltaBeforeItReachesPlayerCore() async {
    let harness = Self.makeHarness()
    await Self.loadPlayback(harness)
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 50,
        listenedDelta: 0))
    await waitUntil { harness.playback.currentTime == 50 }

    // Normalized to zero rather than forwarded: PlayerCore then discards it as a no-op, which is
    // the right answer for a delta Siri never meant. What matters is that no infinity crosses the
    // boundary, where it would poison the position arithmetic on the far side.
    #expect(await harness.actions.skip(by: .infinity) == .performed)
    #expect(harness.player.intents.last == .skip(by: 0))
    #expect(harness.playback.currentTime == 50)
  }

  @Test func coldSkipReportsNoBookmarkOrStartFailureExplicitly() async {
    let noBookmark = Self.makeHarness()
    noBookmark.bookmarks.stubFetchBookmark(nil)
    #expect(
      await noBookmark.actions.skip(by: 30)
        == .unavailable(.noBookmark))

    let failed = Self.makeHarness()
    failed.bookmarks.stubFetchBookmark(Self.bookmark())
    failed.sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-1")))
    #expect(
      await failed.actions.skip(by: 30)
        == .unavailable(.startFailed))
    #expect(failed.player.intents.isEmpty)
  }

  @Test func sleepTimerRequiresAnActiveItemAndRoutesItsExactDurationToPlayerCore() async {
    let idle = Self.makeHarness()
    #expect(
      idle.actions.setSleepTimer(.endOfChapter)
        == .unavailable(.noActivePlayback))
    #expect(idle.player.intents.isEmpty)

    let active = Self.makeHarness()
    await Self.loadPlayback(active)

    #expect(active.actions.setSleepTimer(.endOfChapter) == .performed)
    #expect(active.player.intents.last == .setSleepTimer(.endOfChapter))

    let chapterless = Self.makeHarness()
    await Self.loadPlayback(chapterless, chapters: [])
    let intentCountBeforeTimer = chapterless.player.intents.count

    #expect(
      chapterless.actions.setSleepTimer(.endOfChapter)
        == .unavailable(.noChapters))
    #expect(chapterless.player.intents.count == intentCountBeforeTimer)
  }

  /// A widget row names its item, so play starts that exact selection rather than the bookmark.
  @Test func playStartsTheExactSelectionWithoutConsultingTheBookmark() async throws {
    let harness = Self.makeHarness()
    harness.bookmarks.stubFetchBookmark(Self.bookmark(itemID: "bookmarked-item"))
    harness.sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, itemID: "item-2")))

    let result = await harness.actions.play(selection: Self.selection(itemID: "item-2"))

    #expect(result == .performed)
    #expect(harness.bookmarks.fetchBookmarkCallCount == 0)
    let starts = Self.startCalls(harness.sync)
    #expect(starts.count == 1)
    #expect(String(describing: try #require(starts.first)).contains("item-2"))
  }

  /// RSS preparation is episode-scoped; a selection that cannot be started is refused before any
  /// request, with the reason a stale or foreign widget row gives.
  @Test func playRefusesAnUnstartableSelectionAsItemUnavailable() async throws {
    let harness = Self.makeHarness()
    let feedWithoutEpisode = CompanionSelection(
      source: try #require(PodcastSourceIdentity.rss(feedId: 7)), episodeID: nil)

    #expect(
      await harness.actions.play(selection: feedWithoutEpisode)
        == .unavailable(.itemUnavailable))
    #expect(Self.startCalls(harness.sync).isEmpty)
    #expect(harness.player.intents.isEmpty)
  }

  @Test func playReportsAFailedPreparationAsStartFailed() async {
    let harness = Self.makeHarness()
    harness.sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("item-2")))

    #expect(
      await harness.actions.play(selection: Self.selection(itemID: "item-2"))
        == .unavailable(.startFailed))
    #expect(harness.player.intents.isEmpty)
  }

  /// PlayerCore extends a countdown only and ignores the request otherwise, so the action says so
  /// instead of reporting a change that did not happen.
  @Test func extendAddsToARunningCountdownAndRefusesEveryOtherTimer() async {
    let idle = Self.makeHarness()
    #expect(idle.actions.extendSleepTimer(by: 900) == .unavailable(.noActivePlayback))
    #expect(idle.player.intents.isEmpty)

    let active = Self.makeHarness()
    await Self.loadPlayback(active)
    let loadedIntents = active.player.intents.count

    #expect(active.actions.extendSleepTimer(by: 900) == .unavailable(.noSleepTimer))
    active.player.state.sleepTimer = SleepTimerState(mode: .endOfChapter(atPosition: 100))
    #expect(active.actions.extendSleepTimer(by: 900) == .unavailable(.noSleepTimer))
    #expect(active.player.intents.count == loadedIntents)

    active.player.state.sleepTimer = SleepTimerState(mode: .countdown(remainingSeconds: 600))
    for seconds in [0, -60, Double.nan, .infinity] {
      #expect(active.actions.extendSleepTimer(by: seconds) == .unavailable(.noSleepTimer))
    }
    #expect(active.player.intents.count == loadedIntents)

    #expect(active.actions.extendSleepTimer(by: 900) == .performed)
    #expect(active.player.intents.last == .extendSleepTimer(by: 900))
  }

  private struct Harness {
    let actions: VoicePlaybackActions
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let account: FakeAccountLifecycle
    let bookmarks: FakePlaybackBookmarkStoring
  }

  private static func makeHarness(isAuthenticated: Bool = true) -> Harness {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = isAuthenticated
    let bookmarks = FakePlaybackBookmarkStoring()
    let playback = PlaybackModelHarness(account: account, bookmarkStore: bookmarks)
    let actions = VoicePlaybackActions(
      playback: playback.model, player: playback.player, account: account,
      bookmarkStore: bookmarks)
    return Harness(
      actions: actions, playback: playback.model, player: playback.player, sync: playback.sync,
      account: account, bookmarks: bookmarks)
  }

  private static func loadPlayback(
    _ harness: Harness,
    chapters: [PreparedPlaybackChapter] = [
      PreparedPlaybackChapter(id: 1, start: 0, end: 100, title: "Chapter")
    ]
  ) async {
    harness.sync.stubStartSession(
      .success(preparedPlayback(startPosition: 0, chapters: chapters)))
    await harness.playback.start(itemID: "item-1")
    if case .load(let item, let initialGlobalPosition, let rate, _) = harness.player.intents.first {
      harness.player.state = PlayerState(
        phase: .playing, item: item, currentTrackIndex: 0,
        globalPosition: initialGlobalPosition, rate: rate, isPlaybackIntended: true)
    }
  }

  private static func selection(itemID: String = "item-1") -> CompanionSelection {
    CompanionSelection(source: PodcastSourceIdentity.abs(itemId: itemID)!)
  }

  private static func bookmark(
    itemID: String = "item-1", title: String = "Title", position: Double = 10
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, title: title, author: "Author", durationSeconds: 100,
      positionSeconds: position, isFinished: false)
  }

  private static func preparedPlayback(
    startPosition: Double,
    itemID: String = "item-1",
    episodeID: String? = nil,
    chapters: [PreparedPlaybackChapter] = [
      PreparedPlaybackChapter(id: 1, start: 0, end: 100, title: "Chapter")
    ]
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: startPosition, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/track.mp3")!, mimeType: "audio/mpeg",
          title: "Track 1")
      ],
      chapters: chapters)
  }

  private static func startCalls(
    _ sync: FakePlaybackSyncing
  ) -> [FakePlaybackSyncing.RecordedCall] {
    sync.calls.filter { call in
      guard case .startSession = call else { return false }
      return true
    }
  }

  private static func seekOffsets(_ player: FakePlaybackControlling) -> [Double] {
    player.intents.compactMap { intent in
      guard case .seek(let offset) = intent else { return nil }
      return offset
    }
  }
}
