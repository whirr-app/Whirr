import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

extension DownloadStoreTests {
  // MARK: - Observation surface (DownloadReading)

  @Test("observeItemDownloadAggregate emits on state/progress change, off the main actor")
  func observeItemDownloadAggregateEmitsOnStateAndProgressChange() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)

    let observations = PersistenceObservationCollector(
      reading.observeItemDownloadAggregate(itemId: "item-1"))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.state == .none)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    #expect(await TestSupport.waitUntil { observations.contains { $0.state == .partial } })
    let afterEnqueue = try #require(observations.last { $0.state == .partial })
    #expect(DownloadStoreFixtures.currentThreadIsMain() == false)
    #expect(afterEnqueue.state == .partial)
    #expect(afterEnqueue.progressFraction == 0)

    _ = try store.transition(downloadId: created.id!, to: .downloading)
    _ = try store.transition(downloadId: created.id!, to: .paused, receivedBytes: 500)

    // Two writes landed since `afterEnqueue` (entering `downloading`, then `paused` with the
    // byte update). Each emits, and the first does not change the progress fraction. Drain until
    // the byte-progress value appears rather than assuming a fixed emission count.
    #expect(await TestSupport.waitUntil { observations.contains { $0.progressFraction == 0.5 } })
    let afterProgress = try #require(observations.last { $0.progressFraction == 0.5 })
    #expect(afterProgress.progressFraction == 0.5)

    // Resuming passes back through `pending` before a fresh `downloading` attempt (see
    // `DownloadStore.legalTransitions`). Neither step changes the aggregate's progress/state, so
    // drain until the post-completion value appears rather than assuming a fixed emission count.
    _ = try store.transition(downloadId: created.id!, to: .pending)
    _ = try store.transition(downloadId: created.id!, to: .downloading)
    _ = try store.complete(downloadId: created.id!, finalSizeBytes: 1000)

    #expect(await TestSupport.waitUntil { observations.contains { $0.state == .complete } })
    let afterComplete = try #require(observations.last { $0.state == .complete })
    #expect(afterComplete.progressFraction == 1.0)
  }

  @Test("observeItemDownloadStatus emits the detailed rollup on state change")
  func observeItemDownloadStatusEmitsDetailedRollup() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)

    let observations = PersistenceObservationCollector(
      reading.observeItemDownloadStatus(itemId: "item-1"))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial == .notDownloaded)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    #expect(await TestSupport.waitUntil { observations.contains { $0 == .queued } })
    let afterEnqueue = try #require(observations.last { $0 == .queued })
    #expect(afterEnqueue == .queued)

    _ = try store.transition(downloadId: created.id!, to: .downloading)
    _ = try store.transition(downloadId: created.id!, to: .paused, receivedBytes: 500)

    #expect(await TestSupport.waitUntil { observations.contains { $0 == .paused } })
    let afterPause = try #require(observations.last { $0 == .paused })
    #expect(afterPause == .paused)
  }

  @Test("observeItemFormatDownloadStatus emits each medium's detailed rollup")
  func observeItemFormatDownloadStatusEmitsPerMediumRollup() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "mixed-item")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeItemFormatDownloadStatus(itemId: "mixed-item"))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(try #require(observations.values.first) == ItemFormatDownloadStatus())

    let audio = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "audio-ino", orderIndex: 0,
      destinationRelativePath: "mixed-item.m4b", expectedBytes: 10,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
    _ = try store.transition(downloadId: try #require(audio.id), to: .downloading)
    _ = try store.complete(downloadId: try #require(audio.id), finalSizeBytes: 10)
    let ebook = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-ino", orderIndex: 0,
      destinationRelativePath: "mixed-item.epub", expectedBytes: 10,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)

    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0.audio == .completed && $0.ebook == .queued
        }
      })
    #expect(
      await reading.currentItemFormatDownloadStatusAsync(itemId: "mixed-item")
        == ItemFormatDownloadStatus(audio: .completed, ebook: .queued))

    _ = try store.transition(downloadId: try #require(ebook.id), to: .downloading)
    _ = try store.complete(downloadId: try #require(ebook.id), finalSizeBytes: 10)
    #expect(
      await TestSupport.waitUntil {
        observations.contains {
          $0.audio == .completed && $0.ebook == .completed
        }
      })
  }

  @Test("current item download status reads the persisted state synchronously")
  func currentItemDownloadStatusReadsCompletedDownload() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)
    let download = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: download.id!, to: .downloading)
    _ = try store.complete(downloadId: download.id!, finalSizeBytes: 1000)

    #expect(reading.currentItemDownloadStatus(itemId: "item-1") == .completed)
  }

  @Test("current item download status reads the persisted state asynchronously")
  func currentItemDownloadStatusAsyncReadsCompletedDownload() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")

    try await database.writeAsync { db in
      var download = DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60, receivedBytes: 1000,
        state: .completed)
      try download.insert(db)
    }

    let reading = DefaultDownloadReading(database: database)

    #expect(await reading.currentItemDownloadStatusAsync(itemId: "item-1") == .completed)
  }

  @Test("current item download status asynchronously defaults when the item is missing")
  func currentItemDownloadStatusAsyncDefaultsForMissingItem() async throws {
    let reading = DefaultDownloadReading(database: try AppDatabase.inMemory())

    #expect(await reading.currentItemDownloadStatusAsync(itemId: "missing") == .notDownloaded)
  }

  // MARK: - Bulk presence projection

  @Test("observeItemDownloadPresence emits one entry per item that has download rows")
  func observeItemDownloadPresenceEmitsEveryItemWithRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let first = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let second = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-2")
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-3")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)

    let observations = PersistenceObservationCollector(reading.observeItemDownloadPresence())

    // Nothing downloaded anywhere: an empty map, not one `.none` entry per library item.
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    let firstDownload = try store.enqueue(
      accountId: accountId, itemId: first, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.enqueue(
      accountId: accountId, itemId: second, serverFileIno: "ino-2", orderIndex: 0,
      destinationRelativePath: "item-2/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    #expect(await TestSupport.waitUntil { observations.contains { $0.count >= 2 } })
    let enqueued = try #require(observations.last { $0.count >= 2 })
    #expect(enqueued["item-1"] == .partial)
    #expect(enqueued["item-2"] == .partial)
    // An item with no download rows is absent, never `.none`. The map is the downloaded set.
    #expect(enqueued["item-3"] == nil)

    _ = try store.transition(downloadId: firstDownload.id!, to: .downloading)
    _ = try store.complete(downloadId: firstDownload.id!, finalSizeBytes: 1000)

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["item-1"] == .completed }
      })
    let completed = try #require(observations.last { $0["item-1"] == .completed })
    #expect(completed["item-2"] == .partial)
  }

  @Test("observeItemDownloadPresence stays silent while only download progress changes")
  func observeItemDownloadPresenceIgnoresProgressTicks() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)

    let observations = PersistenceObservationCollector(reading.observeItemDownloadPresence())
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["item-1"] == .partial }
      })
    let current = try #require(observations.last { $0["item-1"] == .partial })
    #expect(current["item-1"] == .partial)

    // Byte-progress writes must not re-emit: every row on a screen shares this one projection, so
    // a per-byte emission would re-render the whole list for one downloading item. `.partial`
    // carries no progress fraction, and the observation removes duplicates.
    for received in stride(from: Int64(100), through: 500, by: 100) {
      _ = try store.updateProgress(downloadId: created.id!, receivedBytes: received)
    }
    _ = try store.complete(downloadId: created.id!, finalSizeBytes: 1000)

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["item-1"] == .completed }
      })
    let next = try #require(observations.last { $0["item-1"] == .completed })
    #expect(next["item-1"] == .completed)
  }

  @Test("observeItemDownloadPresence reports a fully deleting item as deleting")
  func observeItemDownloadPresenceReportsDeleting() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let store = try DownloadStore(database: database)
    let reading = DefaultDownloadReading(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    let observations = PersistenceObservationCollector(reading.observeItemDownloadPresence())
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["item-1"] == .partial }
      })

    _ = try store.transition(downloadId: created.id!, to: .deleting)

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["item-1"] == .deleting }
      })
    let deleting = try #require(observations.last { $0["item-1"] == .deleting })
    #expect(deleting["item-1"] == .deleting)
  }

  @Test("ItemDownloadPresence.resolve mirrors the detailed rollup it summarises")
  func itemDownloadPresenceResolveMirrorsItemStatus() {
    #expect(ItemDownloadPresence.resolve(.notDownloaded) == ItemDownloadPresence.none)
    #expect(ItemDownloadPresence.resolve(.deleting) == .deleting)
    #expect(ItemDownloadPresence.resolve(.completed) == .completed)
    for status: ItemDownloadStatus in [
      .waitingForWiFi, .queued, .downloading(progressFraction: 0.5), .paused, .pausedAuth,
      .interrupted, .failed(category: .unknown),
    ] {
      #expect(ItemDownloadPresence.resolve(status) == .partial)
    }
  }

  @Test("a show whose only download rows are episode-scoped has no item-level presence")
  func itemPresenceIgnoresEpisodeScopedRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "podcast", serverItemId: "show-1")
    let bookId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let episodeId = try await PersistenceFixtures.insertEpisode(database, accountId: accountId, itemId: showId)
    let store = try DownloadStore(database: database)

    let episodeDownload = try store.enqueue(
      accountId: accountId, itemId: showId, podcastEpisodeId: episodeId, serverFileIno: "ino-ep",
      orderIndex: 0, destinationRelativePath: "show-1/ep-1.mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    _ = try store.transition(downloadId: episodeDownload.id!, to: .downloading)
    _ = try store.complete(downloadId: episodeDownload.id!, finalSizeBytes: 500)
    _ = try store.enqueue(
      accountId: accountId, itemId: bookId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    let presence = try database.read { db in try DownloadStore.itemPresence(db) }
    #expect(
      presence["show-1"] == nil,
      "one downloaded episode is not an item-level download of the whole show")
    #expect(presence["item-1"] == .partial, "item-level rows are unaffected")
  }

  @Test("episode presence is keyed by the (show, episode) identity and ignores item-level rows")
  func episodePresenceIsKeyedByEpisodeIdentity() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "podcast", serverItemId: "show-1")
    let bookId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let doneEpisodeId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-done")
    let goingEpisodeId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-going")
    let store = try DownloadStore(database: database)

    let done = try store.enqueue(
      accountId: accountId, itemId: showId, podcastEpisodeId: doneEpisodeId,
      serverFileIno: "ino-done", orderIndex: 0, destinationRelativePath: "show-1/done.mp3",
      expectedBytes: 500, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    _ = try store.transition(downloadId: done.id!, to: .downloading)
    _ = try store.complete(downloadId: done.id!, finalSizeBytes: 500)
    _ = try store.enqueue(
      accountId: accountId, itemId: showId, podcastEpisodeId: goingEpisodeId,
      serverFileIno: "ino-going", orderIndex: 0, destinationRelativePath: "show-1/going.mp3",
      expectedBytes: 500, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    _ = try store.enqueue(
      accountId: accountId, itemId: bookId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    let presence = try database.read { db in try DownloadStore.episodePresence(db) }
    #expect(presence[EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-done")] == .completed)
    #expect(presence[EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-going")] == .partial)
    #expect(presence.count == 2, "an item-level row is not an episode's download")
  }

  @Test("an episode whose only rows are deleting reports deleting, and one with none is absent")
  func episodePresenceReportsDeletingAndAbsence() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "podcast", serverItemId: "show-1")
    let goingEpisodeId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-going")
    _ = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-none")
    let store = try DownloadStore(database: database)

    let going = try store.enqueue(
      accountId: accountId, itemId: showId, podcastEpisodeId: goingEpisodeId,
      serverFileIno: "ino-going", orderIndex: 0, destinationRelativePath: "show-1/going.mp3",
      expectedBytes: 500, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    _ = try store.transition(downloadId: going.id!, to: .deleting)

    let presence = try database.read { db in try DownloadStore.episodePresence(db) }
    #expect(presence[EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-going")] == .deleting)
    #expect(presence[EpisodeDownloadKey(itemID: "show-1", episodeID: "ep-none")] == nil)
  }

  // MARK: - Tombstoned-episode downloads

  @Test("downloads whose episode has been soft-deleted are reported, and only those")
  func tombstonedEpisodeDownloadsReportsOnlyRowsBehindATombstone() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let showId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "podcast", serverItemId: "show-1")
    let bookId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-1")
    let liveEpisodeId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-live")
    let goneEpisodeId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: showId, serverEpisodeId: "ep-gone")
    let store = try DownloadStore(database: database)

    _ = try store.enqueue(
      accountId: accountId, itemId: showId, podcastEpisodeId: liveEpisodeId,
      serverFileIno: "ino-live", orderIndex: 0, destinationRelativePath: "show-1/ep-live.mp3",
      expectedBytes: 500, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    let strandedId = try #require(
      try store.enqueue(
        accountId: accountId, itemId: showId, podcastEpisodeId: goneEpisodeId,
        serverFileIno: "ino-gone", orderIndex: 0, destinationRelativePath: "show-1/ep-gone.mp3",
        expectedBytes: 700, expectedMimeType: "audio/mpeg", fileDurationSeconds: 30
      ).id)
    _ = try store.enqueue(
      accountId: accountId, itemId: bookId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    #expect(try store.tombstonedEpisodeDownloads().isEmpty, "nothing is tombstoned yet")

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [goneEpisodeId])
    }

    let stranded = try store.tombstonedEpisodeDownloads()
    #expect(stranded.compactMap(\.id) == [strandedId])
  }
}
