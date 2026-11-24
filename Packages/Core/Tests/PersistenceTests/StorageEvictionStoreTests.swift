import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct StorageEvictionStoreTests {

  @Test func bookCandidatesOrderFinishedPlayedThenUnfinishedPlayedThenNeverPlayed() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)

    let finished = try await fixture.insertItem(serverItemID: "finished")
    let unfinished = try await fixture.insertItem(serverItemID: "unfinished")
    let neverPlayed = try await fixture.insertItem(serverItemID: "never")
    try fixture.insertCompletedDownload(itemID: finished, bytes: 100)
    try fixture.insertCompletedDownload(itemID: unfinished, bytes: 100)
    try fixture.insertCompletedDownload(itemID: neverPlayed, bytes: 100)
    try await fixture.insertProgress(
      itemID: finished, isFinished: true, lastActivityAt: Date(timeIntervalSince1970: 300))
    try await fixture.insertProgress(
      itemID: unfinished, isFinished: false, lastActivityAt: Date(timeIntervalSince1970: 100))

    let candidates = try await fixture.store.fetchCandidates()

    #expect(candidates.map(\.itemId) == [finished, unfinished, neverPlayed])
    #expect(candidates.last?.lastActivityAt == nil)
  }

  @Test func episodeCandidatesUseEpisodeProgressAndPutNeverPlayedLast() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let first = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "first")
    let second = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "second")
    let neverPlayed = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "never")
    try fixture.insertCompletedDownload(itemID: showID, episodeID: first, bytes: 100)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: second, bytes: 100)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: neverPlayed, bytes: 100)
    try await fixture.insertProgress(
      itemID: showID, episodeID: first, isFinished: true,
      lastActivityAt: Date(timeIntervalSince1970: 300))
    try await fixture.insertProgress(
      itemID: showID, episodeID: second, isFinished: false,
      lastActivityAt: Date(timeIntervalSince1970: 100))

    let candidates = try await fixture.store.fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [first, second, neverPlayed])
    #expect(candidates.last?.lastActivityAt == nil)
  }

  @Test func inFlightBookIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    try fixture.insertInFlightDownload(itemID: itemID, holdReason: .waitingForWiFi)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func inFlightEpisodeIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let episodeID = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "episode")
    try fixture.insertCompletedDownload(itemID: showID, episodeID: episodeID, bytes: 100)
    try fixture.insertInFlightDownload(
      itemID: showID, episodeID: episodeID, holdReason: .waitingForWiFi)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func currentlyPlayingBookIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    try await fixture.insertPlaybackSession(itemID: itemID)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func currentlyPlayingEpisodeIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let episodeID = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "episode")
    try fixture.insertCompletedDownload(itemID: showID, episodeID: episodeID, bytes: 100)
    try await fixture.insertPlaybackSession(itemID: showID, episodeID: episodeID)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func queuedBookIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    try await fixture.insertQueueEntry(itemID: itemID)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func queuedEpisodeIdentityIsExcluded() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let episodeID = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "episode")
    try fixture.insertCompletedDownload(itemID: showID, episodeID: episodeID, bytes: 100)
    try await fixture.insertQueueEntry(itemID: showID, episodeID: episodeID)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func episodeInsideKeepLatestWindowIsExcludedButOlderEpisodeRemains() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    try await fixture.insertGlobalPodcastSettings(keepLatestCount: 1)
    let newest = try await fixture.insertEpisode(
      itemID: showID, serverEpisodeID: "newest", publishedAt: Date(timeIntervalSince1970: 200))
    let older = try await fixture.insertEpisode(
      itemID: showID, serverEpisodeID: "older", publishedAt: Date(timeIntervalSince1970: 100))
    try fixture.insertCompletedDownload(itemID: showID, episodeID: newest, bytes: 100)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: older, bytes: 100)

    let candidates = try await fixture.store.fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [older])
  }

  @Test func ebookDownloadsAreNeverCandidates() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "ebook")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100, mediaKind: .ebook)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  @Test func queuedAfterSelectionIsRejectedByAtomicClaim() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    let selected = try #require(try await fixture.store.fetchCandidates().first)

    try await fixture.insertQueueEntry(itemID: itemID)

    #expect(try await fixture.store.claimUnion(targetBytes: selected.byteTotal).isEmpty)
    let row = try #require(try fixture.downloadStore.fetchAll().first)
    #expect(row.state == .completed)
  }

  @Test func startsPlayingAfterSelectionIsRejectedByAtomicClaim() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let episodeID = try await fixture.insertEpisode(itemID: showID, serverEpisodeID: "episode")
    try fixture.insertCompletedDownload(itemID: showID, episodeID: episodeID, bytes: 100)
    let selected = try #require(try await fixture.store.fetchCandidates().first)

    try await fixture.insertPlaybackSession(itemID: showID, episodeID: episodeID)

    #expect(try await fixture.store.claimUnion(targetBytes: selected.byteTotal).isEmpty)
  }

  @Test func tombstonedEpisodeSortsBeforeUserVisibleDownload() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let tombstoned = try await fixture.insertEpisode(
      itemID: showID, serverEpisodeID: "gone", softDeleted: true)
    let visible = try await fixture.insertEpisode(
      itemID: showID, serverEpisodeID: "visible", softDeleted: false)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: tombstoned, bytes: 100)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: visible, bytes: 100)

    let candidates = try await fixture.store.fetchCandidates()

    #expect(candidates.map(\.podcastEpisodeId) == [tombstoned, visible])
    #expect(candidates.first?.isTombstoned == true)
    let claimed = try await fixture.store.claimUnion(targetBytes: 100)
    #expect(claimed.map(\.podcastEpisodeId) == [tombstoned])
  }

  @Test func tombstonedEpisodeWithLiveTransferIsNotCandidate() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let showID = try await fixture.insertItem(serverItemID: "show", mediaKind: "podcast")
    let episodeID = try await fixture.insertEpisode(
      itemID: showID, serverEpisodeID: "gone", softDeleted: true)
    try fixture.insertCompletedDownload(itemID: showID, episodeID: episodeID, bytes: 100)
    try fixture.insertInFlightDownload(
      itemID: showID, episodeID: episodeID, holdReason: .waitingForWiFi)

    #expect(try await fixture.store.fetchCandidates().isEmpty)
  }

  /// A companion PDF held for Wi-Fi is not the book's
  /// own transfer, so it must not pin a finished audiobook on disk.
  @Test func aHeldSupplementDoesNotProtectItsAudiobook() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    try fixture.insertInFlightDownload(
      itemID: itemID, holdReason: .waitingForWiFi, mediaKind: .supplement)

    #expect(try await fixture.store.fetchCandidates().map(\.itemId) == [itemID])
  }

  /// The PDF goes with its audiobook: it counts towards the bytes freed and is claimed with it.
  @Test func evictionTakesTheSupplementWithTheAudio() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let itemID = try await fixture.insertItem(serverItemID: "book")
    let audioID = try fixture.insertCompletedDownload(itemID: itemID, bytes: 100)
    let pdfID = try fixture.insertCompletedDownload(itemID: itemID, bytes: 20, mediaKind: .supplement)

    #expect(try await fixture.store.fetchCandidates().first?.byteTotal == 120)
    let claimed = try await fixture.store.claimUnion(targetBytes: 50)
    #expect(Set(claimed.map(\.downloadId)) == [audioID, pdfID])
  }

  @Test func claimMarksTheSelectedRowsAndReturnsPreMarkByteTotals() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let first = try await fixture.insertItem(serverItemID: "first")
    let second = try await fixture.insertItem(serverItemID: "second")
    let firstID = try fixture.insertCompletedDownload(itemID: first, bytes: 100)
    let secondID = try fixture.insertCompletedDownload(itemID: second, bytes: 200)

    let claimed = try await fixture.store.claimUnion(targetBytes: 250)

    #expect(claimed.map(\.downloadId) == [firstID, secondID])
    #expect(claimed.map(\.bytes) == [100, 200])
    let rows = try fixture.downloadStore.fetchAll().sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    #expect(rows.map(\.state) == [.deleting, .deleting])
  }

  @Test("union candidates order and claim preserve source identity and byte target")
  func unionCandidatesClaimABSAndRSSRows() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let absItemID = try await fixture.insertItem(serverItemID: "abs")
    let absDownloadID = try fixture.insertCompletedDownload(itemID: absItemID, bytes: 100)
    let rss = try await fixture.insertRSSDownload(key: "rss", bytes: 200)

    let candidates = try await fixture.store.fetchCandidates()
    #expect(
      candidates.contains {
        $0.source == .abs && $0.itemId == absItemID && $0.downloadId == nil
      })
    #expect(
      candidates.contains {
        $0.source == .rss && $0.itemId == rss.feedID && $0.podcastEpisodeId == rss.episodeID
      })

    let claimed = try await fixture.store.claimUnion(targetBytes: 250)
    #expect(claimed.map(\.bytes).reduce(0, +) == 300)
    #expect(
      claimed.contains {
        $0.source == .abs && $0.downloadId == absDownloadID && $0.identity.source == .abs
      })
    #expect(
      claimed.contains {
        $0.source == .rss && $0.downloadId == rss.downloadID && $0.identity.source == .rss
      })
    #expect(try fixture.downloadStore.fetch(downloadId: absDownloadID)?.state == .deleting)
    #expect(try await fixture.rssStore.fetchAsync(downloadId: rss.downloadID)?.state == .deleting)
  }

  @Test("RSS queue and active playback exclusions protect otherwise eligible episodes")
  func unionExcludesQueuedAndActiveRSSDownloads() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let queued = try await fixture.insertRSSDownload(key: "queued", bytes: 100)
    try await fixture.insertRSSQueueEntry(episodeID: queued.episodeID)
    #expect(
      try await fixture.store.fetchCandidates().contains {
        $0.source == .rss && $0.podcastEpisodeId == queued.episodeID
      } == false)

    let active = try await fixture.insertRSSDownload(key: "active", bytes: 100)
    let activeStore = StorageEvictionStore(
      database: database, accountId: fixture.accountID, activeRSSEpisodeIDs: [active.episodeID])
    #expect(
      try await activeStore.fetchCandidates().contains {
        $0.source == .rss && $0.podcastEpisodeId == active.episodeID
      } == false)
  }

  @Test("RSS keep-latest protects a manual row while older storage remains eligible")
  func rssKeepLatestProtectsManualRow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Fixture(database: database)
    let feedID = try await fixture.insertRSSFeed(title: "retention")
    let newest = try await fixture.insertRSSDownload(
      key: "newest", bytes: 100, publishedAt: Date(timeIntervalSince1970: 200), origin: .manual,
      feedID: feedID)
    let older = try await fixture.insertRSSDownload(
      key: "older", bytes: 100, publishedAt: Date(timeIntervalSince1970: 100), origin: .automatic,
      feedID: feedID)
    try await RSSFeedSettingsStore(database: database).setKeepLatestOverride(
      feedId: feedID, count: 1)

    let candidates = try await fixture.store.fetchCandidates()
    #expect(candidates.contains { $0.podcastEpisodeId == newest.episodeID } == false)
    #expect(
      candidates.contains {
        $0.source == .rss && $0.podcastEpisodeId == older.episodeID
      })
  }

  private struct Fixture {
    let database: AppDatabase
    let accountID: Int64
    let libraryID: Int64
    let downloadStore: DownloadStore
    let rssStore: RSSDownloadStore
    let store: StorageEvictionStore

    init(database: AppDatabase) async throws {
      self.database = database
      (accountID, libraryID) = try await Self.insertAccountAndLibrary(database)
      downloadStore = try DownloadStore(database: database)
      rssStore = try RSSDownloadStore(database: database)
      store = StorageEvictionStore(database: database, accountId: accountID)
    }

    func insertItem(serverItemID: String, mediaKind: String = "book") async throws -> Int64 {
      try await database.writeAsync { db in
        var item = PersistenceFixtures.item(
          accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
          mediaKind: mediaKind, title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
        return item.id!
      }
    }

    func insertEpisode(
      itemID: Int64, serverEpisodeID: String, publishedAt: Date? = nil, softDeleted: Bool = false
    ) async throws -> Int64 {
      try await database.writeAsync { db in
        var episode = PersistenceFixtures.episode(
          accountId: accountID, itemId: itemID, serverEpisodeId: serverEpisodeID,
          title: serverEpisodeID, publishedAt: publishedAt, lastSeenGeneration: 1,
          softDeleted: softDeleted)
        try episode.insert(db)
        return episode.id!
      }
    }

    @discardableResult
    func insertProgress(
      itemID: Int64, episodeID: Int64? = nil, isFinished: Bool, lastActivityAt: Date?
    ) async throws -> Int64 {
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID,
          currentTime: isFinished ? 100 : 10, isFinished: isFinished, localSequence: 1,
          origin: .local, originKey: "client", lastActivityAt: lastActivityAt)
        try progress.insert(db)
        return progress.id!
      }
    }

    @discardableResult
    func insertCompletedDownload(
      itemID: Int64, episodeID: Int64? = nil, bytes: Int64, mediaKind: DownloadMediaKind = .audio
    ) throws -> Int64 {
      let record = try downloadStore.enqueue(
        accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID,
        serverFileIno: UUID().uuidString, orderIndex: 0,
        destinationRelativePath: "(UUID().uuidString).bin", expectedBytes: bytes,
        expectedMimeType: mediaKind == .ebook ? "application/epub+zip" : "audio/mp4",
        fileDurationSeconds: mediaKind == .ebook ? 0 : 60, mediaKind: mediaKind)
      _ = try downloadStore.transition(downloadId: record.id!, to: .downloading)
      return try downloadStore.complete(downloadId: record.id!, finalSizeBytes: bytes).id!
    }

    func insertRSSFeed(title: String) async throws -> Int64 {
      try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://example.com/\(UUID().uuidString).xml")!, title: title,
        author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    }

    func insertRSSDownload(
      key: String, bytes: Int64, publishedAt: Date? = nil, origin: DownloadOrigin = .manual,
      feedID: Int64? = nil
    ) async throws -> (feedID: Int64, episodeID: Int64, downloadID: Int64) {
      let resolvedFeedID: Int64
      if let feedID {
        resolvedFeedID = feedID
      } else {
        resolvedFeedID = try await insertRSSFeed(title: key)
        try await RSSFeedSettingsStore(database: database).setKeepLatestOverride(
          feedId: resolvedFeedID, count: 0)
      }
      let episodeStore = RSSEpisodeStore(database: database)
      _ = try await episodeStore.applyRefresh(
        feedId: resolvedFeedID,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: key, title: key,
            enclosureURL: URL(string: "https://example.com/\(UUID().uuidString).mp3")!,
            enclosureType: "audio/mpeg", declaredBytes: bytes, publishedAt: publishedAt)
        ])
      let episode = try #require(
        await episodeStore.fetchEpisode(feedId: resolvedFeedID, identityKey: key))
      let row = try await rssStore.claimOrCreateAsync(
        episodeId: try #require(episode.id), origin: origin)
      let downloadID = try #require(row.id)
      _ = try await rssStore.transitionAsync(downloadId: downloadID, to: .downloading)
      _ = try await rssStore.completeAsync(downloadId: downloadID, actualBytes: bytes)
      return (resolvedFeedID, try #require(episode.id), downloadID)
    }

    @discardableResult
    func insertInFlightDownload(
      itemID: Int64, episodeID: Int64? = nil, holdReason: DownloadHoldReason? = nil,
      mediaKind: DownloadMediaKind = .audio
    ) throws -> Int64 {
      let record = try downloadStore.enqueue(
        accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID,
        serverFileIno: UUID().uuidString, orderIndex: 1,
        destinationRelativePath: "in-flight.bin", expectedBytes: 200,
        expectedMimeType: mediaKind == .supplement ? "application/pdf" : "audio/mp4",
        fileDurationSeconds: mediaKind == .supplement ? 0 : 60, mediaKind: mediaKind)
      _ = try downloadStore.transition(downloadId: record.id!, to: .downloading)
      if let holdReason {
        return try downloadStore.transition(
          downloadId: record.id!, to: .pending, holdReason: holdReason
        ).id!
      }
      return record.id!
    }

    func insertPlaybackSession(itemID: Int64, episodeID: Int64? = nil) async throws {
      try await database.writeAsync { db in
        var session = PlaybackSessionRecord(
          accountId: accountID, clientSessionId: UUID().uuidString, itemId: itemID,
          podcastEpisodeId: episodeID, startedAt: Date(), updatedAt: Date(), state: .active)
        try session.insert(db)
      }
    }

    func insertQueueEntry(itemID: Int64, episodeID: Int64? = nil) async throws {
      try await database.writeAsync { db in
        var entry = ListeningQueueEntryRecord(
          accountId: accountID, itemId: itemID, podcastEpisodeId: episodeID, position: 0)
        try entry.insert(db)
      }
    }

    func insertRSSQueueEntry(episodeID: Int64) async throws {
      try await database.writeAsync { db in
        var entry = RSSListeningQueueEntryRecord(
          rssEpisodeId: episodeID, position: 0)
        try entry.insert(db)
      }
    }

    func insertGlobalPodcastSettings(keepLatestCount: Int) async throws {
      try await database.writeAsync { db in
        let settings = PodcastSettingsRecord(
          accountId: accountID, autoDownloadEnabled: true, keepLatestCount: keepLatestCount,
          enabledAt: Date(timeIntervalSince1970: 1))
        try settings.save(db)
      }
    }

    private static func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
      accountID: Int64, libraryID: Int64
    ) {
      try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: UUID().uuidString, serverVersion: "2.10.0")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: UUID().uuidString, mediaType: "book",
          name: "Library")
        try library.insert(db)
        return (account.id!, library.id!)
      }
    }
  }
}
