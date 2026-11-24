import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The device-owned bookmark surface and the router that decides which surface a write belongs to.
@Suite struct RSSPlaybackBookmarkTests {

  // MARK: - The device-owned surface

  @Test func bookmarkingPointsAtTheNamedEpisode() async throws {
    let context = try await Context()

    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))

    #expect(try await context.store.fetchBookmarkedEpisodeId() == context.episodeA)
  }

  @Test func bookmarkingReplacesThePreviousEpisode() async throws {
    let context = try await Context()

    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-b", now: Self.date(20))

    #expect(try await context.store.fetchBookmarkedEpisodeId() == context.episodeB)
    let rows = try context.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssPlaybackBookmark")
    }
    #expect(rows == 1, "the bookmark is one row, not a history")
  }

  @Test func nothingIsBookmarkedBeforeAnythingIsPlayed() async throws {
    let context = try await Context()

    #expect(try await context.store.fetchBookmarkedEpisodeId() == nil)
    #expect(await context.router(abs: FakePlaybackBookmarkStoring()).fetchBookmark() == nil)
  }

  // MARK: - The merged projection

  /// The device surface stores no position of its own, so every field a mini player renders is
  /// either the episode's, the feed's, or joined from `rssEpisodeState` at read time.
  @Test func rssBookmarkProjectsEpisodeAndState() async throws {
    let context = try await Context()
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    _ = try await RSSEpisodeStateStore(database: context.database).recordTick(
      episodeId: context.episodeA, position: 42, finished: true, capturedSequence: 0,
      now: Self.date(11))

    let bookmark = try #require(
      await context.router(abs: FakePlaybackBookmarkStoring()).fetchBookmark())

    #expect(bookmark.serverItemId == context.itemID)
    #expect(bookmark.episodeID == "episode-a")
    #expect(bookmark.episodeTitle == "A")
    #expect(bookmark.showTitle == "Show")
    #expect(bookmark.title == "A")
    #expect(bookmark.author == "Author")
    #expect(bookmark.durationSeconds == 120)
    #expect(bookmark.positionSeconds == 42)
    #expect(bookmark.isFinished)
  }

  /// A feed that declares no duration leaves one measured from the enclosure as the only figure
  /// there is, and a mini player with no duration cannot draw a progress bar at all.
  @Test func rssBookmarkFallsBackToTheMeasuredDuration() async throws {
    let context = try await Context()
    try await RSSEpisodeStore(database: context.database).recordMeasuredDuration(
      episodeId: context.episodeB, seconds: 300)
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-b", now: Self.date(10))

    let bookmark = try #require(
      await context.router(abs: FakePlaybackBookmarkStoring()).fetchBookmark())

    #expect(bookmark.durationSeconds == 300)
  }

  /// Dynamic ad insertion makes a downloaded file and the feed differ, and the position is on the
  /// file's timeline, so the stopped player shows the file's length while the file exists and the
  /// feed's once it is gone.
  @Test func rssBookmarkPrefersTheDownloadedFilesLengthUntilItIsDeleted() async throws {
    let context = try await Context()
    let downloadID = try await RSSDownloadDurationStoreTests.downloadAndMeasure(
      context.database, episodeID: context.episodeA, seconds: 104)
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    let router = context.router(abs: FakePlaybackBookmarkStoring())

    #expect(try #require(await router.fetchBookmark()).durationSeconds == 104)

    try await RSSDownloadDurationStoreTests.deleteDownload(
      context.database, downloadID: downloadID)

    #expect(try #require(await router.fetchBookmark()).durationSeconds == 120)
  }

  /// The first play measures the file after the bookmark is already on screen, so the observed
  /// region has to cover the download row for the stopped player to pick the length up.
  @Test func measuringTheDownloadReEmitsTheBookmark() async throws {
    let context = try await Context()
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    let observations = PersistenceObservationCollector(
      context.router(abs: FakePlaybackBookmarkStoring()).observeBookmark())
    #expect(await waitUntil { observations.contains { $0?.durationSeconds == 120 } })

    try await RSSDownloadDurationStoreTests.downloadAndMeasure(
      context.database, episodeID: context.episodeA, seconds: 104)

    #expect(await waitUntil { observations.contains { $0?.durationSeconds == 104 } })
  }

  /// Nothing has been played yet on an episode that was bookmarked by a start that has not ticked.
  @Test func rssBookmarkWithoutStateDefaultsProgress() async throws {
    let context = try await Context()
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))

    let bookmark = try #require(
      await context.router(abs: FakePlaybackBookmarkStoring()).fetchBookmark())

    #expect(bookmark.positionSeconds == 0)
    #expect(bookmark.isFinished == false)
  }

  /// The merge leaves the account projection alone: an account-only install reads the same
  /// bookmark through the router.
  @Test func accountBookmarkStillProjectsThroughRouter() async throws {
    let context = try await Context()
    let abs = try await context.writeAccountBookmark(at: Self.date(20))

    let bookmark = try #require(await context.router(abs: abs).fetchBookmark())

    #expect(bookmark.serverItemId == context.absItemID)
    #expect(bookmark.title == "ABS")
  }

  /// Both directions are pinned separately: a single direction passes with the comparison inverted.
  @Test func newerRssBookmarkWinsOverAccountBookmark() async throws {
    let context = try await Context()
    let abs = try await context.writeAccountBookmark(at: Self.date(10))
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(20))

    let bookmark = try #require(await context.router(abs: abs).fetchBookmark())

    #expect(bookmark.serverItemId == context.itemID)
  }

  @Test func newerAccountBookmarkWinsOverRssBookmark() async throws {
    let context = try await Context()
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(20))
    let abs = try await context.writeAccountBookmark(at: Self.date(30))

    let bookmark = try #require(await context.router(abs: abs).fetchBookmark())

    #expect(bookmark.serverItemId == context.absItemID)
  }

  /// A tie is unreachable from `PlaybackModel.start`, which writes one surface per start. The rule
  /// exists so the projection is deterministic rather than dependent on which row SQLite reached
  /// first, and the account surface is the incumbent.
  @Test func aTieKeepsTheAccountBookmark() async throws {
    let context = try await Context()
    let abs = try await context.writeAccountBookmark(at: Self.date(20))
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(20))

    let bookmark = try #require(await context.router(abs: abs).fetchBookmark())

    #expect(bookmark.serverItemId == context.absItemID)
  }

  /// The account store keeps a bookmark row for a soft-deleted item and projects `nil` for it, on
  /// the grounds that the deletion is an inference and reversible. That decision must not reach
  /// across to the other surface: the newest row that can actually be displayed is the device's.
  @Test func softDeletedNewerAccountBookmarkDoesNotSuppressRss() async throws {
    let context = try await Context()
    let abs = try await context.writeAccountBookmark(at: Self.date(30))
    try await context.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE serverItemId = ?",
        arguments: [context.absItemID])
    }
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))

    let bookmark = try #require(await context.router(abs: abs).fetchBookmark())

    #expect(bookmark.serverItemId == context.itemID)
  }

  /// The position is joined, not stored, so the observed region has to cover `rssEpisodeState` as
  /// well as the two marker tables, or the mini player's elapsed time freezes at whatever it read
  /// when the bookmark moved.
  @Test func stateChangeReEmitsMergedBookmark() async throws {
    let context = try await Context()
    let observations = PersistenceObservationCollector(
      context.router(abs: FakePlaybackBookmarkStoring()).observeBookmark())
    #expect(await waitUntil { observations.values.isEmpty == false })

    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    #expect(await waitUntil { observations.contains { $0?.positionSeconds == 0 } })
    _ = try await RSSEpisodeStateStore(database: context.database).recordTick(
      episodeId: context.episodeA, position: 42, finished: false, capturedSequence: 0,
      now: Self.date(11))

    #expect(await waitUntil { observations.contains { $0?.positionSeconds == 42 } })
  }

  /// Switching origins mid-session: the account surface has to be in the observed region too, or a
  /// server item started after a native episode never replaces it on screen.
  @Test func anAccountWriteReEmitsOverADeviceBookmark() async throws {
    let context = try await Context()
    let (itemID, absItemID) = (context.itemID, context.absItemID)
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))
    let abs = DefaultPlaybackBookmarkStoring(database: context.database)
    let observations = PersistenceObservationCollector(
      context.router(abs: abs).observeBookmark())
    #expect(await waitUntil { observations.contains { $0?.serverItemId == itemID } })

    _ = try await context.writeAccountBookmark(at: Self.date(20))

    #expect(await waitUntil { observations.contains { $0?.serverItemId == absItemID } })
  }

  /// An episode id that no longer resolves is a caller-side mistake or a race with a feed refresh.
  /// It is never recorded as "last played" and never silently dropped.
  @Test func anUnresolvedEpisodeIsReported() async throws {
    let context = try await Context()

    await #expect(
      throws: RSSPlaybackBookmarkStoreError.unknownEpisode(
        feedId: context.feedID, episodeID: "gone")
    ) {
      try await context.store.setBookmark(
        feedId: context.feedID, episodeID: "gone", now: Self.date(10))
    }
    #expect(try await context.store.fetchBookmarkedEpisodeId() == nil)
  }

  @Test func aFeedWithoutAnEpisodeIsReported() async throws {
    let context = try await Context()

    await #expect(
      throws: RSSPlaybackBookmarkStoreError.missingEpisodeID(feedId: context.feedID)
    ) {
      try await context.store.setBookmark(
        feedId: context.feedID, episodeID: nil, now: Self.date(10))
    }
  }

  /// Reaping an episode, or unsubscribing its feed, takes the bookmark with it, as the account's
  /// bookmark goes with its item cascade.
  @Test func reapingTheEpisodeTakesTheBookmarkWithIt() async throws {
    let context = try await Context()
    try await context.store.setBookmark(
      feedId: context.feedID, episodeID: "episode-a", now: Self.date(10))

    try await context.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM rssEpisode WHERE id = ?", arguments: [context.episodeA])
    }

    #expect(try await context.store.fetchBookmarkedEpisodeId() == nil)
  }

  // MARK: - Routing

  @Test func aServerItemGoesToTheAccountBookmark() async throws {
    let context = try await Context()
    let abs = FakePlaybackBookmarkStoring()
    let router = context.router(abs: abs)

    try await router.setBookmark(itemID: "li_book", episodeID: nil)

    #expect(
      abs.setBookmarkIdentityCalls == [.init(itemID: "li_book", episodeID: nil)])
    #expect(try await context.store.fetchBookmarkedEpisodeId() == nil)
  }

  /// The failure this router exists for: a device-owned episode resolves no `item` row, so the
  /// account store would throw.
  @Test func aDeviceOwnedEpisodeGoesToTheDeviceBookmark() async throws {
    let context = try await Context()
    let abs = FakePlaybackBookmarkStoring()
    let router = context.router(abs: abs)

    try await router.setBookmark(itemID: context.itemID, episodeID: "episode-a")

    #expect(try await context.store.fetchBookmarkedEpisodeId() == context.episodeA)
    #expect(abs.setBookmarkIdentityCalls.isEmpty, "the account's bookmark is untouched")
  }

  /// The playback router makes the same call: an id carrying the reserved prefix that does not
  /// decode stays on the server path, where it is reported as unresolved rather than quietly
  /// becoming a device-owned write.
  @Test func aMalformedReservedIdStaysOnTheServerPath() async throws {
    let context = try await Context()
    let abs = FakePlaybackBookmarkStoring()
    let router = context.router(abs: abs)

    try await router.setBookmark(itemID: "rss:007", episodeID: "episode-a")

    #expect(abs.setBookmarkIdentityCalls == [.init(itemID: "rss:007", episodeID: "episode-a")])
    #expect(try await context.store.fetchBookmarkedEpisodeId() == nil)
  }

  /// A native show is not itself playable, so an item-level write against one is a bug worth
  /// reporting rather than a bookmark pointing at a whole feed.
  @Test func anItemLevelWriteAgainstANativeShowIsReported() async throws {
    let context = try await Context()
    let router = context.router(abs: FakePlaybackBookmarkStoring())

    await #expect(
      throws: RSSPlaybackBookmarkStoreError.missingEpisodeID(feedId: context.feedID)
    ) {
      try await router.setBookmark(itemID: context.itemID)
    }
  }

  @Test func readsProjectTheDeviceBookmark() async throws {
    let context = try await Context()
    let abs = FakePlaybackBookmarkStoring()
    abs.stubFetchBookmark(
      PlaybackBookmark(
        serverItemId: "li_book", title: "Book", author: nil, durationSeconds: 60,
        positionSeconds: 0, isFinished: false))
    let router = context.router(abs: abs)
    try await router.setBookmark(itemID: context.itemID, episodeID: "episode-a")

    let bookmark = await router.fetchBookmark()

    #expect(bookmark?.serverItemId == context.itemID)
    #expect(bookmark?.episodeID == "episode-a")
    #expect(abs.fetchBookmarkCallCount == 0)
  }

  // MARK: - Context

  private struct Context {
    let database: AppDatabase
    let store: RSSPlaybackBookmarkStore
    let feedID: Int64
    let itemID: String
    let episodeA: Int64
    let episodeB: Int64
    let absItemID: String

    func router(abs: any PlaybackBookmarkStoring) -> RoutingPlaybackBookmarkStoring {
      RoutingPlaybackBookmarkStoring(
        abs: abs, rss: store, reads: MergedPlaybackBookmarkReading(database: database))
    }

    init() async throws {
      database = try AppDatabase.inMemory()
      store = RSSPlaybackBookmarkStore(database: database)
      let accountAndLibrary = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: "user-1", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
        try library.insert(db)
        return (account.id!, library.id!)
      }
      absItemID = "abs-book"
      let absItemID = absItemID
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountAndLibrary.0, libraryId: accountAndLibrary.1, serverItemId: absItemID,
          mediaKind: "book", title: "ABS", sortTitle: "abs", author: nil,
          durationSeconds: 60, numAudioFiles: 1)
        try item.insert(db)
      }
      let feed = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://example.com/feed.xml")!, title: "Show", author: "Author",
        synopsis: nil, artworkURL: nil, subscribedAt: RSSPlaybackBookmarkTests.date(1))
      feedID = feed
      itemID = try #require(PodcastSourceIdentity.rss(feedId: feed)).itemId
      _ = try await RSSEpisodeStore(database: database).applyRefresh(
        feedId: feed,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: "episode-a", title: "A",
            enclosureURL: URL(string: "https://example.com/a.mp3")!, enclosureType: "audio/mpeg",
            durationSeconds: 120),
          RSSEpisodeUpsert(
            identityKey: "episode-b", title: "B",
            enclosureURL: URL(string: "https://example.com/b.mp3")!, enclosureType: "audio/mpeg"),
        ])
      let identifiers = try await database.readAsync { db in
        try Int64.fetchAll(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? ORDER BY identityKey",
          arguments: [feed])
      }
      episodeA = try #require(identifiers.first)
      episodeB = try #require(identifiers.last)
    }

    func writeAccountBookmark(at date: Date) async throws -> DefaultPlaybackBookmarkStoring {
      let store = DefaultPlaybackBookmarkStoring(database: database)
      try await store.setBookmark(itemID: absItemID)
      try await database.writeAsync { db in
        try db.execute(sql: "UPDATE playbackBookmark SET updatedAt = ?", arguments: [date])
      }
      return store
    }
  }

  private static func date(_ time: TimeInterval) -> Date {
    Date(timeIntervalSince1970: time)
  }
}
