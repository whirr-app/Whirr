import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite(.timeLimit(.minutes(1))) struct PodcastReadingTests {

  @Test("episodes are show-scoped, newest-first with stable ties and null dates last")
  func episodesAreScopedOrderedAndProjected() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let reading = DefaultPodcastReading(database: database)

    let sameDate = Date(timeIntervalSince1970: 1_800_000_000)
    let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newestB = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "new-b",
      title: "Newest B", publishedAt: sameDate, storedAudio: true)
    let newestA = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "new-a",
      title: "Newest A", subtitle: "A subtitle", description: "<p>A description</p>",
      seasonNumber: "2", episodeNumber: "4", episodeType: "full", durationSeconds: 400,
      sizeBytes: 2_048, publishedAt: sameDate, storedAudio: true)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "old",
      title: "Older", publishedAt: olderDate)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "undated",
      title: "Undated", publishedAt: nil)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "deleted",
      title: "Deleted", publishedAt: sameDate.addingTimeInterval(10), softDeleted: true)

    let other = try await Self.seedShow(database, suffix: "other")
    _ = try await Self.insertEpisode(
      database, accountId: other.accountId, itemId: other.itemId, id: "other-episode",
      title: "Other", publishedAt: sameDate.addingTimeInterval(20))

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: newestA,
        currentTime: 120, isFinished: false, localSequence: 7, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)

      var itemProgress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, currentTime: 999,
        isFinished: true, localSequence: 8, origin: .local, originKey: "fixture-device")
      try itemProgress.insert(db)

      var completed = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: newestA,
        serverFileIno: "episode-file", orderIndex: 0,
        destinationRelativePath: "podcast/new-a.mp3", expectedBytes: 2_048,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 400, receivedBytes: 2_048,
        state: .completed)
      try completed.insert(db)

      var itemDownload = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, serverFileIno: "item-file",
        orderIndex: 0, destinationRelativePath: "podcast/item.mp3", expectedBytes: 10,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 1, state: .failed,
        errorCategory: .transport)
      try itemDownload.insert(db)
    }

    var iterator = reading.observeEpisodes(itemId: seeded.serverItemId).makeAsyncIterator()
    let rows = try #require(await iterator.next())

    #expect(rows.map(\.id) == ["new-a", "new-b", "old", "undated"])
    let projected = try #require(rows.first)
    #expect(projected.title == "Newest A")
    #expect(projected.subtitle == "A subtitle")
    #expect(projected.episodeDescription == "<p>A description</p>")
    #expect(projected.seasonNumber == "2")
    #expect(projected.episodeNumber == "4")
    #expect(projected.episodeType == "full")
    #expect(projected.durationSeconds == 400)
    #expect(projected.sizeBytes == 2_048)
    #expect(projected.publishedAt == sameDate)
    #expect(projected.progressSeconds == 120)
    #expect(projected.isPlayed)
    #expect(projected.isFinished == false)
    #expect(projected.downloadStatus == .completed)
    #expect(projected.isAvailableOnServer)

    let sibling = try #require(rows.first(where: { $0.id == "new-b" }))
    #expect(sibling.progressSeconds == 0, "item-level progress must not decorate an episode")
    #expect(sibling.downloadStatus == .notDownloaded, "item-level downloads must not decorate an episode")
    #expect(sibling.isAvailableOnServer)
    _ = newestB
  }

  @Test("partial stored-audio metadata is unavailable")
  func partialStoredAudioIsUnavailable() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "partial",
      title: "Partial", publishedAt: nil)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET storedAudioIno = ? WHERE id = ?",
        arguments: ["ino-without-validation", episodeId])
    }

    var iterator =
      DefaultPodcastReading(database: database)
      .observeEpisodes(itemId: seeded.serverItemId)
      .makeAsyncIterator()
    let rows = try #require(await iterator.next())
    #expect(rows.first?.isAvailableOnServer == false)
  }

  @Test("episode summary uses stored audio duration for end progress")
  func episodeSummaryUsesStoredAudioDurationForEndProgress() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "duration-drift",
      title: "Duration Drift", durationSeconds: 900, publishedAt: nil, storedAudio: true)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET storedAudioDurationSeconds = ? WHERE id = ?",
        arguments: [600, episodeId])
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        currentTime: 600, isFinished: false, localSequence: 1, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)
    }

    var iterator =
      DefaultPodcastReading(database: database)
      .observeEpisodes(itemId: seeded.serverItemId)
      .makeAsyncIterator()
    let rows = try #require(await iterator.next())
    let episode = try #require(rows.first)
    let duration = try #require(episode.durationSeconds)

    #expect(duration == 600)
    #expect(max(duration - episode.progressSeconds, 0) == 0)
    #expect(min(max(episode.progressSeconds / duration, 0), 1) == 1)
  }

  @Test("episode summary falls back to feed duration without stored audio")
  func episodeSummaryFallsBackToFeedDurationWithoutStoredAudio() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "feed-duration",
      title: "Feed Duration", durationSeconds: 900, publishedAt: nil)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        currentTime: 480, isFinished: false, localSequence: 1, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)
    }

    var iterator =
      DefaultPodcastReading(database: database)
      .observeEpisodes(itemId: seeded.serverItemId)
      .makeAsyncIterator()
    let rows = try #require(await iterator.next())
    let episode = try #require(rows.first)

    #expect(episode.durationSeconds == 900)
    #expect(max(episode.durationSeconds! - episode.progressSeconds, 0) == 420)
    #expect(min(max(episode.progressSeconds / episode.durationSeconds!, 0), 1) == 480.0 / 900)
  }

  @Test("the episode list floors playback position to the minute; the lookup keeps it exact")
  func theEpisodeListFloorsPlaybackPosition() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "playing",
      title: "Playing", publishedAt: nil, storedAudio: true)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        currentTime: 754.3, isFinished: false, localSequence: 1, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)
    }
    let reading = DefaultPodcastReading(database: database)

    var iterator = reading.observeEpisodes(itemId: seeded.serverItemId).makeAsyncIterator()
    let listed = try #require(await iterator.next())
    #expect(listed.first?.progressSeconds == 720)
    let prefix = try #require(reading.episodePrefix(itemId: seeded.serverItemId, limit: 10))
    #expect(prefix.episodes.first?.progressSeconds == 720)
    let context = try #require(
      await reading.episode(itemID: seeded.serverItemId, episodeID: "playing"))
    #expect(context.episode.progressSeconds == 754.3)
  }

  @Test("duplicate server item ids in another account never merge or leak")
  func duplicateServerItemIdsAreIsolated() async throws {
    let database = try AppDatabase.inMemory()
    let selected = try await Self.seedShow(database, suffix: "selected", serverItemId: "shared-show")
    let duplicate = try await Self.seedShow(database, suffix: "duplicate", serverItemId: "shared-show")
    _ = try await Self.insertEpisode(
      database, accountId: selected.accountId, itemId: selected.itemId, id: "selected-episode",
      title: "Selected Episode", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try await Self.insertEpisode(
      database, accountId: duplicate.accountId, itemId: duplicate.itemId, id: "leaked-episode",
      title: "Leaked Episode", publishedAt: Date(timeIntervalSince1970: 1_800_000_000))

    let selectedCheck = Date(timeIntervalSince1970: 1_710_000_000)
    let duplicateCheck = Date(timeIntervalSince1970: 1_810_000_000)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE item
          SET podcastAutoDownloadEpisodes = 0, podcastLastEpisodeCheck = ?
          WHERE id = ?
          """,
        arguments: [selectedCheck, selected.itemId])
      try db.execute(
        sql: """
          UPDATE item
          SET podcastAutoDownloadEpisodes = 1, podcastLastEpisodeCheck = ?
          WHERE id = ?
          """,
        arguments: [duplicateCheck, duplicate.itemId])
    }

    let reading = DefaultPodcastReading(database: database)
    var episodes = reading.observeEpisodes(itemId: "shared-show").makeAsyncIterator()
    let rows = try #require(await episodes.next())
    #expect(rows.map(\.id) == ["selected-episode"])

    var diagnostics = reading.observeShowDiagnostics(itemId: "shared-show").makeAsyncIterator()
    let selectedDiagnostics = try #require(await diagnostics.next())
    #expect(selectedDiagnostics?.autoDownloadEpisodes == false)
    #expect(selectedDiagnostics?.lastEpisodeCheck == selectedCheck)
  }

  @Test("the episode prefix is the observation's first value, cut at whole episodes")
  func episodePrefixMatchesTheObservationBaseline() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let reading = DefaultPodcastReading(database: database)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "newest",
      title: "Newest", publishedAt: Date(timeIntervalSince1970: 1_900_000_000))
    // Two download rows: a row limit can fall between them.
    let middle = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "middle",
      title: "Middle", publishedAt: Date(timeIntervalSince1970: 1_800_000_000))
    for ino in ["ino-a", "ino-b"] {
      _ = try await Self.insertDownload(
        database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: middle,
        expectedBytes: 100, receivedBytes: 100, state: .completed, serverFileIno: ino)
    }
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "oldest",
      title: "Oldest", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let observed = try #require(
      await AsyncStreamTestSupport.first(reading.observeEpisodes(itemId: seeded.serverItemId)))
    #expect(observed.map(\.id) == ["newest", "middle", "oldest"])

    let id = seeded.serverItemId
    // Rows: newest, middle, middle, oldest. An episode whose rows the limit may have cut is left out.
    #expect(reading.episodePrefix(itemId: id, limit: 2) == .init(episodes: [observed[0]], isComplete: false))
    #expect(reading.episodePrefix(itemId: id, limit: 3) == .init(episodes: [observed[0]], isComplete: false))
    #expect(
      reading.episodePrefix(itemId: id, limit: 4)
        == .init(episodes: Array(observed.prefix(2)), isComplete: false))
    #expect(reading.episodePrefix(itemId: id, limit: 5) == .init(episodes: observed, isComplete: true))
    #expect(reading.episodePrefix(itemId: "missing-show", limit: 5) == .init(episodes: [], isComplete: true))
  }

  @Test("episode observation resolves a show inserted after observation starts")
  func episodeObservationResolvesInsideTrackedFetch() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(reading.observeEpisodes(itemId: "late-show"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    let seeded = try await Self.seedShow(database, serverItemId: "late-show")
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "late-episode",
      title: "Late Episode", publishedAt: nil)

    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty == false } })
    let rows = try #require(observations.last { $0.isEmpty == false })
    #expect(rows.map(\.id) == ["late-episode"])
  }

  @Test("episode observation re-emits for episode progress and download changes")
  func episodeObservationReemits() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "episode",
      title: "Episode", publishedAt: nil, storedAudio: true)
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeEpisodes(itemId: seeded.serverItemId))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.first?.progressSeconds == 0)
    #expect(initial.first?.downloadStatus == .notDownloaded)

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        currentTime: 42, isFinished: false, localSequence: 1, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)
    }
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.first?.progressSeconds == 42 }
      })
    let progressed = try #require(observations.last { $0.first?.progressSeconds == 42 })
    #expect(progressed.first?.progressSeconds == 42)

    try await database.writeAsync { db in
      var download = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        serverFileIno: "episode-file", orderIndex: 0,
        destinationRelativePath: "podcast/episode.mp3", expectedBytes: 100,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, state: .pending)
      try download.insert(db)
    }
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.first?.downloadStatus == .queued }
      })
    let downloaded = try #require(
      observations.last { $0.first?.downloadStatus == .queued })
    #expect(downloaded.first?.progressSeconds == 42)
  }

  @Test("episode list never re-emits on byte writes; the progress projection steps by quantum")
  func episodeListNeverReEmitsOnByteWrites() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "quantum",
      title: "Quantum", publishedAt: nil, storedAudio: true)
    let downloadID = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: episodeID,
      expectedBytes: 1_000, receivedBytes: 0, state: .downloading)
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeEpisodes(itemId: seeded.serverItemId))
    let progress = PersistenceObservationCollector(
      reading.observeEpisodeDownloadProgress(itemId: seeded.serverItemId))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first?.first?.downloadStatus == .downloading(progressFraction: 0))
    #expect(await TestSupport.waitUntil { progress.values.isEmpty == false })
    #expect(progress.values.first == ["quantum": 0])
    let listCount = observations.values.count
    let progressCount = progress.values.count

    // These writes stay in the initial 2% bucket. Do not await a stream value here: the progress
    // projection's `removeDuplicates` suppresses them, and the list (which selects no byte
    // column) must not see them at all.
    try await Self.updateDownloadBytes(database, id: downloadID, receivedBytes: 1)
    try await Self.updateDownloadBytes(database, id: downloadID, receivedBytes: 2)
    try await Self.updateDownloadBytes(database, id: downloadID, receivedBytes: 39)
    #expect(await TestSupport.waitUntil { progress.contains { $0["quantum"] == 0.02 } })
    #expect(progress.values.count == progressCount + 1)

    try await Self.updateDownloadBytes(database, id: downloadID, receivedBytes: 41)
    #expect(await TestSupport.waitUntil { progress.contains { $0["quantum"] == 0.04 } })
    #expect(progress.values.count == progressCount + 2)
    #expect(progress.values.last == ["quantum": 0.04])

    #expect(observations.values.count == listCount)
    #expect(observations.values.last?.first?.downloadStatus == .downloading(progressFraction: 0))
  }

  @Test("the progress projection sums an episode's file rows and omits every other state")
  func progressProjectionSumsFileRowsAndOmitsOtherStates() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let splitEpisodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "split",
      title: "Split", publishedAt: nil, storedAudio: true)
    let queuedEpisodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "queued",
      title: "Queued", publishedAt: nil, storedAudio: true)
    _ = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: splitEpisodeID,
      expectedBytes: 600, receivedBytes: 600, state: .downloading)
    try await database.writeAsync { db in
      var second = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: splitEpisodeID,
        serverFileIno: "ino-episode-2", orderIndex: 1,
        destinationRelativePath: "podcast/episode-2.mp3", expectedBytes: 400,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, receivedBytes: 150,
        state: .downloading, errorCategory: nil)
      try second.insert(db)
    }
    _ = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: queuedEpisodeID,
      expectedBytes: 1_000, receivedBytes: 0, state: .pending)

    var iterator = DefaultPodcastReading(database: database)
      .observeEpisodeDownloadProgress(itemId: seeded.serverItemId).makeAsyncIterator()
    let progress = try #require(await iterator.next())

    // 750 of 1,000 bytes, floored to the 2% quantum.
    #expect(progress == ["split": 0.74])
  }

  @Test("episode list emits every download state transition without byte changes")
  func episodeListEmitsStateTransitionsWithoutByteChanges() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let queuedEpisodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "queued-to-downloading",
      title: "Queued", publishedAt: nil, storedAudio: true)
    let completedEpisodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "downloading-to-completed",
      title: "Completed", publishedAt: nil, storedAudio: true)
    let failedEpisodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "downloading-to-failed",
      title: "Failed", publishedAt: nil, storedAudio: true)
    let queuedDownloadID = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: queuedEpisodeID,
      expectedBytes: 1_000, receivedBytes: 0, state: .pending)
    let completedDownloadID = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: completedEpisodeID,
      expectedBytes: 1_000, receivedBytes: 0, state: .downloading)
    let failedDownloadID = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: failedEpisodeID,
      expectedBytes: 1_000, receivedBytes: 0, state: .downloading)
    let observations = PersistenceObservationCollector(
      DefaultPodcastReading(database: database).observeEpisodes(itemId: seeded.serverItemId))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(Self.status(in: initial, for: "queued-to-downloading") == .queued)
    #expect(Self.status(in: initial, for: "downloading-to-completed") == .downloading(progressFraction: 0))
    #expect(Self.status(in: initial, for: "downloading-to-failed") == .downloading(progressFraction: 0))
    let initialCount = observations.values.count

    try await Self.updateDownloadState(database, id: queuedDownloadID, state: .downloading)
    #expect(
      await TestSupport.waitUntil {
        Self.observations(observations, containStatus: .downloading(progressFraction: 0), for: "queued-to-downloading")
      })

    try await Self.updateDownloadState(database, id: completedDownloadID, state: .completed)
    #expect(
      await TestSupport.waitUntil {
        Self.observations(observations, containStatus: .completed, for: "downloading-to-completed")
      })

    try await Self.updateDownloadState(
      database, id: failedDownloadID, state: .failed, errorCategory: .transport)
    #expect(
      await TestSupport.waitUntil {
        Self.observations(
          observations, containStatus: .failed(category: .transport), for: "downloading-to-failed")
      })

    #expect(observations.values.count == initialCount + 3)
  }

  @Test("single episode lookup keeps exact download progress")
  func singleEpisodeLookupKeepsExactDownloadProgress() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeID = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "exact",
      title: "Exact", publishedAt: nil, storedAudio: true)
    _ = try await Self.insertDownload(
      database, accountId: seeded.accountId, itemId: seeded.itemId, episodeID: episodeID,
      expectedBytes: 1_000, receivedBytes: 37, state: .downloading)
    let reading = DefaultPodcastReading(database: database)

    let context = try #require(
      await reading.episode(itemID: seeded.serverItemId, episodeID: "exact"))

    #expect(context.episode.downloadStatus == .downloading(progressFraction: 0.037))
  }

  @Test("show diagnostics resolve inside the observation and re-emit")
  func diagnosticsResolveAndReemit() async throws {
    let database = try AppDatabase.inMemory()
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeShowDiagnostics(itemId: "late-show"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial == nil)

    let seeded = try await Self.seedShow(database, serverItemId: "late-show")
    let checkedAt = Date(timeIntervalSince1970: 1_750_000_000)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE item
          SET podcastAutoDownloadEpisodes = ?, podcastLastEpisodeCheck = ?
          WHERE id = ?
          """,
        arguments: [true, checkedAt, seeded.itemId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0?.autoDownloadEpisodes == true && $0?.lastEpisodeCheck == checkedAt
        }
      })
    let diagnostics = try #require(
      observations.last { $0?.autoDownloadEpisodes == true && $0?.lastEpisodeCheck == checkedAt })
    #expect(diagnostics?.autoDownloadEpisodes == true)
    #expect(diagnostics?.lastEpisodeCheck == checkedAt)
  }

  @Test("show diagnostics observe podcast server settings and re-emit changes")
  func diagnosticsObservePodcastServerSettings() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let reading = DefaultPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeShowDiagnostics(itemId: seeded.serverItemId))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    let initialDiagnostics = try #require(initial)
    #expect(initialDiagnostics.autoDownloadSchedule == nil)
    #expect(initialDiagnostics.maxEpisodesToKeep == nil)
    #expect(initialDiagnostics.maxNewEpisodesToDownload == nil)

    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE item
          SET podcastAutoDownloadSchedule = ?,
              podcastMaxEpisodesToKeep = ?,
              podcastMaxNewEpisodesToDownload = ?
          WHERE id = ?
          """,
        arguments: ["0 0 * * *", 0, 3, seeded.itemId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0?.autoDownloadSchedule == "0 0 * * *"
            && $0?.maxEpisodesToKeep == 0
            && $0?.maxNewEpisodesToDownload == 3
        }
      })
    let populated = try #require(
      observations.last {
        $0?.autoDownloadSchedule == "0 0 * * *"
          && $0?.maxEpisodesToKeep == 0
          && $0?.maxNewEpisodesToDownload == 3
      })
    #expect(populated?.maxEpisodesToKeep == 0)

    let countBeforeChange = observations.values.count
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET podcastAutoDownloadSchedule = ? WHERE id = ?",
        arguments: ["0 */6 * * *", seeded.itemId])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.values.count > countBeforeChange
          && observations.contains {
            $0?.autoDownloadSchedule == "0 */6 * * *"
              && $0?.maxEpisodesToKeep == 0
              && $0?.maxNewEpisodesToDownload == 3
          }
      })
    let changed = try #require(
      observations.last {
        $0?.autoDownloadSchedule == "0 */6 * * *"
          && $0?.maxEpisodesToKeep == 0
          && $0?.maxNewEpisodesToDownload == 3
      })
    #expect(changed?.autoDownloadSchedule == "0 */6 * * *")
  }

  @Test("no-op podcast reading finishes without values")
  func noOpReadingFinishes() async throws {
    let reading = NoOpPodcastReading()
    var episodes = reading.observeEpisodes(itemId: "show").makeAsyncIterator()
    var diagnostics = reading.observeShowDiagnostics(itemId: "show").makeAsyncIterator()
    #expect(await episodes.next() == nil)
    #expect(await diagnostics.next() == nil)
    #expect(try await reading.episode(itemID: "show", episodeID: "episode") == nil)
    #expect(try await reading.recentEpisodeDescriptions(itemId: "show", limit: 20) == [])
  }

  @Test
  func singleEpisodeReadReturnsFullDescription() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database, title: "Ocean Signals", author: "Remote Concern Radio")
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "ep-1",
      title: "Episode One", subtitle: "A subtitle", description: "<p>Full description</p>",
      seasonNumber: "1", episodeNumber: "2", episodeType: "full", durationSeconds: 500,
      sizeBytes: 4_096, publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let reading = DefaultPodcastReading(database: database)

    let context = try #require(
      await reading.episode(itemID: seeded.serverItemId, episodeID: "ep-1"))

    #expect(context.episode.id == "ep-1")
    #expect(context.episode.title == "Episode One")
    #expect(context.episode.subtitle == "A subtitle")
    #expect(context.episode.episodeDescription == "<p>Full description</p>")
    #expect(context.episode.seasonNumber == "1")
    #expect(context.episode.episodeNumber == "2")
    #expect(context.episode.episodeType == "full")
    #expect(context.episode.durationSeconds == 500)
    #expect(context.episode.sizeBytes == 4_096)
    #expect(context.showTitle == "Ocean Signals")
    #expect(context.showAuthor == "Remote Concern Radio")
  }

  @Test("the single episode read carries its show's serverUpdatedAt, which revisions its cover")
  func singleEpisodeReadCarriesShowServerUpdatedAt() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let showUpdatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET serverUpdatedAt = ? WHERE id = ?",
        arguments: [showUpdatedAt, seeded.itemId])
    }
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "ep-1",
      title: "Episode One", publishedAt: nil)
    let reading = DefaultPodcastReading(database: database)

    let context = try #require(
      await reading.episode(itemID: seeded.serverItemId, episodeID: "ep-1"))

    #expect(context.showServerUpdatedAt == showUpdatedAt)
  }

  @Test
  func singleEpisodeReadReflectsProgressAndDownloadStatus() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    let episodeId = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "ep-progress",
      title: "Progress Episode", publishedAt: nil, storedAudio: true)
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        currentTime: 77, isFinished: false, localSequence: 1, origin: .local,
        originKey: "fixture-device")
      try progress.insert(db)
      var download = DownloadRecord(
        accountId: seeded.accountId, itemId: seeded.itemId, podcastEpisodeId: episodeId,
        serverFileIno: "episode-file", orderIndex: 0,
        destinationRelativePath: "podcast/ep-progress.mp3", expectedBytes: 100,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, receivedBytes: 100,
        state: .completed)
      try download.insert(db)
    }
    let reading = DefaultPodcastReading(database: database)

    let context = try #require(
      await reading.episode(itemID: seeded.serverItemId, episodeID: "ep-progress"))

    #expect(context.episode.progressSeconds == 77)
    #expect(context.episode.isPlayed)
    #expect(context.episode.isFinished == false)
    #expect(context.episode.downloadStatus == .completed)
  }

  @Test
  func recentEpisodeDescriptionsAreShowScopedNewestFirstAndSkipDeletedOrEmpty() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database, suffix: "primary")
    let other = try await Self.seedShow(database, suffix: "other")
    let date = { Date(timeIntervalSince1970: $0) }
    try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "old", title: "Old",
      description: "old", publishedAt: date(10))
    try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "new", title: "New",
      description: "new", publishedAt: date(30))
    try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "silent", title: "Silent",
      publishedAt: date(25))
    try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "gone", title: "Gone",
      description: "gone", publishedAt: date(20), softDeleted: true)
    try await Self.insertEpisode(
      database, accountId: other.accountId, itemId: other.itemId, id: "elsewhere", title: "Elsewhere",
      description: "elsewhere", publishedAt: date(40))
    let reading = DefaultPodcastReading(database: database)

    #expect(
      try await reading.recentEpisodeDescriptions(itemId: seeded.serverItemId, limit: 20) == ["new", "old"])
    #expect(try await reading.recentEpisodeDescriptions(itemId: seeded.serverItemId, limit: 1) == ["new"])
    #expect(try await reading.recentEpisodeDescriptions(itemId: "missing", limit: 20) == [])
  }

  @Test
  func singleEpisodeReadNilForUnknownEpisode() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "known",
      title: "Known", publishedAt: nil)
    let reading = DefaultPodcastReading(database: database)

    let context = try await reading.episode(itemID: seeded.serverItemId, episodeID: "missing")

    #expect(context == nil)
  }

  @Test
  func singleEpisodeReadNilForEpisodeOfOtherItem() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database, suffix: "primary")
    let other = try await Self.seedShow(database, suffix: "other")
    _ = try await Self.insertEpisode(
      database, accountId: other.accountId, itemId: other.itemId, id: "other-episode",
      title: "Other Episode", publishedAt: nil)
    let reading = DefaultPodcastReading(database: database)

    let context = try await reading.episode(
      itemID: seeded.serverItemId, episodeID: "other-episode")

    #expect(context == nil)
  }

  @Test("episode-list observation follows library inclusion, while the explicit episode lookup is retained")
  func episodeListObservationTracksInclusionWhileExplicitLookupIsRetained() async throws {
    let database = try AppDatabase.inMemory()
    let seeded = try await Self.seedShow(database)
    _ = try await Self.insertEpisode(
      database, accountId: seeded.accountId, itemId: seeded.itemId, id: "retained-episode",
      title: "Retained Episode", publishedAt: nil)
    try await database.writeAsync { db in
      var library = LibraryRecord(
        accountId: seeded.accountId, serverLibraryId: "excluded-podcasts", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try library.insert(db)
      var show = ItemRecord(
        accountId: seeded.accountId, libraryId: library.id!, serverItemId: "excluded-show",
        mediaKind: "podcast", title: "Excluded", sortTitle: "excluded")
      try show.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: seeded.accountId, itemId: show.id!, serverEpisodeId: "excluded-episode",
        title: "Excluded Episode", lastSeenGeneration: 1)
      try episode.insert(db)
    }
    let reading = DefaultPodcastReading(database: database)
    var excluded = reading.observeEpisodes(itemId: "excluded-show").makeAsyncIterator()
    #expect(try #require(await excluded.next()).isEmpty)
    let observations = PersistenceObservationCollector(reading.observeEpisodes(itemId: seeded.serverItemId))
    #expect(await TestSupport.waitUntil { observations.contains { $0.map(\.id) == ["retained-episode"] } })

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("accountId") == seeded.accountId)
        .filter(Column("serverLibraryId") == "library-primary")
        .updateAll(db, Column("isIncluded").set(to: false))
    }
    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty } })
    #expect(try await reading.episode(itemID: seeded.serverItemId, episodeID: "retained-episode") != nil)

    try await database.writeAsync { db in
      try LibraryRecord
        .filter(Column("accountId") == seeded.accountId)
        .filter(Column("serverLibraryId") == "library-primary")
        .updateAll(db, Column("isIncluded").set(to: true))
    }
    #expect(await TestSupport.waitUntil { observations.contains { $0.map(\.id) == ["retained-episode"] } })
  }

  private static func seedShow(
    _ database: AppDatabase,
    suffix: String = "primary",
    serverItemId: String? = nil,
    title: String = "Show",
    author: String? = nil
  ) async throws -> (accountId: Int64, itemId: Int64, serverItemId: String) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      let resolvedServerItemId = serverItemId ?? "show-\(suffix)"
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: resolvedServerItemId,
        mediaKind: "podcast", title: title, sortTitle: title.lowercased(), author: author)
      try item.insert(db)
      return (account.id!, item.id!, resolvedServerItemId)
    }
  }

  @discardableResult
  private static func insertEpisode(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    id: String,
    title: String,
    subtitle: String? = nil,
    description: String? = nil,
    seasonNumber: String? = nil,
    episodeNumber: String? = nil,
    episodeType: String? = nil,
    durationSeconds: Double? = nil,
    sizeBytes: Int? = nil,
    publishedAt: Date?,
    storedAudio: Bool = false,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: accountId, itemId: itemId, serverEpisodeId: id, title: title,
        subtitle: subtitle, episodeDescription: description, seasonNumber: seasonNumber,
        episodeNumber: episodeNumber, episodeType: episodeType, durationSeconds: durationSeconds,
        sizeBytes: sizeBytes, publishedAt: publishedAt,
        storedAudioIno: storedAudio ? "ino-\(id)" : nil,
        storedAudioExpectedSize: storedAudio ? (sizeBytes ?? 1_000) : nil,
        storedAudioMimeType: storedAudio ? "audio/mpeg" : nil,
        storedAudioDurationSeconds: storedAudio ? (durationSeconds ?? 60) : nil,
        lastSeenGeneration: 1, softDeleted: softDeleted)
      try episode.insert(db)
      return episode.id!
    }
  }

  private static func insertDownload(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    episodeID: Int64,
    expectedBytes: Int64,
    receivedBytes: Int64,
    state: DownloadState,
    errorCategory: DownloadErrorCategory? = nil,
    serverFileIno: String = "ino-episode"
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var download = DownloadRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeID,
        serverFileIno: serverFileIno, orderIndex: 0,
        destinationRelativePath: "podcast/episode.mp3", expectedBytes: expectedBytes,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, receivedBytes: receivedBytes,
        state: state, errorCategory: errorCategory)
      try download.insert(db)
      return download.id!
    }
  }

  private static func updateDownloadBytes(
    _ database: AppDatabase, id: Int64, receivedBytes: Int64
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE download SET receivedBytes = ? WHERE id = ?",
        arguments: [receivedBytes, id])
    }
  }

  private static func updateDownloadState(
    _ database: AppDatabase,
    id: Int64,
    state: DownloadState,
    errorCategory: DownloadErrorCategory? = nil
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE download SET state = ?, errorCategory = ? WHERE id = ?",
        arguments: [state.rawValue, errorCategory?.rawValue, id])
    }
  }

  private static func status(
    in rows: [PodcastEpisodeSummary], for episodeID: String
  ) -> ItemDownloadStatus? {
    rows.first(where: { $0.id == episodeID })?.downloadStatus
  }

  private static func observations(
    _ observations: PersistenceObservationCollector<[PodcastEpisodeSummary]>,
    containStatus status: ItemDownloadStatus,
    for episodeID: String
  ) -> Bool {
    observations.contains { rows in Self.status(in: rows, for: episodeID) == status }
  }
}
