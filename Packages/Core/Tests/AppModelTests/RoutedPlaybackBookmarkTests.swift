import ABSApi
import Foundation
import Persistence
import PlayerCore
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `PlaybackModel.start` writes its bookmark best-effort and swallows the error, so a
/// misrouted write fails silently and the only way to see it is from the model's own seam. These
/// tests drive the composed graph: a real `PlaybackModel` over the playback router and the bookmark
/// router, against the native tables.
@MainActor
@Suite("Routed playback bookmark")
struct RoutedPlaybackBookmarkTests {

  /// The failure this routing exists for: without it the account store resolves no `item` row for
  /// a device-owned episode, throws, and nothing records what was played.
  @Test func startingADeviceOwnedEpisodeRecordsIt() async throws {
    let harness = try await Harness()

    await harness.model.start(itemID: harness.itemID, episodeID: "episode")

    #expect(harness.model.activeItemID == harness.itemID)
    #expect(await waitUntil { harness.model.displayedItem?.serverItemId == harness.itemID })
    #expect(harness.model.displayedItem?.episodeID == "episode")
    #expect(harness.model.displayedItem?.title == "Episode")
    #expect(try await harness.bookmarks.fetchBookmarkedEpisodeId() == harness.episodeRowID)
    #expect(harness.absBookmarks.setBookmarkIdentityCalls.isEmpty)
  }

