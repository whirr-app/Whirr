import Foundation
import GRDB
import Testing

@testable import Persistence

/// The SQL behind `SmartListDownloadReconciler`: the wanted set, the claims, the request-time
/// "any download row" probe, the shared "kept besides" check, hidden-row pruning.
@Suite struct SmartListDownloadStoreTests {

  // MARK: - Wanted set

  @Test func wantedIsTheTopNOfEveryAutoDownloadingListAndNothingFromTheOthers() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    for index in 1...7 {
      try await world.native(feed: feed, "e\(index)", published: SmartListReadingWorld.at(Double(index)))
    }
    let showsAll = try await world.list(SmartListRules(autoDownload: true, autoDownloadLimit: .five))
    _ = try await world.list(SmartListRules(autoDownload: false))
    let second = try await world.list(SmartListRules(autoDownload: true, autoDownloadLimit: .five))

    let wanted = try await world.store().wantedEpisodes()

    #expect(wanted.map(\.listID) == Array(repeating: showsAll, count: 5) + Array(repeating: second, count: 5))
    #expect(wanted.prefix(5).map(\.episodeID) == ["e7", "e6", "e5", "e4", "e3"])
    #expect(wanted.allSatisfy { $0.source == .native && $0.itemID == "rss:\(feed)" })
  }

  @Test func aFinishedEpisodeLeavesTheWantedSetAndTheNextTakesItsPlace() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    var rows: [Int64] = []
    for index in 1...6 {
      rows.append(try await world.native(feed: feed, "e\(index)", published: SmartListReadingWorld.at(Double(index))))
    }
    _ = try await world.list(SmartListRules(autoDownload: true, autoDownloadLimit: .five))
    #expect(try await world.store().wantedEpisodes().map(\.episodeID) == ["e6", "e5", "e4", "e3", "e2"])

    try await world.nativeProgress(rows[5], position: 1_800, finished: true)

    #expect(try await world.store().wantedEpisodes().map(\.episodeID) == ["e5", "e4", "e3", "e2", "e1"])
  }

  @Test func theNativeHalfIsEmptyWhileNativeSubscriptionsAreOff() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    _ = try await world.list(SmartListRules(autoDownload: true))

    #expect(try await world.store(nativeEnabled: false).wantedEpisodes().isEmpty)
  }

  @Test func theWantedSetEmitsWhenMembershipChanges() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    _ = try await world.list(SmartListRules(autoDownload: true))
    var changes = await world.store().observeWantedEpisodes().makeAsyncIterator()

    #expect(try #require(await changes.next()).map(\.episodeID) == ["e1"])
    try await world.native(feed: feed, "e2", published: SmartListReadingWorld.at(2))
    #expect(try #require(await changes.next()).map(\.episodeID) == ["e2", "e1"])
  }

  // MARK: - Claims and download rows

  @Test func claimsAreSharedAcrossListsAndHasClaimCanLeaveOneListOut() async throws {
    let world = try await SmartListReadingWorld.make()
    let first = try await world.list()
    let second = try await world.list()
    let store = world.store()

    #expect(try await store.hasClaim(itemID: "rss:1", episodeID: "e1") == false)
    try await store.recordClaim(listID: first, itemID: "rss:1", episodeID: "e1", accountID: nil, at: Date())
    #expect(try await store.hasClaim(itemID: "rss:1", episodeID: "e1"))
    #expect(try await store.hasClaim(itemID: "rss:1", episodeID: "e1", excluding: first) == false)
    try await store.recordClaim(listID: second, itemID: "rss:1", episodeID: "e1", accountID: nil, at: Date())
    #expect(try await store.hasClaim(itemID: "rss:1", episodeID: "e1", excluding: first))
    try await store.dropClaim(listID: second, itemID: "rss:1", episodeID: "e1")
    #expect(try await store.claims().count == 1)
  }

  @Test func anyDownloadRowOfAnyStateCountsForBothSources() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let feed = try await world.feed("https://a.example/feed")
    let native = try await world.native(feed: feed, "e1")
    let show = try await world.show("show")
    let server = try await world.server(show: show, "s1")
    let store = world.store()

    #expect(try await store.hasDownloadRow(itemID: "rss:\(feed)", episodeID: "e1", accountID: nil) == false)
    #expect(try await store.hasDownloadRow(itemID: "show", episodeID: "s1", accountID: accountId) == false)

    try await world.nativeDownload(native, state: .failed)
    try await world.serverDownload(show: show, episode: server)

    #expect(try await store.hasDownloadRow(itemID: "rss:\(feed)", episodeID: "e1", accountID: nil))
    #expect(try await store.hasDownloadRow(itemID: "show", episodeID: "s1", accountID: accountId))
    #expect(try await store.hasDownloadRow(itemID: "show", episodeID: "s1", accountID: nil) == false)
  }

  // MARK: - Shared "kept besides" check

  @Test func aServerEpisodeIsKeptByUpNextSavedPinPlaybackOrATransferAndOtherwiseNot() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let show = try await world.show("show")
    let kept = { (id: String) async throws -> Bool in
      try await world.store().isKeptBesidesClaims(itemID: "show", episodeID: id, accountID: accountId)
    }
    let queued = try await world.server(show: show, "queued")
    let saved = try await world.server(show: show, "saved")
    let playing = try await world.server(show: show, "playing")
    let transferring = try await world.server(show: show, "transferring")
    _ = try await world.server(show: show, "pinned")
    _ = try await world.server(show: show, "free")

    #expect(try await kept("free") == false)
    try await world.serverQueue(show: show, episode: queued)
    try await world.serverSave(show: show, episode: saved)
    try await world.serverPlayback(show: show, episode: playing)
    try await world.serverTransfer(show: show, episode: transferring, state: "downloading")
    try await world.pin(items: [("show", "pinned")])

    for id in ["queued", "saved", "playing", "transferring", "pinned"] {
      #expect(try await kept(id), "\(id) is kept")
    }
    #expect(try await kept("free") == false)
  }

  @Test func aNativeEpisodeIsKeptByUpNextSavedActivePlaybackOrATransferAndOtherwiseNot() async throws {
    let world = try await SmartListReadingWorld.make(signedIn: false)
    let feed = try await world.feed("https://a.example/feed")
    let queued = try await world.native(feed: feed, "queued")
    let saved = try await world.native(feed: feed, "saved")
    let playing = try await world.native(feed: feed, "playing")
    let transferring = try await world.native(feed: feed, "transferring")
    try await world.native(feed: feed, "free")
    try await world.nativeQueue(queued)
    try await world.nativeSave(saved)
    try await world.nativeDownload(transferring, state: .downloading)
    let store = world.store(activeNative: [playing])
    let kept = { (id: String) async throws -> Bool in
      try await store.isKeptBesidesClaims(itemID: "rss:\(feed)", episodeID: id, accountID: nil)
    }

    for id in ["queued", "saved", "playing", "transferring"] {
      #expect(try await kept(id), "\(id) is kept")
    }
    #expect(try await kept("free") == false)
    // A completed download of the episode keeps nothing by itself.
    try await world.nativeDownload(try await world.native(feed: feed, "done"), state: .completed)
    #expect(try await kept("done") == false)
  }

  @Test func theNativeCheckIgnoresASavedAndQueuedEpisodeOfAnotherFeed() async throws {
    let world = try await SmartListReadingWorld.make(signedIn: false)
    let one = try await world.feed("https://a.example/feed")
    let two = try await world.feed("https://b.example/feed")
    let other = try await world.native(feed: two, "e1")
    try await world.nativeQueue(other)
    try await world.native(feed: one, "e1")

    #expect(try await world.store().isKeptBesidesClaims(itemID: "rss:\(one)", episodeID: "e1", accountID: nil) == false)
    #expect(try await world.store().isKeptBesidesClaims(itemID: "rss:\(two)", episodeID: "e1", accountID: nil))
  }

  @Test func aPinnedListRelease_isKeptByASmartListClaimAndNotWithout() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let show = try await world.show("show")
    try await world.server(show: show, "ep-1")
    let list = try await world.list()
    let pins = PinnedListStore(database: world.database)
    let member = PinnedListMember(serverItemID: "show", serverEpisodeID: "ep-1")

    #expect(try await pins.isKeptBesidesPins(accountID: accountId, member: member) == false)
    try await world.store().recordClaim(
      listID: list, itemID: "show", episodeID: "ep-1", accountID: accountId, at: Date())
    #expect(try await pins.isKeptBesidesPins(accountID: accountId, member: member))
  }

  // MARK: - Hidden rows

  @Test func hiddenRowsAreDroppedOnceTheEpisodeIsFinishedOrGoneAndOtherwiseKept() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    let finished = try await world.native(feed: feed, "finished")
    try await world.native(feed: feed, "live")
    try await world.nativeProgress(finished, position: 10, finished: true)
    let show = try await world.show("show")
    let serverFinished = try await world.server(show: show, "s-finished")
    try await world.server(show: show, "s-live")
    try await world.serverProgress(show: show, episode: serverFinished, position: 10, finished: true)
    let list = try await world.list()
    let hidden = SmartListHiddenEpisodeStore(database: world.database)
    for (item, episode) in [
      ("rss:\(feed)", "finished"), ("rss:\(feed)", "live"), ("rss:\(feed)", "gone"),
      ("show", "s-finished"), ("show", "s-live"), ("unknown-show", "x"),
    ] {
      try await hidden.hide(listID: list, itemID: item, episodeID: episode)
    }

    #expect(try await world.store().pruneHiddenEpisodes() == 3)

    let left = try await hidden.hiddenEpisodes(listID: list).map(\.episodeID).sorted()
    #expect(left == ["live", "s-live", "x"])
  }

  // MARK: - Declines

  @Test func aDeclineWritesOnlyWhatAListWantsAndReturnsIt() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    for index in 1...6 {
      try await world.native(feed: feed, "e\(index)", published: SmartListReadingWorld.at(Double(index)))
    }
    _ = try await world.list(SmartListRules(autoDownload: true, autoDownloadLimit: .five))
    _ = try await world.list(SmartListRules(autoDownload: true, autoDownloadLimit: .five))
    let store = world.store()

    let unwanted = try await store.declineWanted(itemID: "rss:\(feed)", episodeID: "e1", accountID: nil, at: Date())
    let wanted = try await store.declineWanted(itemID: "rss:\(feed)", episodeID: "e3", accountID: nil, at: Date())

    #expect(unwanted.isEmpty)
    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "e1") == false)
    // Two lists want e3; it is declined once.
    #expect(wanted == [SmartListEpisodeIdentity(itemID: "rss:\(feed)", episodeID: "e3")])
    #expect(try await store.requestState(itemID: "rss:\(feed)", episodeID: "e3", accountID: nil) == .declined)
  }

  @Test func anItemOrRemoveAllDeclinesEveryWantedEpisodeItCovers() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    try await world.native(feed: feed, "e2", published: SmartListReadingWorld.at(2))
    let show = try await world.show("show")
    try await world.server(show: show, "s1")
    _ = try await world.list(SmartListRules(autoDownload: true))
    let store = world.store()

    let item = try await store.declineWanted(itemID: "rss:\(feed)", episodeID: nil, accountID: accountId, at: Date())
    #expect(Set(item.map(\.episodeID)) == ["e1", "e2"])
    #expect(try await store.isDeclined(itemID: "show", episodeID: "s1") == false)

    let all = try await store.declineWanted(itemID: nil, episodeID: nil, accountID: accountId, at: Date())
    #expect(Set(all.map(\.episodeID)) == ["e1", "e2", "s1"])
    #expect(try await store.isDeclined(itemID: "show", episodeID: "s1"))
  }

  @Test func withNoAccountOnlyNativeEpisodesAreDeclined() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    let show = try await world.show("show")
    try await world.server(show: show, "s1")
    _ = try await world.list(SmartListRules(autoDownload: true))

    let declined = try await world.store().declineWanted(itemID: nil, episodeID: nil, accountID: nil, at: Date())

    #expect(declined == [SmartListEpisodeIdentity(itemID: "rss:\(feed)", episodeID: "e1")])
  }

  @Test func droppingClaimsRemovesEveryListsClaimOnThoseEpisodesOnly() async throws {
    let world = try await SmartListReadingWorld.make()
    let first = try await world.list()
    let second = try await world.list()
    let store = world.store()
    for list in [first, second] {
      try await store.recordClaim(listID: list, itemID: "rss:1", episodeID: "e1", accountID: nil, at: Date())
    }
    try await store.recordClaim(listID: first, itemID: "rss:1", episodeID: "e2", accountID: nil, at: Date())

    try await store.dropClaims(episodes: [SmartListEpisodeIdentity(itemID: "rss:1", episodeID: "e1")])

    #expect(try await store.claims().map(\.episodeID) == ["e2"])
  }

  @Test func aClearedDeclineMakesTheEpisodeRequestableAgain() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    try await world.native(feed: feed, "e2", published: SmartListReadingWorld.at(2))
    _ = try await world.list(SmartListRules(autoDownload: true))
    let store = world.store()
    try await store.declineWanted(itemID: nil, episodeID: nil, accountID: nil, at: Date())

    try await store.clearDecline(itemID: "rss:\(feed)", episodeID: "e1")
    #expect(try await store.requestState(itemID: "rss:\(feed)", episodeID: "e1", accountID: nil) == .requestable)
    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "e2"))

    try await store.clearDecline(itemID: "rss:\(feed)", episodeID: nil)
    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "e2") == false)
  }

  @Test func declinesAreDroppedOnceTheEpisodeIsFinishedOrGoneAndOutliveTheirList() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    let finished = try await world.native(feed: feed, "finished", published: SmartListReadingWorld.at(1))
    try await world.native(feed: feed, "live", published: SmartListReadingWorld.at(2))
    let show = try await world.show("show")
    let serverFinished = try await world.server(show: show, "s-finished")
    try await world.server(show: show, "s-live")
    let list = try await world.list(SmartListRules(autoDownload: true))
    let store = world.store()
    try await store.declineWanted(itemID: nil, episodeID: nil, accountID: world.accountId, at: Date())
    try await SmartListStore(database: world.database).delete(id: list)
    try await world.nativeProgress(finished, position: 10, finished: true)
    try await world.serverProgress(show: show, episode: serverFinished, position: 10, finished: true)

    #expect(try await store.pruneDeclines() == 2)

    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "live"))
    #expect(try await store.isDeclined(itemID: "show", episodeID: "s-live"))
    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "finished") == false)
  }

  @Test func aListThatShowsOnlyOneDownloadStateWantsNothing() async throws {
    let world = try await SmartListReadingWorld.make()
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    _ = try await world.list(SmartListRules(includeDownloaded: false, autoDownload: true))
    _ = try await world.list(SmartListRules(includeNotDownloaded: false, autoDownload: true))

    #expect(try await world.store().wantedEpisodes().isEmpty)
  }

  // MARK: - Account removal

  @Test func removingTheAccountDropsServerClaimsAndKeepsNativeOnes() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let list = try await world.list()
    let store = world.store()
    try await store.recordClaim(listID: list, itemID: "show", episodeID: "s1", accountID: accountId, at: Date())
    try await store.recordClaim(listID: list, itemID: "rss:1", episodeID: "e1", accountID: nil, at: Date())

    try await world.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
    }

    #expect(try await store.claims().map(\.itemID) == ["rss:1"])
  }

  @Test func removingTheAccountDropsServerDeclinesAndKeepsNativeOnes() async throws {
    let world = try await SmartListReadingWorld.make()
    let accountId = try #require(world.accountId)
    let feed = try await world.feed("https://a.example/feed")
    try await world.native(feed: feed, "e1", published: SmartListReadingWorld.at(1))
    let show = try await world.show("show")
    try await world.server(show: show, "s1")
    _ = try await world.list(SmartListRules(autoDownload: true))
    let store = world.store()
    try await store.declineWanted(itemID: nil, episodeID: nil, accountID: accountId, at: Date())

    try await world.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
    }

    #expect(try await store.isDeclined(itemID: "rss:\(feed)", episodeID: "e1"))
    #expect(try await store.isDeclined(itemID: "show", episodeID: "s1") == false)
  }
}

