import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("RSS podcast automation stores")
struct RSSPodcastAutomationStoreTests {
  @Test("selection resolves per-feed settings and enforces both budgets")
  func selectionSettingsAndBudgets() async throws {
    let fixture = try await Fixture(episodeCount: 4)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    try await fixture.settings.setGlobalKeepLatestCount(3)
    try await fixture.feedSettings.setKeepLatestOverride(feedId: fixture.feedID, count: 2)
    let store = RSSPodcastAutoDownloadSelectionStore(
      database: fixture.database, accountId: fixture.accountID)

    let one = try await store.fetchCandidates(maxPerShow: 1, maxPerPass: 20)
    #expect(one.map(\.episodeID) == ["episode-4"])

    let two = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 2)
    #expect(two.map(\.episodeID) == ["episode-4", "episode-3"])
  }

  @Test("selection excludes finished, existing-download, disabled, and pre-floor episodes")
  func selectionEligibility() async throws {
    let enabledAt = Date(timeIntervalSince1970: 350)
    let fixture = try await Fixture(episodeCount: 4, settingsNow: enabledAt)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    let newest = try #require(fixture.episodes.last)
    let previous = fixture.episodes[fixture.episodes.count - 2]
    let newestID = try #require(newest.id)
    let previousID = try #require(previous.id)
    _ = try fixture.downloads.claimOrCreate(
      episodeId: newestID, origin: .manual,
      decidedStamp: Date(timeIntervalSince1970: 500))
    _ = try await fixture.states.recordTick(
      episodeId: previousID, position: 20, finished: true,
      capturedSequence: 0, now: Date(timeIntervalSince1970: 500))
    let store = RSSPodcastAutoDownloadSelectionStore(
      database: fixture.database, accountId: fixture.accountID)

    #expect(try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20) == [])

    try await fixture.feedSettings.setAutoDownloadOverride(
      feedId: fixture.feedID, override: .disabled)
    #expect(try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20) == [])
  }

  @Test("mark-decided preserves automatic origin and advances its decision stamp")
  func automaticDecisionStamp() async throws {
    let fixture = try await Fixture(episodeCount: 1)
    let episode = try #require(fixture.episodes.first)
    let episodeID = try #require(episode.id)
    let initial = Date(timeIntervalSince1970: 10)
    let decided = Date(timeIntervalSince1970: 20)
    _ = try fixture.downloads.claimOrCreate(
      episodeId: episodeID, origin: .automatic, decidedStamp: initial)
    let claimedEpisode = try #require(
      await fixture.database.readAsync { db in try RSSEpisodeRecord.fetchOne(db, key: episodeID) })
    #expect(claimedEpisode.autoDownloadDecidedAt == initial)
    let store = RSSPodcastAutoDownloadSelectionStore(
      database: fixture.database, accountId: fixture.accountID, now: { decided })

    try await store.markDecided(itemID: "rss:\(fixture.feedID)", episodeID: episode.identityKey)

    let row = try #require(try fixture.downloads.fetch(episodeId: episodeID))
    #expect(row.origin == .automatic)
    #expect(row.decidedStamp == decided)
    let decidedEpisode = try #require(
      await fixture.database.readAsync { db in try RSSEpisodeRecord.fetchOne(db, key: episodeID) })
    #expect(decidedEpisode.autoDownloadDecidedAt == decided)
  }

  @Test("deleted automatic downloads stay decided while a new episode remains eligible")
  func deletedAutomaticDownloadsAreNotReconsidered() async throws {
    let fixture = try await Fixture(episodeCount: 3)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    try await fixture.settings.setGlobalKeepLatestCount(3)

    for episode in fixture.episodes {
      let episodeID = try #require(episode.id)
      let row = try fixture.downloads.claimOrCreate(
        episodeId: episodeID, origin: .automatic,
        decidedStamp: Date(timeIntervalSince1970: 500))
      try fixture.downloads.markDeleting(downloadId: try #require(row.id))
      try fixture.downloads.finalizeDeletion(downloadId: try #require(row.id))
    }

    _ = try await RSSEpisodeStore(database: fixture.database).applyRefresh(
      feedId: fixture.feedID,
      episodes: (1...4).map { index in
        RSSEpisodeUpsert(
          identityKey: "episode-\(index)", guid: "episode-\(index)", title: "Episode \(index)",
          enclosureURL: URL(string: "https://cdn.invalid/\(index).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 100,
          publishedAt: Date(timeIntervalSince1970: TimeInterval(index * 100)), durationSeconds: 60)
      })

    let store = RSSPodcastAutoDownloadSelectionStore(
      database: fixture.database, accountId: fixture.accountID)
    let candidates = try await store.fetchCandidates(maxPerShow: 5, maxPerPass: 20)

    #expect(candidates.map(\.episodeID) == ["episode-4"])
  }

  @Test("retention reaps automatic completed rows outside keep-latest or finished")
  func retentionPolicies() async throws {
    let fixture = try await Fixture(episodeCount: 3)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    try await fixture.settings.setGlobalKeepLatestCount(1)
    try await fixture.settings.setGlobalDeleteAfterPlayed(true)
    for episode in fixture.episodes {
      try fixture.insertCompletedDownload(episode: episode, origin: .automatic)
    }
    let newest = try #require(fixture.episodes.last)
    _ = try await fixture.states.recordTick(
      episodeId: try #require(newest.id), position: 60, finished: true,
      capturedSequence: 0, now: Date(timeIntervalSince1970: 500))
    let store = RSSPodcastAutoDownloadReapStore(
      database: fixture.database, accountId: fixture.accountID)

    let candidates = try await store.reapCandidates()

    #expect(Set(candidates.map(\.episodeID)) == Set(["episode-1", "episode-2", "episode-3"]))
    #expect(candidates.allSatisfy { $0.itemID == "rss:\(fixture.feedID)" })
  }

  @Test("retention excludes manual, queued, and actively playing episodes")
  func retentionExclusions() async throws {
    let fixture = try await Fixture(episodeCount: 4)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    try await fixture.settings.setGlobalKeepLatestCount(1)
    try fixture.insertCompletedDownload(episode: fixture.episodes[0], origin: .manual)
    for episode in fixture.episodes.dropFirst() {
      try fixture.insertCompletedDownload(episode: episode, origin: .automatic)
    }
    try fixture.insertQueueEntry(episode: fixture.episodes[1])
    let activeID = try #require(fixture.episodes[2].id)
    let store = RSSPodcastAutoDownloadReapStore(
      database: fixture.database, accountId: fixture.accountID,
      activeEpisodeIDs: { Set([activeID]) })

    let candidates = try await store.reapCandidates()

    #expect(candidates.map(\.episodeID) == [])
  }

  /// A Watch copy no longer pins the phone's own file: the Watch downloads the enclosure itself
  /// (ADR 0020 Decision 1), so the phone's completed auto-download is reaped like any other, both
  /// while the offer is live and once the Watch has admitted the copy.
  @Test("retention does not spare a phone file because the episode is on the Watch")
  func watchCopiesDoNotPinPhoneFiles() async throws {
    let fixture = try await Fixture(episodeCount: 3)
    try await fixture.settings.setGlobalAutoDownloadEnabled(true)
    try await fixture.settings.setGlobalKeepLatestCount(1)
    try await fixture.settings.setGlobalDeleteAfterPlayed(true)
    for episode in fixture.episodes {
      try fixture.insertCompletedDownload(episode: episode, origin: .automatic)
    }
    let offeredID = try #require(fixture.episodes[0].id)
    let deliveredID = try #require(fixture.episodes[1].id)
    let watchCopyStore = RSSWatchCopyStore(database: fixture.database)
    _ = try await watchCopyStore.request(
      episodeId: offeredID, now: Date(timeIntervalSince1970: 500))
    _ = try await watchCopyStore.request(
      episodeId: deliveredID, now: Date(timeIntervalSince1970: 501))
    _ = try await watchCopyStore.transition(
      episodeId: deliveredID, revision: 1, to: .sending,
      now: Date(timeIntervalSince1970: 502))
    _ = try await watchCopyStore.applyInventory(
      RSSWatchInventory(
        watchInstallID: "watch-1", sequence: 1, acknowledgedGeneration: 2, acceptsCopies: true,
        entries: [.init(episodeId: deliveredID, revision: 1, state: .ready)],
        budgetTotalBytes: 2_000_000_000, budgetUsedBytes: 0,
        observedAt: Date(timeIntervalSince1970: 503)),
      now: Date(timeIntervalSince1970: 503))
    // Finishing every episode would otherwise reap them under delete-after-played.
    for episode in fixture.episodes {
      _ = try await fixture.states.setFinished(
        episodeId: try #require(episode.id), finished: true,
        now: Date(timeIntervalSince1970: 510))
    }

    let store = RSSPodcastAutoDownloadReapStore(
      database: fixture.database, accountId: fixture.accountID)
    let candidates = try await store.reapCandidates()

    #expect(
      candidates.map(\.episodeID) == ["episode-1", "episode-2", "episode-3"],
      "a copy in the offer and a delivered copy both leave the phone's file reapable")
  }
}

private struct Fixture {
  let database: AppDatabase
  let accountID: Int64
  let feedID: Int64
  let episodes: [RSSEpisodeRecord]
  let settings: NativePodcastSettingsStore
  let feedSettings: RSSFeedSettingsStore
  let downloads: RSSDownloadStore
  let states: RSSEpisodeStateStore

  init(episodeCount: Int, settingsNow: Date = Date(timeIntervalSince1970: 50)) async throws {
    let database = try AppDatabase.inMemory()
    self.database = database
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "rss-automation", serverBaseURL: "https://server.invalid",
        serverUserId: "user", serverVersion: "2.35.1", defaultLibraryId: "books"))
    accountID = try #require(account.id)
    settings = NativePodcastSettingsStore(database: database, now: { settingsNow })
    let feedStore = RSSFeedStore(database: database)
    let createdFeedID = try await feedStore.subscribe(
      feedURL: URL(string: "https://feeds.invalid/show.xml")!, title: "Show", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 1))
    feedID = createdFeedID
    feedSettings = RSSFeedSettingsStore(database: database)
    downloads = try RSSDownloadStore(database: database)
    states = RSSEpisodeStateStore(database: database)
    let episodeStore = RSSEpisodeStore(database: database)
    _ = try await episodeStore.applyRefresh(
      feedId: feedID,
      episodes: (1...episodeCount).map { index in
        RSSEpisodeUpsert(
          identityKey: "episode-\(index)", guid: "episode-\(index)", title: "Episode \(index)",
          enclosureURL: URL(string: "https://cdn.invalid/\(index).mp3")!,
          enclosureType: "audio/mpeg", declaredBytes: 100,
          publishedAt: Date(timeIntervalSince1970: TimeInterval(index * 100)),
          durationSeconds: 60)
      })
    episodes = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY publishedAt",
        arguments: [createdFeedID])
    }
  }

  func insertCompletedDownload(episode: RSSEpisodeRecord, origin: DownloadOrigin) throws {
    let episodeID = try #require(episode.id)
    let row = try downloads.claimOrCreate(
      episodeId: episodeID, origin: origin, decidedStamp: Date(timeIntervalSince1970: 500))
    let downloadID = try #require(row.id)
    _ = try downloads.transition(downloadId: downloadID, to: .downloading)
    _ = try downloads.complete(downloadId: downloadID, actualBytes: 100)
  }

  func insertQueueEntry(episode: RSSEpisodeRecord) throws {
    let episodeID = try #require(episode.id)
    try database.write { db in
      try db.execute(
        sql: "INSERT INTO rssListeningQueueEntry (rssEpisodeId, position) VALUES (?, 0)",
        arguments: [episodeID])
    }
  }
}
