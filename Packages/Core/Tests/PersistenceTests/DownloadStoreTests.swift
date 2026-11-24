import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The download schema and `DownloadStore`.
@Suite struct DownloadStoreTests {

  // MARK: - Uniqueness

  @Test func duplicateAudiobookDownloadForTheSameFileThrows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    _ = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    // Same account/item/null-episode/file identity again. A plain nullable unique column would
    // not catch this (SQLite treats each NULL as distinct), so this exercises the schema's
    // partial-index split (SchemaV1.swift).
    #expect(throws: DownloadStoreError.self) {
      try store.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0-again.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    }

    let count = try database.read { db in try DownloadRecord.fetchCount(db) }
    #expect(count == 1)
  }

  @Test func duplicatePodcastEpisodeDownloadForTheSameFileThrows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let episodeId = try await PersistenceFixtures.insertEpisode(database, accountId: accountId, itemId: itemId)
    let store = try DownloadStore(database: database)

    _ = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: "ino-1",
      orderIndex: 0, destinationRelativePath: "item-1/ep-1.mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)

    #expect(throws: DownloadStoreError.self) {
      try store.enqueue(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, serverFileIno: "ino-1",
        orderIndex: 0, destinationRelativePath: "item-1/ep-1-again.mp3", expectedBytes: 500,
        expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    }
  }

  @Test func differentEpisodesOfTheSameItemMayShareAFileInoWithoutColliding() async throws {
    // Two different episodes of the same podcast item, coincidentally sharing a file ino value,
    // must not collide with each other (identity includes the episode, not just item + ino).
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "podcast")
    let episodeOneId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: itemId, serverEpisodeId: "ep-1")
    let episodeTwoId = try await PersistenceFixtures.insertEpisode(
      database, accountId: accountId, itemId: itemId, serverEpisodeId: "ep-2")
    let store = try DownloadStore(database: database)

    _ = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeOneId, serverFileIno: "ino-1",
      orderIndex: 0, destinationRelativePath: "item-1/ep-1.mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)
    _ = try store.enqueue(
      accountId: accountId, itemId: itemId, podcastEpisodeId: episodeTwoId, serverFileIno: "ino-1",
      orderIndex: 0, destinationRelativePath: "item-1/ep-2.mp3", expectedBytes: 500,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 30)

    let count = try database.read { db in try DownloadRecord.fetchCount(db) }
    #expect(count == 2)
  }

  // MARK: - Round trip

  @Test func downloadRowRoundTripsEveryColumn() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-42", orderIndex: 3,
      destinationRelativePath: "item-1/file-3.m4b", expectedBytes: 123_456,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 987.5)
    #expect(created.orderIndex == 3)
    #expect(created.expectedBytes == 123_456)
    #expect(created.expectedMimeType == "audio/mp4")
    #expect(created.fileDurationSeconds == 987.5)
    #expect(created.receivedBytes == 0)
    #expect(created.state == .pending)
    #expect(created.holdReason == nil)
    #expect(created.errorCategory == nil)

    let downloading = try store.transition(downloadId: created.id!, to: .downloading)
    #expect(downloading.state == .downloading)

    let progressed = try store.transition(
      downloadId: created.id!, to: .paused, receivedBytes: 60_000)
    #expect(progressed.receivedBytes == 60_000)
    #expect(progressed.state == .paused)

    let refetched = try store.fetch(downloadId: created.id!)
    #expect(refetched?.receivedBytes == 60_000)
  }

  // MARK: - Wi-Fi hold (durable, not an error)

  @Test func wifiHoldIsPendingWithADistinctHoldReasonNotAnError() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)

    let held = try store.transition(
      downloadId: created.id!, to: .pending, holdReason: .waitingForWiFi)
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)
    #expect(held.errorCategory == nil, "a Wi-Fi hold is never an error")

    // Clearing the hold (Wi-Fi returns) and starting a fresh attempt drops the hold reason.
    let resumed = try store.transition(downloadId: created.id!, to: .downloading)
    #expect(resumed.holdReason == nil)
  }

  // MARK: - pausedAuth: durable, only automatic exit is re-auth

  @Test func pausedAuthOnlyLeavesToPendingOnReauth() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)
    let paused = try store.transition(downloadId: created.id!, to: .pausedAuth)
    #expect(paused.state == .pausedAuth)

    // There is no direct pausedAuth -> downloading edge: resuming always passes back through
    // pending.
    #expect(throws: DownloadStoreError.self) {
      try store.transition(downloadId: created.id!, to: .downloading)
    }

    let reauthenticated = try store.transition(downloadId: created.id!, to: .pending)
    #expect(reauthenticated.state == .pending)
  }

  // MARK: - Completion guard

  @Test func completedRequiresAPositiveVerifiedFinalSize() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)

    #expect(throws: DownloadStoreError.self) {
      try store.complete(downloadId: created.id!, finalSizeBytes: 0)
    }
    let stillDownloading = try store.fetch(downloadId: created.id!)
    #expect(stillDownloading?.state == .downloading, "a rejected completion must not mutate state")

    let completed = try store.complete(downloadId: created.id!, finalSizeBytes: 1000)
    #expect(completed.state == .completed)
    #expect(completed.receivedBytes == 1000)
    #expect(completed.isPlayable)
  }

  @Test func completedIsUnreachableThroughTheGenericTransitionEvenFromDownloading() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)

    #expect(throws: DownloadStoreError.self) {
      try store.transition(downloadId: created.id!, to: .completed)
    }
  }

  @Test func completeOnlyLegalFromDownloading() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    // Still `pending`, never started downloading.
    #expect(throws: DownloadStoreError.self) {
      try store.complete(downloadId: created.id!, finalSizeBytes: 1000)
    }
  }

  // MARK: - deleting is never playable or schedulable

  @Test func deletingIsNeverPlayableOrSchedulable() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)
    let completed = try store.complete(downloadId: created.id!, finalSizeBytes: 1000)
    #expect(completed.isPlayable)

    let deleting = try store.transition(downloadId: created.id!, to: .deleting)
    #expect(deleting.isPlayable == false)
    #expect(deleting.isSchedulable == false)

    // Terminal: nothing may transition a `deleting` row onward.
    for target: DownloadState in [.pending, .downloading, .paused, .pausedAuth, .failed] {
      #expect(throws: DownloadStoreError.self) {
        try store.transition(downloadId: created.id!, to: target)
      }
    }
  }

  // MARK: - Launch recovery

  @Test func launchRecoveryMovesDownloadingRowsToInterrupted() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")

    let downloadId = try await database.writeAsync { db in
      try DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60, state: .downloading
      ).inserted(db).id!
    }

    _ = try DownloadStore(database: database)

    let recovered = try database.read { db in try DownloadRecord.fetchOne(db, key: downloadId) }
    #expect(recovered?.state == .interrupted)
  }

  @Test func launchRecoveryLeavesPausedPausedAuthAndDeletingRowsUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")

    func insert(state: DownloadState, ino: String) async throws -> Int64 {
      try await database.writeAsync { db in
        try DownloadRecord(
          accountId: accountId, itemId: itemId, serverFileIno: ino, orderIndex: 0,
          destinationRelativePath: "item-1/\(ino).m4b", expectedBytes: 1000,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 60, state: state
        ).inserted(db).id!
      }
    }
    let pausedId = try await insert(state: .paused, ino: "ino-paused")
    let pausedAuthId = try await insert(state: .pausedAuth, ino: "ino-pausedAuth")
    let deletingId = try await insert(state: .deleting, ino: "ino-deleting")
    let pendingId = try await insert(state: .pending, ino: "ino-pending")

    _ = try DownloadStore(database: database)

    let states = try database.read { db -> [Int64: DownloadState] in
      let rows = try DownloadRecord.fetchAll(db)
      return Dictionary(uniqueKeysWithValues: rows.map { ($0.id!, $0.state) })
    }
    #expect(states[pausedId] == .paused)
    #expect(states[pausedAuthId] == .pausedAuth)
    #expect(states[deletingId] == .deleting)
    #expect(states[pendingId] == .pending)
  }

  // MARK: - Per-item aggregate

  @Test func aggregateIsNoneWhenTheItemHasNoDownloadRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)
    _ = accountId

    let aggregate = try store.aggregate(itemId: itemId)
    #expect(aggregate.state == .none)
    #expect(aggregate.progressFraction == 0)
  }

  @Test func aggregateIsPartialWithAByteWeightedFractionAcrossFiles() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: first.id!, to: .downloading)
    _ = try store.transition(downloadId: first.id!, to: .paused, receivedBytes: 500)
    _ = second

    let aggregate = try store.aggregate(itemId: itemId)
    #expect(aggregate.state == .partial)
    #expect(aggregate.progressFraction == 0.25, "500 of 2000 total expected bytes across both files")
  }

  @Test func aggregateIsCompleteOnlyWhenEveryFileRowIsCompleted() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: first.id!, to: .downloading)
    _ = try store.complete(downloadId: first.id!, finalSizeBytes: 1000)

    let stillPartial = try store.aggregate(itemId: itemId)
    #expect(stillPartial.state == .partial)

    _ = try store.transition(downloadId: second.id!, to: .downloading)
    _ = try store.complete(downloadId: second.id!, finalSizeBytes: 1000)

    let complete = try store.aggregate(itemId: itemId)
    #expect(complete.state == .complete)
    #expect(complete.progressFraction == 1.0)
  }

  @Test func aggregateExcludesDeletingRowsFromTheRollup() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let only = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: only.id!, to: .downloading)
    _ = try store.transition(downloadId: only.id!, to: .deleting)

    let aggregate = try store.aggregate(itemId: itemId)
    #expect(aggregate.state == .none, "a lone deleting row must not read as partial/complete progress")
  }

  @Test
  func ebookRowsContributeToTheItemRollupButNotAnExplicitAudioProjection() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book",
      serverItemId: "ebook-item")
    let store = try DownloadStore(database: database)

    let ebook = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ebook-ino", orderIndex: 0,
      destinationRelativePath: "ebook-item.epub", expectedBytes: 5,
      expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
    #expect(try store.aggregate(itemId: itemId, mediaKind: .audio).state == .none)
    #expect(try store.itemStatus(itemId: itemId, mediaKind: .audio) == .notDownloaded)
    #expect(
      try database.read { db in try DownloadStore.itemPresence(db, mediaKind: .audio) }.isEmpty)
    #expect(try store.aggregate(itemId: itemId).state == .partial)
    #expect(try store.itemStatus(itemId: itemId) == .queued)
    #expect(
      try database.read { db in try DownloadStore.itemPresence(db) }["ebook-item"] == .partial)

    _ = try store.transition(downloadId: try #require(ebook.id), to: .downloading)
    _ = try store.complete(downloadId: try #require(ebook.id), finalSizeBytes: 5)

    #expect(try store.aggregate(itemId: itemId, mediaKind: .audio).state == .none)
    #expect(try store.itemStatus(itemId: itemId, mediaKind: .audio) == .notDownloaded)
    #expect(try store.aggregate(itemId: itemId).state == .complete)
    #expect(try store.itemStatus(itemId: itemId) == .completed)
    #expect(
      try database.read { db in try DownloadStore.itemPresence(db) }["ebook-item"] == .completed)

    let audio = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "audio-ino", orderIndex: 0,
      destinationRelativePath: "audio-item.mp3", expectedBytes: 5,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 1)
    _ = try store.transition(downloadId: try #require(audio.id), to: .downloading)
    _ = try store.complete(downloadId: try #require(audio.id), finalSizeBytes: 5)

    #expect(try store.aggregate(itemId: itemId).state == .complete)
    #expect(try store.itemStatus(itemId: itemId) == .completed)
    #expect(
      try database.read { db in try DownloadStore.itemPresence(db) }["ebook-item"] == .completed)
  }

  @Test("a mixed item exposes each requested medium and an all-live-row item status")
  func mixedItemFormatStatusMatrix() async throws {
    let cases: [(name: String, audio: Bool, ebook: Bool, expectedItemStatus: ItemDownloadStatus)] = [
      ("none", false, false, .notDownloaded),
      ("audio-only", true, false, .completed),
      ("ebook-only", false, true, .completed),
      ("one-of-both", true, true, .queued),
      ("both", true, true, .completed),
    ]

    for (index, testCase) in cases.enumerated() {
      let database = try AppDatabase.inMemory()
      let (accountId, libraryId) = try await insertAccountAndLibrary(database)
      let itemId = try await insertItem(
        database, accountId: accountId, libraryId: libraryId, kind: "book",
        serverItemId: "mixed-\(index)")
      try await database.writeAsync { db in
        try ItemRecord
          .filter(key: itemId)
          .updateAll(db, Column("numAudioFiles").set(to: 1), Column("ebookFormat").set(to: "epub"))
      }
      let store = try DownloadStore(database: database)

      if testCase.audio {
        let audio = try store.enqueue(
          accountId: accountId, itemId: itemId, serverFileIno: "audio-\(index)", orderIndex: 0,
          destinationRelativePath: "mixed-\(index).m4b", expectedBytes: 10,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
        _ = try store.transition(downloadId: try #require(audio.id), to: .downloading)
        _ = try store.complete(downloadId: try #require(audio.id), finalSizeBytes: 10)
      }
      if testCase.ebook {
        let ebook = try store.enqueue(
          accountId: accountId, itemId: itemId, serverFileIno: "ebook-\(index)", orderIndex: 0,
          destinationRelativePath: "mixed-\(index).epub", expectedBytes: 10,
          expectedMimeType: "application/epub+zip", fileDurationSeconds: 0, mediaKind: .ebook)
        if testCase.name == "one-of-both" {
          // Leave this requested row pending: one completed medium must not make the item
          // completed, while the format projection still reports both requested kinds.
          _ = ebook
        } else {
          _ = try store.transition(downloadId: try #require(ebook.id), to: .downloading)
          _ = try store.complete(downloadId: try #require(ebook.id), finalSizeBytes: 10)
        }
      }

      let formatStatus = try store.itemFormatStatus(itemId: itemId)
      #expect(
        formatStatus.audio == (testCase.audio ? .completed : .notDownloaded),
        "audio format for \(testCase.name)")
      #expect(
        formatStatus.ebook
          == (testCase.ebook
            ? (testCase.name == "one-of-both" ? .queued : .completed)
            : .notDownloaded),
        "ebook format for \(testCase.name)")
      #expect(try store.itemStatus(itemId: itemId) == testCase.expectedItemStatus)
      #expect(
        try store.aggregate(itemId: itemId).state
          == (testCase.expectedItemStatus == .completed
            ? .complete : testCase.expectedItemStatus == .notDownloaded ? .none : .partial),
        "aggregate for \(testCase.name)")
    }
  }

  // MARK: - Item-level detailed status

  @Test func itemStatusIsNotDownloadedWhenTheItemHasNoDownloadRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    #expect(try store.itemStatus(itemId: itemId) == .notDownloaded)
  }

  @Test func itemStatusIsQueuedForAPlainPendingRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    _ = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    #expect(try store.itemStatus(itemId: itemId) == .queued)
  }

  @Test func itemStatusIsWaitingForWiFiWhenAPendingRowCarriesThatHoldReason() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let row = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: row.id!, to: .downloading)
    _ = try store.transition(downloadId: row.id!, to: .pending, holdReason: .waitingForWiFi)

    #expect(try store.itemStatus(itemId: itemId) == .waitingForWiFi)
  }

  @Test func itemStatusIsDownloadingWithByteWeightedProgress() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: first.id!, to: .downloading)
    _ = try store.updateProgress(downloadId: first.id!, receivedBytes: 500)
    _ = second

    guard case .downloading(let fraction) = try store.itemStatus(itemId: itemId) else {
      Issue.record("expected .downloading")
      return
    }
    #expect(fraction == 0.25, "500 of 2000 total expected bytes across both files")
  }

  @Test func itemStatusIsPausedWhenAnyRowIsPaused() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let row = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: row.id!, to: .downloading)
    _ = try store.transition(downloadId: row.id!, to: .paused)

    #expect(try store.itemStatus(itemId: itemId) == .paused)
  }

  @Test func itemStatusIsPausedAuthAndTakesPriorityOverAFailedSiblingRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: first.id!, to: .downloading)
    _ = try store.transition(downloadId: first.id!, to: .pausedAuth)
    _ = try store.transition(downloadId: second.id!, to: .downloading)
    _ = try store.transition(downloadId: second.id!, to: .failed, errorCategory: .transport)

    #expect(try store.itemStatus(itemId: itemId) == .pausedAuth)
  }

  @Test func itemStatusIsFailedWithItsCategoryIncludingLowDiskAndValidation() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    func failedStatus(category: DownloadErrorCategory) async throws -> ItemDownloadStatus {
      let itemId = try await insertItem(
        database, accountId: accountId, libraryId: libraryId, kind: "book",
        serverItemId: "item-\(category.rawValue)")
      let store = try DownloadStore(database: database)
      let row = try store.enqueue(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-\(category.rawValue)", orderIndex: 0,
        destinationRelativePath: "item-\(category.rawValue)/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
      _ = try store.transition(downloadId: row.id!, to: .downloading)
      _ = try store.transition(downloadId: row.id!, to: .failed, errorCategory: category)
      return try store.itemStatus(itemId: itemId)
    }

    #expect(try await failedStatus(category: .lowDisk) == .failed(category: .lowDisk))
    #expect(try await failedStatus(category: .validation) == .failed(category: .validation))
    #expect(try await failedStatus(category: .transport) == .failed(category: .transport))
  }

  @Test func itemStatusIsInterruptedWhenARowWasInferredInterruptedOnLaunch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    var store = try DownloadStore(database: database)

    let row = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: row.id!, to: .downloading)

    // A fresh `DownloadStore` over the same database performs the `.downloading` -> `.interrupted`
    // launch reconciliation.
    store = try DownloadStore(database: database)
    #expect(try store.itemStatus(itemId: itemId) == .interrupted)
  }

  @Test func itemStatusIsDeletingOnlyWhenEveryRowIsDeleting() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let row = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: row.id!, to: .downloading)
    _ = try store.transition(downloadId: row.id!, to: .deleting)

    #expect(try store.itemStatus(itemId: itemId) == .deleting)
  }

  @Test func itemStatusIsCompletedOnlyWhenEveryRowIsCompleted() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: first.id!, to: .downloading)
    _ = try store.complete(downloadId: first.id!, finalSizeBytes: 1000)

    #expect(try store.itemStatus(itemId: itemId) != .completed, "one file still pending")

    _ = try store.transition(downloadId: second.id!, to: .downloading)
    _ = try store.complete(downloadId: second.id!, finalSizeBytes: 1000)

    #expect(try store.itemStatus(itemId: itemId) == .completed)
  }

  // MARK: - Transition matrix

  private static let allStates: [DownloadState] = [
    .pending, .downloading, .paused, .pausedAuth, .interrupted, .deleting, .completed, .failed,
  ]

  /// The full legal-transition matrix (see `DownloadStore.legalTransitions` for the rationale
  /// behind each edge). Every pair not listed here, including every pair targeting `completed`
  /// or `interrupted`, must throw.
  private static let legalTransitions: Set<[DownloadState]> = [
    [.pending, .downloading],
    [.pending, .deleting],
    [.downloading, .pending],
    [.downloading, .paused],
    [.downloading, .pausedAuth],
    [.downloading, .failed],
    [.downloading, .deleting],
    [.paused, .pending],
    [.paused, .deleting],
    [.pausedAuth, .pending],
    [.pausedAuth, .deleting],
    [.interrupted, .pending],
    [.interrupted, .failed],
    [.interrupted, .deleting],
    [.failed, .pending],
    [.failed, .deleting],
    [.completed, .deleting],
    // `DownloadIntegritySweep` demotes a completed row whose file has gone missing back to
    // failed/redownloadable (see `DownloadStore.legalTransitions`'s doc comment).
    [.completed, .failed],
  ]

  @Test(arguments: allStates, allStates)
  func transitionMatrix(from: DownloadState, to: DownloadState) async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let downloadId = try await database.writeAsync { db in
      try DownloadRecord(
        accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
        destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 60, state: from
      ).inserted(db).id!
    }

    let isLegal = Self.legalTransitions.contains([from, to])

    if isLegal {
      let updated = try store.transition(downloadId: downloadId, to: to)
      #expect(updated.state == to)
    } else {
      #expect(throws: DownloadStoreError.self) {
        try store.transition(downloadId: downloadId, to: to)
      }
      let unchanged = try database.read { db in try DownloadRecord.fetchOne(db, key: downloadId) }
      #expect(unchanged?.state == from, "an illegal transition must not mutate the row")
    }
  }

  @Test func transitionOnAMissingDownloadThrowsDownloadNotFound() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await PersistenceFixtures.insertAccount(database)
    let store = try DownloadStore(database: database)

    #expect(throws: DownloadStoreError.self) {
      try store.transition(downloadId: 999_999, to: .downloading)
    }
  }

  // MARK: - Bulk mark-deleting (first step of the purge)

  @Test func markDeletingForItemTransitionsEveryNonDeletingRowAndReturnsPreTransitionSnapshots() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let otherItemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-2")
    let store = try DownloadStore(database: database)

    let downloading = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: downloading.id!, to: .downloading)
    let pending = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-2", orderIndex: 1,
      destinationRelativePath: "item-1/file-1.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let otherItemRow = try store.enqueue(
      accountId: accountId, itemId: otherItemId, serverFileIno: "ino-3", orderIndex: 0,
      destinationRelativePath: "item-2/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    let marked = try store.markDeleting(itemId: itemId)

    // Pre-transition snapshots: still report each row's state as it stood right before marking.
    #expect(Set(marked.map(\.id)) == Set([downloading.id, pending.id]))
    #expect(marked.first { $0.id == downloading.id }?.state == .downloading)
    #expect(marked.first { $0.id == pending.id }?.state == .pending)

    // The DB rows themselves are now durably `.deleting`.
    #expect(try store.fetch(downloadId: downloading.id!)?.state == .deleting)
    #expect(try store.fetch(downloadId: pending.id!)?.state == .deleting)
    // A different item's row is never touched.
    #expect(try store.fetch(downloadId: otherItemRow.id!)?.state == .pending)
  }

  @Test func markDeletingSkipsRowsAlreadyDeletingAndIsIdempotent() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let already = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: already.id!, to: .deleting)

    let marked = try store.markDeleting(itemId: itemId)

    #expect(marked.isEmpty, "an already-deleting row is neither re-reported nor re-marked")
    #expect(try store.fetch(downloadId: already.id!)?.state == .deleting)
  }

  @Test func markAllDeletingCoversEveryItemInOneTransaction() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let firstItemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let secondItemId = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, kind: "book", serverItemId: "item-2")
    let store = try DownloadStore(database: database)

    let first = try store.enqueue(
      accountId: accountId, itemId: firstItemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    let second = try store.enqueue(
      accountId: accountId, itemId: secondItemId, serverFileIno: "ino-2", orderIndex: 0,
      destinationRelativePath: "item-2/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)

    let marked = try store.markAllDeleting()

    #expect(Set(marked.map(\.id)) == Set([first.id, second.id]))
    #expect(try store.fetch(downloadId: first.id!)?.state == .deleting)
    #expect(try store.fetch(downloadId: second.id!)?.state == .deleting)
  }

  // MARK: - Error category

  @Test func errorCategoryRoundTripsAndClearsOnRecovery() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await insertItem(database, accountId: accountId, libraryId: libraryId, kind: "book")
    let store = try DownloadStore(database: database)

    let created = try store.enqueue(
      accountId: accountId, itemId: itemId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: "item-1/file-0.m4b", expectedBytes: 1000,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 60)
    _ = try store.transition(downloadId: created.id!, to: .downloading)

    let failed = try store.transition(
      downloadId: created.id!, to: .failed, errorCategory: .transport)
    #expect(failed.errorCategory == .transport)

    let retried = try store.transition(downloadId: failed.id!, to: .pending)
    #expect(retried.errorCategory == nil, "re-queueing clears the stale error category")
  }
}