  /// The cold-start case, and the only one where the projection carries the identity on its own:
  /// with nothing active, `nowPlayingIdentity` is derived from `displayedItem`, so a model built
  /// over an existing device-owned marker must name the native episode rather than falling back to
  /// whatever server item the account last recorded. Asserting this on the start path above would
  /// prove nothing: `setActive` names the identity there whether or not the bookmark projects.
  @Test func aModelBuiltOverADeviceOwnedMarkerDisplaysIt() async throws {
    let harness = try await Harness()
    try await harness.bookmarks.setBookmark(
      feedId: harness.feedID, episodeID: "episode", now: Self.date(50))

    let restored = harness.makeModel()

    #expect(await waitUntil { restored.displayedItem != nil })
    #expect(restored.activeItemID == nil)
    #expect(restored.displayedItem?.serverItemId == harness.itemID)
    #expect(restored.displayedItem?.episodeID == "episode")
    let expectedIdentity = try #require(
      ListeningIdentity.rssEpisode(feedID: harness.feedID, episodeID: "episode"))
    #expect(restored.nowPlayingIdentity == expectedIdentity)
  }

  /// A finish synced from another device joins the bookmark projection, so a cold launch onto a
  /// finished native episode retains its metadata but presents nothing.
  @Test func aFinishedNativeEpisodeIsRetainedButNotPresented() async throws {
    let harness = try await Harness()
    try await harness.bookmarks.setBookmark(
      feedId: harness.feedID, episodeID: "episode", now: Self.date(50))
    _ = try await RSSEpisodeStateStore(database: harness.database).setFinished(
      episodeId: harness.episodeRowID, finished: true, now: Self.date(60))

    let restored = harness.makeModel()

    #expect(await waitUntil { restored.displayedItem != nil })
    #expect(restored.displayedItem?.serverItemId == harness.itemID)
    #expect(restored.displayedItem?.isFinished == true)
    #expect(restored.activeItemID == nil)
    #expect(restored.nowPlayingIdentity == nil)
  }

  /// A start that never reaches the player writes no bookmark, on either surface. That is the
  /// model's contract, which the router must not loosen.
  @Test func aFailedStartRecordsNothing() async throws {
    let harness = try await Harness()

    await harness.model.start(itemID: harness.itemID, episodeID: "no-such-episode")

    #expect(harness.model.activeItemID == nil)
    #expect(try await harness.bookmarks.fetchBookmarkedEpisodeId() == nil)
  }

  /// Switching origins moves the marker off the device surface, so the two surfaces cannot both
  /// claim to hold the last-played item.
  @Test func aServerStartStillRecordsAgainstTheAccount() async throws {
    let harness = try await Harness()
    harness.abs.stubStartSession(.success(Self.absPreparation))

    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    await harness.model.start(itemID: "li_book")

    #expect(
      harness.absBookmarks.setBookmarkIdentityCalls == [
        .init(itemID: "li_book", episodeID: nil)
      ])
    #expect(try await harness.bookmarks.fetchBookmarkedEpisodeId() == harness.episodeRowID)
  }

  @Test("manual RSS stop persists the final position and the next play resumes it")
  func manualStopPersistsFinalRSSPositionAndNextPlayResumesIt() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    harness.player.state.globalPosition = 42

    await harness.model.stop()

    let state = try await RSSEpisodeStateStore(database: harness.database).fetchState(
      episodeId: harness.episodeRowID)
    #expect(state?.position == 42)
    #expect(state?.localSequence == 1)

    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    let loadPositions = harness.player.intents.compactMap { intent -> Double? in
      if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
      return nil
    }
    #expect(loadPositions.last == 42)
  }

  @Test("RSS logout persists the final position before clearing the local session")
  func logoutPersistsFinalRSSPositionBeforeTeardown() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    harness.player.state.globalPosition = 57

    try await harness.model.logout()

    #expect(
      try await RSSEpisodeStateStore(database: harness.database).fetchState(
        episodeId: harness.episodeRowID)?.position == 57)
  }

  @Test("an RSS stop cannot overwrite a later position already recorded by a tick")
  func stopDoesNotRegressALaterRecordedRSSPosition() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    harness.player.state.globalPosition = 90
    harness.player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: harness.itemID, episodeID: "episode", phase: .playing,
        currentTime: 90, listenedDelta: 1))

    #expect(
      await waitUntil {
        (try? await RSSEpisodeStateStore(database: harness.database).fetchState(
          episodeId: harness.episodeRowID)?.position) == 90
      })
    harness.player.state.globalPosition = 40

    await harness.model.stop()

    #expect(
      try await RSSEpisodeStateStore(database: harness.database).fetchState(
        episodeId: harness.episodeRowID)?.position == 90)
  }

  @Test func disablingFiltersAFlushTickReEmissionFromTheRealMergedStore() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    #expect(await waitUntil { harness.model.displayedItem?.serverItemId == harness.itemID })

    harness.player.state.globalPosition = 42
    await harness.model.stopForNativeSubscriptionsDisable()
    await harness.subscriptions.setEnabled(false)
    #expect(
      await waitUntil {
        harness.model.nativeSubscriptionsEnabled == false
          && harness.model.displayedItem == nil
      })

    _ = try await RSSEpisodeStateStore(database: harness.database).recordTick(
      episodeId: harness.episodeRowID, position: 43, finished: false, capturedSequence: 1,
      now: Self.date(201))
    // The model sets `latestBookmark` and refreshes its projection in one main-actor turn, so
    // once the tick is visible the projection has already declined it.
    #expect(await waitUntil { harness.model.latestBookmark?.positionSeconds == 43 })
    #expect(harness.model.displayedItem == nil)
    #expect(harness.model.nowPlayingIdentity == nil)
  }

  @Test func coldLaunchWhileDisabledDoesNotProjectARetainedRSSBookmark() async throws {
    let harness = try await Harness()
    try await harness.bookmarks.setBookmark(
      feedId: harness.feedID, episodeID: "episode", now: Self.date(50))
    await harness.subscriptions.setEnabled(false)

    let restored = harness.makeModel()

    #expect(
      await waitUntil {
        restored.nativeSubscriptionsEnabled == false && restored.latestBookmark != nil
      })
    #expect(restored.displayedItem == nil)
    #expect(restored.nowPlayingIdentity == nil)
  }

  @Test func disablingSilentlyClearsARetainedRSSBookmark() async throws {
    let harness = try await Harness()
    try await harness.bookmarks.setBookmark(
      feedId: harness.feedID, episodeID: "episode", now: Self.date(50))
    #expect(await waitUntil { harness.model.displayedItem?.serverItemId == harness.itemID })

    await harness.subscriptions.setEnabled(false)

    #expect(await waitUntil { harness.model.displayedItem == nil })
    #expect(harness.model.activeItemID == nil)
    #expect(harness.model.nowPlayingIdentity == nil)
  }

  @Test func disablingNativeSubscriptionsKeepsAnABSBookmarkVisible() async throws {
    let harness = try await Harness()
    let absBookmarks = DefaultPlaybackBookmarkStoring(database: harness.database)
    try await absBookmarks.setBookmark(itemID: harness.absItemID)
    await harness.subscriptions.setEnabled(false)

    let restored = harness.makeModel(absBookmarks: absBookmarks)

    #expect(await waitUntil { restored.displayedItem?.serverItemId == harness.absItemID })
    #expect(restored.nowPlayingIdentity == .audiobook(itemID: harness.absItemID))
  }

  @Test func reEnablingReprojectsTheRetainedRSSBookmarkWithoutStartingPlayback() async throws {
    let harness = try await Harness()
    try await harness.bookmarks.setBookmark(
      feedId: harness.feedID, episodeID: "episode", now: Self.date(50))
    #expect(await waitUntil { harness.model.displayedItem?.serverItemId == harness.itemID })
    await harness.subscriptions.setEnabled(false)
    #expect(await waitUntil { harness.model.displayedItem == nil })

    await harness.subscriptions.setEnabled(true)

    #expect(await waitUntil { harness.model.displayedItem?.serverItemId == harness.itemID })
    #expect(harness.model.activeItemID == nil)
    #expect(harness.model.phase == .idle)
    #expect(harness.player.intents.isEmpty)
  }

  // MARK: - Harness

  private struct Harness {
    let model: PlaybackModel
    let abs: FakePlaybackSyncing
    let absBookmarks: FakePlaybackBookmarkStoring
    let bookmarks: RSSPlaybackBookmarkStore
    let player: FakePlaybackControlling
    let subscriptions: NativePodcastSubscriptionsPreference
    let itemID: String
    let absItemID: String
    let feedID: Int64
    let episodeRowID: Int64
    let database: AppDatabase
    private let episodeStore: RSSEpisodeStore

    /// A second model over the same database, for the cold-start read: `displayedItem` is only
    /// populated by the bookmark observation, so restoring it needs a model that starts with the
    /// marker already written rather than one that wrote it itself.
    @MainActor
    func makeModel(
      absBookmarks: any PlaybackBookmarkStoring = FakePlaybackBookmarkStoring()
    ) -> PlaybackModel {
      PlaybackModel(
        sync: RoutingPlaybackSyncing(
          abs: FakePlaybackSyncing(),
          rss: RSSPlaybackCoordinator(
            episodeStore: episodeStore,
            stateStore: RSSEpisodeStateStore(database: database),
            durationResolver: RSSEpisodeDurationResolver(episodeStore: episodeStore),
            feedStore: RSSFeedStore(database: database),
            credentialStore: InMemoryFeedCredentialStore(),
            now: { date(200) })),
        player: FakePlaybackControlling(),
        account: FakeAccountLifecycle(),
        appLifecycle: FakeAppLifecycle(),
        bookmarkStore: RoutingPlaybackBookmarkStoring(
          abs: absBookmarks,
          rss: bookmarks,
          reads: MergedPlaybackBookmarkReading(database: database)),
        nativePodcastSubscriptions: subscriptions)
    }

    @MainActor
    init() async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let (accountID, libraryID) = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: "user", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "library", mediaType: "book",
          name: "Library")
        try library.insert(db)
        return (account.id!, library.id!)
      }
      absItemID = "abs-book"
      let absItemID = absItemID
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountID, libraryId: libraryID, serverItemId: absItemID,
          mediaKind: "book", title: "ABS Book", sortTitle: "abs book", author: nil,
          durationSeconds: 60, numAudioFiles: 1)
        try item.insert(db)
      }
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!,
        title: "Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: date(1))
      self.feedID = feedID
      let episodeStore = RSSEpisodeStore(database: database)
      self.episodeStore = episodeStore
      _ = try await episodeStore.applyRefresh(
        feedId: feedID,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: "episode", title: "Episode", enclosureURL: episodeURL,
            enclosureType: "audio/mpeg", durationSeconds: 120)
        ])
      episodeRowID = try #require(
        try await database.readAsync { db in
          try Int64.fetchOne(
            db, sql: "SELECT id FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
        })
      itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
      bookmarks = RSSPlaybackBookmarkStore(database: database)
      player = FakePlaybackControlling()
      subscriptions = NativePodcastSubscriptionsPreference(
        defaults: FakeNativePodcastSubscriptionsDefaults())
      absBookmarks = FakePlaybackBookmarkStoring()
      abs = FakePlaybackSyncing()
      model = PlaybackModel(
        sync: RoutingPlaybackSyncing(
          abs: abs,
          rss: RSSPlaybackCoordinator(
            episodeStore: episodeStore,
            stateStore: RSSEpisodeStateStore(database: database),
            durationResolver: RSSEpisodeDurationResolver(episodeStore: episodeStore),
            feedStore: RSSFeedStore(database: database),
            credentialStore: InMemoryFeedCredentialStore(),
            now: { date(200) })),
        player: player,
        account: FakeAccountLifecycle(),
        appLifecycle: FakeAppLifecycle(),
        bookmarkStore: RoutingPlaybackBookmarkStoring(
          abs: absBookmarks,
          rss: bookmarks,
          reads: MergedPlaybackBookmarkReading(database: database)),
        nativePodcastSubscriptions: subscriptions)
    }
  }

  private nonisolated static let episodeURL = URL(string: "https://example.com/episode.mp3")!

  private nonisolated static func date(_ time: TimeInterval) -> Date {
    Date(timeIntervalSince1970: time)
  }

  private static let absPreparation = PreparedPlayback(
    itemID: "li_book",
    episodeID: nil,
    startPosition: 0,
    duration: 3_600,
    tracks: [
      PreparedPlaybackTrack(
        index: 0, startOffset: 0, duration: 3_600,
        url: URL(string: "https://books.example.test/file.m4b")!, mimeType: "audio/mp4",
        title: "Book")
    ],
    chapters: [],
    source: .streaming,
    streamAuthorization: nil)
}
