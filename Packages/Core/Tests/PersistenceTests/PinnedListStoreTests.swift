import Foundation
import GRDB
import Testing

@testable import Persistence

/// Pinned-list store.
@Suite struct PinnedListStoreTests {
  @Test func aPinSurvivesAReplaceAndIsRemovedWithTheAccount() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1"])])
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("pl"), at: Date())

    try await fixture.replace(.playlist, [list("pl", ["book-2", "book-1"])])
    #expect(await fixture.pins.pinnedKeys(accountID: fixture.accountID) == [fixture.key("pl")])

    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [fixture.accountID])
    }
    let count = try await fixture.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinnedList") ?? -1
    }
    #expect(count == 0)
  }

  @Test func candidatesAreHeldUnfinishedAudioMembersWithoutAnAudioRowInListOrder() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(
      .playlist,
      [
        list(
          "pl",
          [
            "book-2", "missing", "book-1", "finished", "ebook", "downloaded", "failed",
            "ebook-row-only",
          ], episodes: [("show", "ep-1")])
      ])
    try await fixture.finish("finished")
    try fixture.audioRow("downloaded", state: .completed)
    try fixture.audioRow("failed", state: .failed)
    try fixture.audioRow("ebook-row-only", state: .completed, mediaKind: .ebook)
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("pl"), at: Date())

    let candidates = try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10)

    #expect(
      candidates.map(\.member) == [
        member("book-2"), member("book-1"), member("ebook-row-only"), member("show", "ep-1"),
      ])
    #expect(candidates.map(\.category) == [.audiobook, .audiobook, .audiobook, .podcast])
    #expect(try await fixture.pins.candidates(accountID: fixture.accountID, limit: 1).count == 1)
  }

  @Test func aMemberOfTwoPinnedListsIsOneCandidateAndAnUnpinnedListGivesNone() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("a", ["book-1"]), list("b", ["book-1", "book-2"])])
    try await fixture.replace(.collection, [list("c", ["book-3"])])
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("a"), at: Date(timeIntervalSince1970: 1))
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("b"), at: Date(timeIntervalSince1970: 2))

    let candidates = try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10)
    #expect(candidates.map(\.member) == [member("book-1"), member("book-2")])
    #expect(candidates.map(\.key) == [fixture.key("a"), fixture.key("b")])
  }

  @Test func anExcludedLibraryActsAsUnpinnedButKeepsThePin() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1"])])
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("pl"), at: Date())
    try await fixture.database.writeAsync { db in
      try db.execute(sql: "UPDATE library SET isIncluded = 0")
    }

    #expect(try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).isEmpty)
    #expect(try await fixture.pins.dropVanishedPins(accountID: fixture.accountID) == 0)
    #expect(await fixture.pins.pinnedKeys(accountID: fixture.accountID) == [fixture.key("pl")])
  }

  @Test func claimsAreReleasableOnlyWhenTheMemberLeftAListThatIsStillStored() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1", "book-2"])])
    let key = fixture.key("pl")
    try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date())
    for id in ["book-1", "book-2"] {
      try await fixture.pins.recordClaim(accountID: fixture.accountID, key: key, member: member(id), at: Date())
    }

    try await fixture.replace(.playlist, [list("pl", ["book-1"])])
    #expect(
      try await fixture.pins.releasableClaims(accountID: fixture.accountID)
        == [PinnedListClaim(key: key, member: member("book-2"))])

    // A complete refresh that no longer lists it: the members cascade away, but nothing is
    // releasable, and dropping the vanished pin drops its claims.
    try await fixture.replace(.playlist, [])
    #expect(try await fixture.pins.releasableClaims(accountID: fixture.accountID).isEmpty)
    #expect(try await fixture.pins.dropVanishedPins(accountID: fixture.accountID) == 1)
    #expect(await fixture.pins.pinnedKeys(accountID: fixture.accountID).isEmpty)
    #expect(try await fixture.claimCount() == 0)
  }

  @Test func aListNeverFetchedIsNotVanished() async throws {
    let fixture = try await Fixture()
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("pl"), at: Date())
    #expect(try await fixture.pins.dropVanishedPins(accountID: fixture.accountID) == 0)
  }

  @Test func unpinReturnsItsClaimsAndRemovesThem() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1", "book-2"])])
    let key = fixture.key("pl")
    try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date())
    try await fixture.pins.recordClaim(accountID: fixture.accountID, key: key, member: member("book-1"), at: Date())

    #expect(try await fixture.pins.unpin(accountID: fixture.accountID, key: key) == [member("book-1")])
    #expect(try await fixture.claimCount() == 0)
    #expect(await fixture.pins.pinnedKeys(accountID: fixture.accountID).isEmpty)
  }

  @Test func aDeclinedMemberIsNotACandidateUntilClearedOrItLeavesTheList() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1", "book-2"])])
    let key = fixture.key("pl")
    try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date())
    try await fixture.pins.recordClaim(accountID: fixture.accountID, key: key, member: member("book-1"), at: Date())

    try await fixture.pins.decline(accountID: fixture.accountID, member: member("book-1"), at: Date())
    #expect(
      try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).map(\.member) == [member("book-2")])
    #expect(try await fixture.claimCount() == 0)

    try await fixture.pins.clearDeclines(accountID: fixture.accountID, member: member("book-1"))
    #expect(try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).count == 2)

    try await fixture.pins.decline(accountID: fixture.accountID, member: member("book-1"), at: Date())
    try await fixture.replace(.playlist, [list("pl", ["book-2"])])
    try await fixture.pins.pruneDeclines(accountID: fixture.accountID)
    try await fixture.replace(.playlist, [list("pl", ["book-2", "book-1"])])
    #expect(try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).count == 2)
  }

  @Test func declineTouchesOnlyPinnedListsHoldingTheMember() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1"])])
    try await fixture.pins.decline(accountID: fixture.accountID, member: member("book-1"), at: Date())
    let count = try await fixture.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinnedListDecline") ?? -1
    }
    #expect(count == 0)
  }

  @Test func protectionsKeepAReleasedMember() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("a", ["book-1", "book-2", "book-3"]), list("b", ["book-4"])])
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("b"), at: Date())
    let keeps = { (id: String) async throws -> Bool in
      try await fixture.pins.isKeptBesidesPins(accountID: fixture.accountID, member: member(id))
    }
    #expect(try await keeps("book-1") == false)

    try await fixture.queue("book-1")
    try await fixture.save("book-2")
    #expect(try await keeps("book-1"))
    #expect(try await keeps("book-2"))
    #expect(try await keeps("book-3") == false)
    #expect(try await keeps("book-4"))
  }

  @Test func claimedMembersAreOnlyThisPinsClaims() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("a", ["book-1", "book-2"]), list("b", ["book-3"])])
    let a = fixture.key("a")
    let b = fixture.key("b")
    for key in [a, b] { try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date()) }
    try await fixture.pins.recordClaim(accountID: fixture.accountID, key: a, member: member("book-2"), at: Date())
    try await fixture.pins.recordClaim(accountID: fixture.accountID, key: b, member: member("book-3"), at: Date())

    #expect(try await fixture.pins.claimedMembers(accountID: fixture.accountID, key: a) == [member("book-2")])
  }

  @Test func failedMembersAreTheListsHeldMembersWithAFailedAudioRow() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["failed", "downloaded", "finished"])])
    try fixture.audioRow("failed", state: .failed)
    try fixture.audioRow("downloaded", state: .completed)
    try fixture.audioRow("finished", state: .failed)
    try await fixture.finish("finished")
    let key = fixture.key("pl")
    try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date())

    #expect(try await fixture.pins.failedMembers(accountID: fixture.accountID, key: key) == [member("failed")])
  }

  @Test func declineAllDeclinesEveryPinnedMemberAndDropsEveryClaim() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("a", ["book-1"]), list("b", ["book-2"]), list("d", ["book-3"])])
    for id in ["a", "b"] {
      try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key(id), at: Date())
    }
    try await fixture.pins.recordClaim(
      accountID: fixture.accountID, key: fixture.key("a"), member: member("book-1"), at: Date())

    try await fixture.pins.declineAll(accountID: fixture.accountID, at: Date())

    #expect(try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).isEmpty)
    #expect(try await fixture.claimCount() == 0)
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("d"), at: Date())
    #expect(
      try await fixture.pins.candidates(accountID: fixture.accountID, limit: 10).map(\.member) == [member("book-3")])
  }

  @Test func previewCountsWhatPinningWouldDownloadAndSizesOnlyWhenAllAreKnown() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1", "book-2", "downloaded", "finished", "ebook"])])
    try fixture.audioRow("downloaded", state: .completed)
    try await fixture.finish("finished")
    let key = fixture.key("pl")

    #expect(
      try await fixture.pins.downloadPreview(accountID: fixture.accountID, key: key)
        == PinnedListDownloadPreview(count: 2, expectedBytes: nil))

    try await fixture.setExpectedBytes("book-1", 1_000)
    try await fixture.setExpectedBytes("book-2", 500)
    #expect(
      try await fixture.pins.downloadPreview(accountID: fixture.accountID, key: key)
        == PinnedListDownloadPreview(count: 2, expectedBytes: 1_500))
  }

  @Test func keptBesidesPinsCanLeaveOnePinOut() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("a", ["book-1"]), list("b", ["book-1"])])
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("a"), at: Date())
    let kept = { (excluding: LibraryCollectionKey?) async throws -> Bool in
      try await fixture.pins.isKeptBesidesPins(
        accountID: fixture.accountID, member: member("book-1"), excluding: excluding)
    }
    #expect(try await kept(nil))
    #expect(try await kept(fixture.key("a")) == false)
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("b"), at: Date())
    #expect(try await kept(fixture.key("a")))
  }

  @Test func summaryCountsByStateAndSetsAsideEbooksFinishedAndDeclined() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(
      .playlist,
      [list("pl", ["book-1", "downloaded", "failed", "waiting", "ebook", "finished", "missing"])])
    try fixture.audioRow("downloaded", state: .completed)
    try fixture.audioRow("failed", state: .failed)
    try fixture.audioRow("waiting", state: .pending, hold: .waitingForWiFi)
    try await fixture.finish("finished")
    let key = fixture.key("pl")
    try await fixture.pins.pin(accountID: fixture.accountID, key: key, at: Date())

    let summary = try #require(await fixture.pins.summary(accountID: fixture.accountID, key: key))
    #expect(
      summary
        == PinnedListDownloadSummary(
          total: 4, completed: 1, waitingForWiFi: 1, failed: 1, notDownloadable: 1))
    #expect(summary.active == 1)
    #expect(await fixture.pins.summary(accountID: fixture.accountID, key: fixture.key("nope")) == nil)
  }

  @Test func evictionNeverOffersAnUnfinishedPinnedMember() async throws {
    let fixture = try await Fixture()
    try await fixture.replace(.playlist, [list("pl", ["book-1", "book-2", "finished"], episodes: [("show", "ep-1")])])
    try fixture.audioRow("book-1", state: .completed)
    try fixture.audioRow("book-2", state: .completed)
    try fixture.audioRow("finished", state: .completed)
    try fixture.audioRow("show", episode: "ep-1", state: .completed)
    try await fixture.finish("finished")
    try await fixture.pins.pin(accountID: fixture.accountID, key: fixture.key("pl"), at: Date())
    try await fixture.replace(.playlist, [list("pl", ["book-1", "finished"], episodes: [("show", "ep-1")])])

    let eviction = StorageEvictionStore(database: fixture.database, accountId: fixture.accountID)
    let candidates = try await eviction.fetchCandidates()
    let ids = try await fixture.database.readAsync { db in
      try candidates.map {
        try String.fetchOne(db, sql: "SELECT serverItemId FROM item WHERE id = ?", arguments: [$0.itemId])!
      }
    }
    #expect(Set(ids) == ["book-2", "finished"])
  }

  // MARK: - Fixture

  private func member(_ item: String, _ episode: String? = nil) -> PinnedListMember {
    PinnedListMember(serverItemID: item, serverEpisodeID: episode)
  }

  private func list(
    _ serverID: String, _ items: [String], episodes: [(String, String)] = []
  ) -> LibraryCollectionSnapshotList {
    LibraryCollectionSnapshotList(
      serverID: serverID, name: serverID, description: nil, lastUpdate: nil,
      members: items.map { LibraryCollectionSnapshotMember(serverItemID: $0) }
        + episodes.map { LibraryCollectionSnapshotMember(serverItemID: $0.0, serverEpisodeID: $0.1) })
  }

  private struct Fixture {
    let database: AppDatabase
    let accountID: Int64
    let lists: LibraryCollectionStore
    let pins: PinnedListStore
    let downloads: DownloadStore

    init() async throws {
      database = try AppDatabase.inMemory()
      accountID = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: "user", serverVersion: "2.35.1")
        try account.insert(db)
        let accountID = account.id!
        var library = LibraryRecord(
          accountId: accountID, serverLibraryId: "books", mediaType: "book", name: "Books")
        try library.insert(db)
        for id in [
          "book-1", "book-2", "book-3", "book-4", "finished", "downloaded", "failed", "waiting",
          "ebook-row-only",
        ] {
          var item = ItemRecord(
            accountId: accountID, libraryId: library.id!, serverItemId: id, mediaKind: "book",
            title: id, sortTitle: id)
          item.numAudioFiles = 1
          try item.insert(db)
        }
        var ebook = ItemRecord(
          accountId: accountID, libraryId: library.id!, serverItemId: "ebook", mediaKind: "book",
          title: "ebook", sortTitle: "ebook")
        ebook.numAudioFiles = 0
        ebook.ebookFormat = "epub"
        try ebook.insert(db)
        var show = ItemRecord(
          accountId: accountID, libraryId: library.id!, serverItemId: "show", mediaKind: "podcast",
          title: "show", sortTitle: "show")
        try show.insert(db)
        var episode = PodcastEpisodeRecord(
          accountId: accountID, itemId: show.id!, serverEpisodeId: "ep-1", title: "ep-1",
          lastSeenGeneration: 1)
        try episode.insert(db)
        return accountID
      }
      lists = LibraryCollectionStore(database: database)
      pins = PinnedListStore(database: database)
      downloads = try DownloadStore(database: database)
    }

    func key(_ serverID: String) -> LibraryCollectionKey {
      LibraryCollectionKey(
        serverLibraryID: "books", kind: serverID == "c" ? .collection : .playlist, serverID: serverID)
    }

    func replace(_ kind: LibraryCollectionListKind, _ lists: [LibraryCollectionSnapshotList]) async throws {
      try await self.lists.replaceSnapshot(accountID: accountID, libraryID: "books", kind: kind, lists: lists)
    }

    func rowIDs(_ item: String, _ episode: String? = nil) throws -> (Int64, Int64?) {
      try database.read { db in
        let itemID = try Int64.fetchOne(db, sql: "SELECT id FROM item WHERE serverItemId = ?", arguments: [item])!
        let episodeID = try episode.map {
          try Int64.fetchOne(db, sql: "SELECT id FROM podcastEpisode WHERE serverEpisodeId = ?", arguments: [$0])!
        }
        return (itemID, episodeID)
      }
    }

    func setExpectedBytes(_ item: String, _ bytes: Int64) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: "UPDATE item SET audioDownloadExpectedBytes = ? WHERE serverItemId = ?",
          arguments: [bytes, item])
      }
    }

    func finish(_ item: String) async throws {
      let (itemID, _) = try rowIDs(item)
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountID, itemId: itemID, currentTime: 100, isFinished: true,
          localSequence: 1, origin: .server, originKey: "fixture")
        try progress.insert(db)
      }
    }

    func audioRow(
      _ item: String, episode: String? = nil, state: DownloadState,
      hold: DownloadHoldReason? = nil, mediaKind: DownloadMediaKind = .audio
    ) throws {
      let (itemID, episodeID) = try rowIDs(item, episode)
      let record = try downloads.enqueue(
        accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID,
        serverFileIno: UUID().uuidString, orderIndex: 0,
        destinationRelativePath: "\(UUID().uuidString).bin", expectedBytes: 100,
        expectedMimeType: mediaKind == .ebook ? "application/epub+zip" : "audio/mp4",
        fileDurationSeconds: mediaKind == .ebook ? 0 : 60, mediaKind: mediaKind)
      try database.write { db in
        try db.execute(
          sql: "UPDATE download SET state = ?, holdReason = ?, receivedBytes = 100 WHERE id = ?",
          arguments: [state.rawValue, hold?.rawValue, record.id!])
      }
    }

    func queue(_ item: String) async throws {
      let (itemID, _) = try rowIDs(item)
      try await database.writeAsync { db in
        var entry = ListeningQueueEntryRecord(accountId: accountID, itemId: itemID, podcastEpisodeId: nil, position: 0)
        try entry.insert(db)
      }
    }

    func save(_ item: String) async throws {
      let (itemID, _) = try rowIDs(item)
      try await database.writeAsync { db in
        try db.execute(
          sql: "INSERT INTO savedShelfEntry (accountId, itemId, savedAt) VALUES (?, ?, ?)",
          arguments: [accountID, itemID, Date()])
      }
    }

    func claimCount() async throws -> Int {
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pinnedListClaim") ?? -1
      }
    }
  }
}
