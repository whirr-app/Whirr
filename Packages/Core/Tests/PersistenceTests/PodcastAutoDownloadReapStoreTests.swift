import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The reap query itself. Each test builds the minimal show/episode/download shape its predicate
/// or exclusion needs, via an explicit per-show override (`.enabled`/`.disabled`), so none
/// depends on a `podcastSettings` default.
@Suite struct PodcastAutoDownloadReapStoreTests {

  @Test func manualDownloadIsNeverReaped() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    // Rank 2 in a keep-latest-1 window: outside the window, but manual origin.
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest",
      origin: .manual)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty)
  }

  @Test func episodeWithAnActivePlaybackSessionIsNeverReaped() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")
    try await insertActivePlaybackSession(
      database, accountId: accountId, itemId: show.itemRowId, episodeId: oldest)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty, "the currently-playing episode is never reaped")
  }

  @Test func episodeInUpNextIsNeverReaped() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")
    try await insertQueueEntry(database, accountId: accountId, itemId: show.itemRowId, episodeId: oldest)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty, "Up Next is explicit user intent")
  }

  /// Saved for Later is a reminder, not a pin: shelf membership does not protect an episode from
  /// the podcast automatic-download retention policy.
  @Test func savedShelfEpisodeStillAppearsAsAnAutomaticReapCandidate() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(
      database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let savedOldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "saved-oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: savedOldest,
      fileIno: "saved-oldest")
    try await database.writeAsync { db in
      var savedShelfEntry = SavedShelfEntryRecord(
        accountId: accountId, itemId: show.itemRowId, podcastEpisodeId: savedOldest,
        savedAt: Date(timeIntervalSince1970: 3_000))
      try savedShelfEntry.insert(db)
    }

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    // Saved ≠ reap-protected: the shelf is a reminder, not a pin.
    #expect(
      candidates == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "saved-oldest")])
  }

  /// `listeningQueueEntry` is universal, so an audiobook row (no episode) for some unrelated item
  /// must not shield a different show's episode from reaping. The retention predicate matches on
  /// `podcastEpisodeId`, never on `itemId` alone.
  @Test func audiobookQueueRowHasNoBearingOnAPodcastEpisodesReaping() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")

    // An audiobook, queued whole, with no episode identity at all.
    let audiobook = try await insertAudiobookItem(database, accountId: accountId, libraryId: libraryId)
    try await insertAudiobookQueueEntry(database, accountId: accountId, itemId: audiobook)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(
      candidates == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "oldest")],
      "an unrelated audiobook queue row must not shield this show's own episode from reaping")
  }

  @Test func inFlightDownloadIsNeverReaped() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    // Still pending. An in-flight transfer is cancelled by the user, never by a sweep.
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest",
      completed: false)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty)
  }

  @Test func keepLatestReapsOnlyBeyondTheWindowAndOnlyWhileEnabled() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let store = try DownloadStore(database: database)

    // Show A: effectively enabled, keep latest 1. The middle and oldest episodes fall outside
    // the newest-1 window.
    let showA = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "a")
    try await insertShowOverride(
      database, accountId: accountId, itemId: showA.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let newestA = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showA.itemRowId, serverEpisodeId: "a-newest",
      publishedAt: Date(timeIntervalSince1970: 3_000))
    let middleA = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showA.itemRowId, serverEpisodeId: "a-middle",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldestA = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showA.itemRowId, serverEpisodeId: "a-oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: showA.itemRowId, episodeId: newestA, fileIno: "a-newest")
    try insertDownload(
      store, accountId: accountId, itemId: showA.itemRowId, episodeId: middleA, fileIno: "a-middle")
    try insertDownload(
      store, accountId: accountId, itemId: showA.itemRowId, episodeId: oldestA, fileIno: "a-oldest")

    // Show B: the same rank shape, but effectively disabled, so keep-latest must not fire.
    let showB = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "b")
    try await insertShowOverride(
      database, accountId: accountId, itemId: showB.itemRowId, override: .disabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let newestB = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showB.itemRowId, serverEpisodeId: "b-newest",
      publishedAt: Date(timeIntervalSince1970: 3_000))
    let oldestB = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showB.itemRowId, serverEpisodeId: "b-oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: showB.itemRowId, episodeId: newestB, fileIno: "b-newest")
    try insertDownload(
      store, accountId: accountId, itemId: showB.itemRowId, episodeId: oldestB, fileIno: "b-oldest")

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    // Oldest-first within a show; show B contributes nothing.
    #expect(
      candidates == [
        EpisodeDownloadKey(itemID: showA.serverItemID, episodeID: "a-oldest"),
        EpisodeDownloadKey(itemID: showA.serverItemID, episodeID: "a-middle"),
      ])
  }

  @Test func keepAllReapsNothingByWindow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    // 0 == keep all, so the window never applies however many episodes exist.
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 0, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty)
  }

  @Test func deleteAfterPlayedReapsOnlyFinishedEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    // A generous keep-latest window so this test isolates the delete-after-played policy alone.
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 10, deleteAfterPlayedOverride: true)
    let store = try DownloadStore(database: database)
    let finished = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "finished",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let unfinished = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "unfinished",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: finished, fileIno: "finished")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: unfinished,
      fileIno: "unfinished")
    try await insertMediaProgress(
      database, accountId: accountId, itemId: show.itemRowId, episodeId: finished, isFinished: true)
    try await insertMediaProgress(
      database, accountId: accountId, itemId: show.itemRowId, episodeId: unfinished,
      isFinished: false)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "finished")])
  }

  @Test func deleteAfterPlayedAppliesEvenWhenAutoDownloadIsOff() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    // Effectively disabled overall, but delete-after-played is its own independent field.
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .disabled,
      keepLatestOverride: nil, deleteAfterPlayedOverride: true)
    let store = try DownloadStore(database: database)
    let episode = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "finished",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: episode, fileIno: "finished")
    try await insertMediaProgress(
      database, accountId: accountId, itemId: show.itemRowId, episodeId: episode, isFinished: true)

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "finished")])
  }

  @Test func reapDoesNotClearAutoDownloadDecidedAt() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")
    let stampedAt = Date(timeIntervalSince1970: 500)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET autoDownloadDecidedAt = ? WHERE id = ?",
        arguments: [stampedAt, oldest])
    }

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "oldest")])
    let afterReap = try database.read { db in
      try PodcastEpisodeRecord.fetchOne(db, key: oldest)?.autoDownloadDecidedAt
    }
    #expect(afterReap == stampedAt, "the reap query never writes - it only reads")
  }

  @Test func reapIsIdempotentAcrossRepeatedPasses() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    let oldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "oldest",
      publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    let oldestDownloadId = try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: oldest, fileIno: "oldest")

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let firstPass = try await reapStore.reapCandidates()
    #expect(firstPass == [EpisodeDownloadKey(itemID: show.serverItemID, episodeID: "oldest")])

    // Forward the identity through the real purge protocol, as
    // `DownloadIntents.purgeEpisodeDownload` does at the DownloadStore layer.
    _ = try store.transition(downloadId: oldestDownloadId, to: .deleting)
    try store.finalizeDeletion(downloadId: oldestDownloadId)

    let secondPass = try await reapStore.reapCandidates()
    #expect(secondPass.isEmpty, "a purged row never resurfaces on a later pass")
  }

  @Test func reapQueryIsAccountScoped() async throws {
    let database = try AppDatabase.inMemory()
    let (firstAccountId, firstLibraryId) = try await insertAccountAndLibrary(database, suffix: "first")
    let (secondAccountId, secondLibraryId) = try await insertAccountAndLibrary(
      database, suffix: "second")
    let store = try DownloadStore(database: database)

    let firstShow = try await insertShow(
      database, accountId: firstAccountId, libraryId: firstLibraryId, suffix: "first")
    try await insertShowOverride(
      database, accountId: firstAccountId, itemId: firstShow.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let firstNewest = try await PersistenceFixtures.insertEpisode(
      database, accountId: firstAccountId, itemId: firstShow.itemRowId,
      serverEpisodeId: "first-newest", publishedAt: Date(timeIntervalSince1970: 2_000))
    let firstOldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: firstAccountId, itemId: firstShow.itemRowId,
      serverEpisodeId: "first-oldest", publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: firstAccountId, itemId: firstShow.itemRowId, episodeId: firstNewest,
      fileIno: "first-newest")
    try insertDownload(
      store, accountId: firstAccountId, itemId: firstShow.itemRowId, episodeId: firstOldest,
      fileIno: "first-oldest")

    let secondShow = try await insertShow(
      database, accountId: secondAccountId, libraryId: secondLibraryId, suffix: "second")
    try await insertShowOverride(
      database, accountId: secondAccountId, itemId: secondShow.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let secondNewest = try await PersistenceFixtures.insertEpisode(
      database, accountId: secondAccountId, itemId: secondShow.itemRowId,
      serverEpisodeId: "second-newest", publishedAt: Date(timeIntervalSince1970: 2_000))
    let secondOldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: secondAccountId, itemId: secondShow.itemRowId,
      serverEpisodeId: "second-oldest", publishedAt: Date(timeIntervalSince1970: 1_000))
    try insertDownload(
      store, accountId: secondAccountId, itemId: secondShow.itemRowId, episodeId: secondNewest,
      fileIno: "second-newest")
    try insertDownload(
      store, accountId: secondAccountId, itemId: secondShow.itemRowId, episodeId: secondOldest,
      fileIno: "second-oldest")

    let firstReapStore = PodcastAutoDownloadReapStore(database: database, accountId: firstAccountId)
    let firstCandidates = try await firstReapStore.reapCandidates()
    #expect(firstCandidates == [EpisodeDownloadKey(itemID: firstShow.serverItemID, episodeID: "first-oldest")])

    let secondReapStore = PodcastAutoDownloadReapStore(
      database: database, accountId: secondAccountId)
    let secondCandidates = try await secondReapStore.reapCandidates()
    #expect(
      secondCandidates == [
        EpisodeDownloadKey(itemID: secondShow.serverItemID, episodeID: "second-oldest")
      ])
  }

  @Test func softDeletedEpisodeBytesAreLeftToTheManualReclaim() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let show = try await insertShow(database, accountId: accountId, libraryId: libraryId, suffix: "1")
    try await insertShowOverride(
      database, accountId: accountId, itemId: show.itemRowId, override: .enabled,
      keepLatestOverride: 1, deleteAfterPlayedOverride: nil)
    let store = try DownloadStore(database: database)
    let newest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "newest",
      publishedAt: Date(timeIntervalSince1970: 2_000))
    // Soft-deleted, and otherwise outside the keep-latest-1 window. A soft-delete is a reversible
    // sync inference, so its bytes stay for the manual reclaim path
    // (`DownloadStore.tombstonedEpisodeDownloads`), never the automatic reaper.
    let goneOldest = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: show.itemRowId, serverEpisodeId: "gone",
      publishedAt: Date(timeIntervalSince1970: 1_000), softDeleted: true)
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: newest, fileIno: "newest")
    try insertDownload(
      store, accountId: accountId, itemId: show.itemRowId, episodeId: goneOldest, fileIno: "gone")

    let reapStore = PodcastAutoDownloadReapStore(database: database, accountId: accountId)
    let candidates = try await reapStore.reapCandidates()

    #expect(candidates.isEmpty)
  }

  // MARK: - Fixtures

  private struct Show {
    let itemRowId: Int64
    let serverItemID: String
  }

  private func insertAccountAndLibrary(_ database: AppDatabase, suffix: String = "1") async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example-\(suffix).com",
        serverUserId: "user-\(suffix)", serverVersion: "2.10.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-\(suffix)", mediaType: "podcast",
        name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }

  private func insertShow(
    _ database: AppDatabase, accountId: Int64, libraryId: Int64, suffix: String
  ) async throws -> Show {
    try await database.writeAsync { db in
      let serverItemID = "show-\(suffix)"
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemID,
        mediaKind: "podcast", title: "Show \(suffix)", sortTitle: "show \(suffix)")
      try item.insert(db)
      return Show(itemRowId: item.id!, serverItemID: serverItemID)
    }
  }

  private func insertShowOverride(
    _ database: AppDatabase, accountId: Int64, itemId: Int64,
    override: PodcastShowAutoDownloadOverride, keepLatestOverride: Int?,
    deleteAfterPlayedOverride: Bool?
  ) async throws {
    try await database.writeAsync { db in
      let record = PodcastShowSettingsRecord(
        itemId: itemId, accountId: accountId, autoDownloadOverride: override,
        keepLatestOverride: keepLatestOverride, deleteAfterPlayedOverride: deleteAfterPlayedOverride)
      try record.save(db)
    }
  }

  /// Enqueues one automatic-origin download and, unless `completed` is false, drives it all the
  /// way to `.completed`, the only state the reap query considers.
  @discardableResult
  private func insertDownload(
    _ store: DownloadStore, accountId: Int64, itemId: Int64, episodeId: Int64, fileIno: String,
    origin: DownloadOrigin = .automatic, completed: Bool = true
  ) throws -> Int64 {
    let record = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: fileIno,
      orderIndex: 0, destinationRelativePath: "show/\(fileIno).mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30, origin: origin)
    guard completed else { return record.id! }
    _ = try store.transition(downloadId: record.id!, to: .downloading)
    let completedRecord = try store.complete(downloadId: record.id!, finalSizeBytes: 500)
    return completedRecord.id!
  }

  private func insertMediaProgress(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, episodeId: Int64, isFinished: Bool
  ) async throws {
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId,
        currentTime: isFinished ? 100 : 10, isFinished: isFinished, localSequence: 1,
        origin: .local, originKey: "device")
      try progress.insert(db)
    }
  }

  private func insertActivePlaybackSession(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, episodeId: Int64
  ) async throws {
    try await database.writeAsync { db in
      var session = PlaybackSessionRecord(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        podcastEpisodeId: episodeId, startedAt: Date(), updatedAt: Date(), state: .active)
      try session.insert(db)
    }
  }

  private func insertQueueEntry(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, episodeId: Int64, position: Int = 0
  ) async throws {
    try await database.writeAsync { db in
      var entry = ListeningQueueEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, position: position)
      try entry.insert(db)
    }
  }

  /// A bare audiobook `item` row, unrelated to any show under test. Just enough to satisfy
  /// `listeningQueueEntry`'s `(accountId, itemId)` FK for an audiobook-shaped queue row.
  private func insertAudiobookItem(_ database: AppDatabase, accountId: Int64, libraryId: Int64)
    async throws -> Int64
  {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "audiobook-\(UUID().uuidString)",
        mediaKind: "book", title: "Audiobook", sortTitle: "audiobook")
      try item.insert(db)
      return item.id!
    }
  }

  private func insertAudiobookQueueEntry(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, position: Int = 0
  ) async throws {
    try await database.writeAsync { db in
      var entry = ListeningQueueEntryRecord(accountId: accountId, itemId: itemId, position: position)
      try entry.insert(db)
    }
  }
}
