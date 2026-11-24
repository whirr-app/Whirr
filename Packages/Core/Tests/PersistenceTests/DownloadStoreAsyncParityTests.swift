import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

extension DownloadStoreTests {
  // MARK: - Async parity

  @Test func enqueueAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let sync = try twin.syncStore.enqueue(
      accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-async",
      orderIndex: 2, destinationRelativePath: "item-1/file-2.m4b", expectedBytes: 1234,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 61, origin: .automatic)
    let async = try await twin.asyncStore.enqueueAsync(
      accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-async",
      orderIndex: 2, destinationRelativePath: "item-1/file-2.m4b", expectedBytes: 1234,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 61, origin: .automatic)

    #expect(async == sync)
    #expect(async.id != nil)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(async.id)) == async)
  }

  @Test func fetchAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-fetch")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-fetch")

    let sync = try twin.syncStore.fetch(downloadId: try #require(syncRow.id))
    let async = try await twin.asyncStore.fetchAsync(downloadId: try #require(syncRow.id))
    #expect(async == sync)
  }

  @Test func fetchDownloadsByItemAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    for orderIndex in [2, 0] {
      _ = try await seedDownload(
        twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
        serverFileIno: "ino-\(orderIndex)", orderIndex: orderIndex)
      _ = try await seedDownload(
        twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
        serverFileIno: "ino-\(orderIndex)", orderIndex: orderIndex)
    }

    let sync = try twin.syncStore.fetchDownloads(itemId: twin.itemId)
    let async = try await twin.asyncStore.fetchDownloadsAsync(itemId: twin.itemId)
    #expect(async == sync)
    #expect(async.map(\.orderIndex) == [0, 2])
  }

  @Test func fetchDownloadsByEpisodeAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin(kind: "podcast")
    let syncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-async")
    let asyncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-async")
    #expect(asyncEpisodeID == syncEpisodeID)

    _ = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: syncEpisodeID, serverFileIno: "ino-episode")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: asyncEpisodeID, serverFileIno: "ino-episode")

    let sync = try twin.syncStore.fetchDownloads(
      itemId: twin.itemId, podcastEpisodeId: syncEpisodeID)
    let async = try await twin.asyncStore.fetchDownloadsAsync(
      itemId: twin.itemId, podcastEpisodeId: asyncEpisodeID)
    #expect(async == sync)
    #expect(async.map(\.serverFileIno) == ["ino-episode"])
  }

  @Test func fetchAllAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    for fileIno in ["ino-all-1", "ino-all-2"] {
      _ = try await seedDownload(
        twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: fileIno)
      _ = try await seedDownload(
        twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: fileIno)
    }

    let sync = try twin.syncStore.fetchAll()
    let async = try await twin.asyncStore.fetchAllAsync()
    #expect(async == sync)
    #expect(async.count == 2)
  }

  @Test func tombstonedEpisodeDownloadsAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin(kind: "podcast")
    let syncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-gone")
    let asyncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-gone")
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: syncEpisodeID, serverFileIno: "ino-gone")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: asyncEpisodeID, serverFileIno: "ino-gone")

    try await twin.syncDatabase.writeAsync { db in
      try db.execute(sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [syncEpisodeID])
    }
    try await twin.asyncDatabase.writeAsync { db in
      try db.execute(sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?", arguments: [asyncEpisodeID])
    }

    let sync = try twin.syncStore.tombstonedEpisodeDownloads()
    let async = try await twin.asyncStore.tombstonedEpisodeDownloadsAsync()
    #expect(async == sync)
    #expect(async.map(\.id) == [syncRow.id])
  }

  @Test func transitionAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      serverFileIno: "ino-transition", state: .downloading)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      serverFileIno: "ino-transition", state: .downloading)
    let id = try #require(syncRow.id)

    let sync = try twin.syncStore.transition(
      downloadId: id, to: .pending, receivedBytes: 42, holdReason: .waitingForWiFi)
    let async = try await twin.asyncStore.transitionAsync(
      downloadId: id, to: .pending, receivedBytes: 42, holdReason: .waitingForWiFi)

    #expect(async == sync)
    #expect(async.state == .pending)
    #expect(async.receivedBytes == 42)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: id) == async)
  }

  @Test func promoteToManualAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-promote",
      origin: .automatic)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-promote",
      origin: .automatic)
    let id = try #require(syncRow.id)

    let sync = try twin.syncStore.promoteToManual(downloadId: id)
    let async = try await twin.asyncStore.promoteToManualAsync(downloadId: id)

    #expect(async == sync)
    #expect(async.origin == .manual)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: id)?.origin == .manual)
  }

  @Test func updateProgressAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-progress",
      state: .downloading, receivedBytes: 10)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-progress",
      state: .downloading, receivedBytes: 10)
    let id = try #require(syncRow.id)

    let sync = try twin.syncStore.updateProgress(downloadId: id, receivedBytes: 88)
    let async = try await twin.asyncStore.updateProgressAsync(downloadId: id, receivedBytes: 88)

    #expect(async == sync)
    #expect(async.receivedBytes == 88)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: id)?.receivedBytes == 88)
  }

  @Test func markDeletingByItemAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncPending = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-pending")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-pending")
    let syncDeleting = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-deleting",
      state: .deleting)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-deleting",
      state: .deleting)

    let sync = try twin.syncStore.markDeleting(itemId: twin.itemId)
    let async = try await twin.asyncStore.markDeletingAsync(itemId: twin.itemId)

    #expect(async == sync)
    #expect(async.map(\.id) == [syncPending.id])
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncPending.id))?.state == .deleting)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncDeleting.id))?.state == .deleting)
  }

  @Test func markDeletingByMediaKindAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncAudio = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-audio",
      mediaKind: .audio)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-audio",
      mediaKind: .audio)
    let syncEbook = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-ebook",
      mediaKind: .ebook)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-ebook",
      mediaKind: .ebook)

    let sync = try twin.syncStore.markDeleting(itemId: twin.itemId, mediaKind: .ebook)
    let async = try await twin.asyncStore.markDeletingAsync(itemId: twin.itemId, mediaKind: .ebook)

    #expect(async == sync)
    #expect(async.map(\.id) == [syncEbook.id])
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncAudio.id))?.state == .pending)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncEbook.id))?.state == .deleting)
  }

  @Test func markDeletingByEpisodeAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin(kind: "podcast")
    let syncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-target")
    let asyncEpisodeID = try await PersistenceFixtures.insertEpisode(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-target")
    let syncSiblingID = try await PersistenceFixtures.insertEpisode(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-sibling")
    let asyncSiblingID = try await PersistenceFixtures.insertEpisode(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverEpisodeId: "ep-sibling")
    #expect(asyncEpisodeID == syncEpisodeID)
    #expect(asyncSiblingID == syncSiblingID)

    let syncTarget = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: syncEpisodeID, serverFileIno: "ino-target")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: asyncEpisodeID, serverFileIno: "ino-target")
    let syncSibling = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: syncSiblingID, serverFileIno: "ino-sibling")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId,
      podcastEpisodeId: asyncSiblingID, serverFileIno: "ino-sibling")

    let sync = try twin.syncStore.markDeleting(itemId: twin.itemId, podcastEpisodeId: syncEpisodeID)
    let async = try await twin.asyncStore.markDeletingAsync(
      itemId: twin.itemId, podcastEpisodeId: asyncEpisodeID)

    #expect(async == sync)
    #expect(async.map(\.id) == [syncTarget.id])
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncTarget.id))?.state == .deleting)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: try #require(syncSibling.id))?.state == .pending)
  }

  @Test func markAllDeletingAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncFirst = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-all-first")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-all-first")
    let syncSecond = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-all-second")
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-all-second")

    let sync = try twin.syncStore.markAllDeleting()
    let async = try await twin.asyncStore.markAllDeletingAsync()

    #expect(async == sync)
    #expect(async.map(\.id) == [syncFirst.id, syncSecond.id])
    #expect(try await twin.asyncStore.fetchAllAsync().allSatisfy { $0.state == .deleting })
  }

  @Test func finalizeDeletionAsyncMatchesSyncTwin() async throws {
    let twin = try await makeTwin()
    let syncRow = try await seedDownload(
      twin.syncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-finalize",
      state: .deleting)
    _ = try await seedDownload(
      twin.asyncDatabase, accountId: twin.accountId, itemId: twin.itemId, serverFileIno: "ino-finalize",
      state: .deleting)
    let id = try #require(syncRow.id)

    try twin.syncStore.finalizeDeletion(downloadId: id)
    try await twin.asyncStore.finalizeDeletionAsync(downloadId: id)

    #expect(try twin.syncStore.fetch(downloadId: id) == nil)
    #expect(try await twin.asyncStore.fetchAsync(downloadId: id) == nil)
    #expect(try await twin.asyncStore.fetchAllAsync().isEmpty)
  }
}