extension SmartListReadingWorld {
  func store(
    nativeEnabled: Bool = true, activeNative: Set<Int64> = []
  ) -> SmartListDownloadStore {
    SmartListDownloadStore(
      database: database, nativeEnabled: { nativeEnabled }, activeNativeEpisodeIDs: { activeNative },
      now: { Self.epoch })
  }

  func nativeQueue(_ episode: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssListeningQueueEntry (rssEpisodeId, position) VALUES (?, 1)",
        arguments: [episode])
    }
  }

  func serverQueue(show: Int64, episode: Int64) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry (accountId, itemId, podcastEpisodeId, position)
          VALUES (?, ?, ?, 1)
          """,
        arguments: [accountId, show, episode])
    }
  }

  func serverPlayback(show: Int64, episode: Int64) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO playbackSession (accountId, clientSessionId, itemId, podcastEpisodeId,
            startedAt, updatedAt, state)
          VALUES (?, ?, ?, ?, ?, ?, 'active')
          """,
        arguments: [accountId, UUID().uuidString, show, episode, Self.epoch, Self.epoch])
    }
  }

  func serverTransfer(show: Int64, episode: Int64, state: String) async throws {
    let accountId = try #require(accountId)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO download (accountId, itemId, podcastEpisodeId, serverFileIno, orderIndex,
            destinationRelativePath, expectedBytes, expectedMimeType, fileDurationSeconds,
            receivedBytes, state)
          VALUES (?, ?, ?, 'ino', 0, 'x.mp3', 100, 'audio/mpeg', 10, 0, ?)
          """,
        arguments: [accountId, show, episode, state])
    }
  }

  /// A stored, pinned playlist in the world's library holding the given server episodes.
  func pin(items: [(String, String)]) async throws {
    let accountId = try #require(accountId)
    let libraryId = try #require(libraryId)
    try await database.writeAsync { db in
      let serverLibraryId = try #require(
        try String.fetchOne(db, sql: "SELECT serverLibraryId FROM library WHERE id = ?", arguments: [libraryId]))
      try db.execute(
        sql: """
          INSERT INTO pinnedList (accountId, serverLibraryId, kind, serverId, pinnedAt)
          VALUES (?, ?, 'playlist', 'pl', ?)
          """,
        arguments: [accountId, serverLibraryId, Self.epoch])
      try db.execute(
        sql: "INSERT INTO libraryCollection (libraryId, kind, serverId, name) VALUES (?, 'playlist', 'pl', 'P')",
        arguments: [libraryId])
      let collection = db.lastInsertedRowID
      for (position, item) in items.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO libraryCollectionMember (collectionId, position, serverItemId, serverEpisodeId)
            VALUES (?, ?, ?, ?)
            """,
          arguments: [collection, position, item.0, item.1])
      }
    }
  }
}
