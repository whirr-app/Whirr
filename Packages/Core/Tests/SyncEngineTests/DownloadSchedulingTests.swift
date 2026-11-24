import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

private actor DownloadSchedulingCompletion {
  private var scheduleFinished = false
  private var resumeSucceeded: Bool?

  func markScheduleFinished() { scheduleFinished = true }

  func markResumeFinished(succeeded: Bool) { resumeSucceeded = succeeded }

  func allFinished() -> Bool { scheduleFinished && resumeSucceeded != nil }

  func didResumeSucceed() -> Bool { resumeSucceeded == true }
}

/// `DownloadCoordinator`'s scheduler: concurrency cap, FIFO, pause/resume/cancel/delete intents,
/// the cellular gate, and finish-event pass-through into validation. Planning
/// (`DownloadPlanningTests`), auth recovery (`DownloadAuthRecoveryTests`) and launch
/// reconciliation (`DownloadReconciliationTests`) are covered elsewhere.
@Suite struct DownloadSchedulingTests {

  @Test func rssTransferStampsTheCurrentFeedCredentialAtMintTime() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(
      bytes: 50, enclosureURL: URL(string: "https://feeds.example.test/41/episode.mp3")!)
    let details = try #require(try harness.rssDownloadStore.transferDetails(downloadId: row.id!))
    let feedID = try #require(details.feed.id)
    let credential = try FeedCredential.basic(username: "media-user", password: "media-pass")
    try harness.feedCredentialStore.save(credential, forFeedID: feedID)

    await harness.coordinator.schedule()

    let request = try #require(harness.backgroundTransferring.enqueuedRequests.first)
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == credential.authorization)
    #expect(request.redirectPolicy == .feed)
    #expect(request.request.httpShouldHandleCookies == false)
    let rendered = String(reflecting: request)
    #expect(rendered.contains("media-user") == false)
    #expect(rendered.contains("media-pass") == false)
    #expect(rendered.contains(credential.authorization) == false)
  }

  /// A feed names its own enclosures, so a hostile or compromised feed can point one at any host
  /// it likes. The credential belongs to the feed's origin alone: the enclosure still downloads,
  /// but unauthenticated. Redirect stripping cannot cover this: the first request is already out.
  /// Matches the exact-origin rule the artwork and playback paths apply.
  @Test func rssTransferWithholdsTheFeedCredentialFromACrossOriginEnclosure() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let row = try await harness.seedRSSDownload(bytes: 50)
    let details = try #require(try harness.rssDownloadStore.transferDetails(downloadId: row.id!))
    let feedID = try #require(details.feed.id)
    try harness.feedCredentialStore.save(
      try FeedCredential.basic(username: "media-user", password: "media-pass"), forFeedID: feedID)

    await harness.coordinator.schedule()

    let request = try #require(harness.backgroundTransferring.enqueuedRequests.first)
    #expect(request.request.url?.host == "media.example.test")
    #expect(request.request.value(forHTTPHeaderField: "Authorization") == nil)
  }

  @Test func malformedRSSDestinationNeverClaimsTheRowOrEnqueuesATransfer() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    try await harness.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET relativePath = ? WHERE id = ?",
        arguments: ["../escape.mp3", downloadID])
    }

    await harness.coordinator.schedule()

    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .pending)
    #expect(harness.backgroundTransferring.enqueuedRequests.isEmpty)
  }

  @Test func absAndRSSRowsShareOneGlobalTwoTransferCap() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    try await harness.database.writeAsync { db in
      for (index, ino) in [100, 200].enumerated() {
        var row = DownloadRecord(
          accountId: harness.accountId, itemId: harness.itemRowId,
          serverFileIno: String(ino), orderIndex: index,
          destinationRelativePath: "mixed-\(index).m4b", expectedBytes: 10,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
        try row.insert(db)
      }
    }
    _ = try await harness.seedRSSDownload(feedID: 101, episodeKey: "rss-a")
    _ = try await harness.seedRSSDownload(feedID: 102, episodeKey: "rss-b")

    await harness.coordinator.schedule()

    let activeABS = try harness.downloadStore.fetchAll().filter { $0.state == .downloading }
    let activeRSS = try harness.rssDownloadStore.fetchAll().filter { $0.state == .downloading }
    let enqueued = harness.backgroundTransferring.calls.compactMap { call -> TransferIdentity? in
      guard case .enqueue(let identity, _, _, _) = call else { return nil }
      return identity
    }
    let activeIdentities = Set(
      activeABS.compactMap(\.id).map { TransferIdentity.abs(rowID: $0) }
        + activeRSS.compactMap(\.id).map { TransferIdentity.rss(rowID: $0) })
    #expect(activeABS.count + activeRSS.count == 2)
    #expect(enqueued.count == 2)
    #expect(Set(enqueued) == activeIdentities)
  }

  @Test func rssOnlyRowsNeverExceedTheGlobalTwoTransferCap() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    for index in 0..<4 {
      _ = try await harness.seedRSSDownload(
        feedID: Int64(200 + index), episodeKey: "rss-only-\(index)")
    }

    await harness.coordinator.schedule()

    let activeRows = try harness.rssDownloadStore.fetchAll().filter { $0.state == .downloading }
    let activeIdentities = Set(
      activeRows.compactMap(\.id).map { TransferIdentity.rss(rowID: $0) })
    let enqueuedIdentities = Set(
      harness.backgroundTransferring.calls.compactMap { call -> TransferIdentity? in
        guard case .enqueue(let identity, _, _, _) = call else { return nil }
        return identity
      })
    #expect(activeRows.count == 2)
    #expect(enqueuedIdentities.count == 2)
    #expect(enqueuedIdentities == activeIdentities)
  }

  @Test func aPendingABSDownloadQueuedBeforeItemQuarantineIsNotScheduled() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "quarantined.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try row.insert(db)
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [harness.itemRowId])
    }

    await harness.coordinator.schedule()

    #expect(harness.backgroundTransferring.enqueuedRequests.isEmpty)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).first?.state == .pending)
  }

  @Test func aPendingABSDownloadForALiveItemStillSchedules() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "live.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try row.insert(db)
    }

    await harness.coordinator.schedule()

    #expect(harness.backgroundTransferring.enqueuedRequests.count == 1)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).first?.state == .downloading)
  }

  @Test func quarantiningANetworkHeldABSDownloadDoesNotResumeItsSuspendedTask() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let downloadId = try await harness.database.writeAsync { db -> Int64 in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "held.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1, state: .downloading)
      try row.insert(db)
      return row.id!
    }

    harness.networkConditions.isConstrainedOrCellular = true
    await harness.coordinator.schedule()
    try await harness.database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [harness.itemRowId])
    }
    harness.networkConditions.isConstrainedOrCellular = false

    await harness.coordinator.schedule()

    #expect(
      harness.backgroundTransferring.calls.contains(.resume(identity: .abs(rowID: downloadId))) == false,
      "quarantine must not release a suspended task back to the server")
    #expect(harness.backgroundTransferring.enqueuedRequests.isEmpty)
    #expect(try harness.fetchDownloads(itemId: harness.itemRowId).first?.state == .pending)
  }

  /// The damage re-entrant scheduling does. `performSchedule` computes `availableSlots` once and
  /// then suspends inside `startTransfer`; a second pass entering meanwhile recomputes slots from
  /// rows the first has not finished claiming, and both start transfers against a stale budget.
  /// The cap is two.
  ///
  /// Four pending rows and a gate on the first `enqueue` make the interleaving deterministic:
  /// unserialised, pass A starts row 1, pass B starts row 2 while A is parked, then A resumes
  /// believing only it is running and starts a third.
  @Test func twoConcurrentSchedulePassesNeverExceedTheTwoTransferCap() async throws {
    let harness = try await DownloadCoordinatorHarness()
    var seeded: [Int64] = [harness.itemRowId]
    for suffix in ["b", "c", "d"] {
      seeded.append(try await harness.seedItem(serverItemId: "item-\(suffix)"))
    }
    let itemRowIds = seeded
    let itemIDs = [DownloadCoordinatorHarness.itemID, "item-b", "item-c", "item-d"]

    try await harness.database.writeAsync { db in
      for (offset, itemRowId) in itemRowIds.enumerated() {
        var row = DownloadRecord(
          accountId: harness.accountId, itemId: itemRowId,
          serverFileIno: String(100 + offset * 100), orderIndex: 0,
          destinationRelativePath: "row-\(offset).m4b", expectedBytes: 10,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
        try row.insert(db)
      }
    }
    for (offset, itemID) in itemIDs.enumerated() {
      harness.enqueueBookItemDetail(
        itemID: itemID,
        audioFiles: [(index: 0, ino: 100 + offset * 100, size: 10, mimeType: "audio/mp4", duration: 1)])
    }

    harness.backgroundTransferring.armEnqueueGate()
    let firstPass = Task { await harness.coordinator.schedule() }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains {
        if case .enqueue = $0 { return true }
        return false
      }
    }
    let secondPass = Task { await harness.coordinator.schedule() }
    harness.backgroundTransferring.releaseEnqueueGate()
    await firstPass.value
    await secondPass.value

    var downloadingCount = 0
    for itemRowId in itemRowIds {
      downloadingCount += try harness.fetchDownloads(itemId: itemRowId).filter { $0.state == .downloading }.count
    }
    let enqueuedIds = Set(
      harness.backgroundTransferring.calls.compactMap { call -> Int64? in
        guard case .enqueue(let identity, _, _, _) = call else { return nil }
        guard case .abs(let downloadId) = identity else { return nil }
        return downloadId
      })
    #expect(downloadingCount == 2, "rule 25 caps concurrent transfers at two")
    #expect(enqueuedIds.count == 2, "a row must not be handed to the adapter twice, nor a third started")
  }

  @Test func scheduleReturnsOnlyAfterAPassThatSawTheCallersOwnWrite() async throws {
    let harness = try await DownloadCoordinatorHarness()
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "first.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try row.insert(db)
    }
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 10, mimeType: "audio/mp4", duration: 1)])
    harness.backgroundTransferring.armEnqueueGate()
    let firstPass = Task { await harness.coordinator.schedule() }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains {
        if case .enqueue = $0 { return true }
        return false
      }
    }

    let secondItem = try await harness.seedItem(serverItemId: "item-b")
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: secondItem, serverFileIno: "200",
        orderIndex: 0, destinationRelativePath: "second.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try row.insert(db)
    }
    harness.enqueueBookItemDetail(
      itemID: "item-b", audioFiles: [(index: 0, ino: 200, size: 10, mimeType: "audio/mp4", duration: 1)])
    let secondPass = Task { await harness.coordinator.schedule() }
    harness.backgroundTransferring.releaseEnqueueGate()
    await firstPass.value
    await secondPass.value

    let secondRow = try #require(try harness.fetchDownloads(itemId: secondItem).first)
    #expect(secondRow.state == .downloading)
    #expect(
      harness.backgroundTransferring.calls.contains { call in
        guard case .enqueue(let identity, _, _, _) = call else { return false }
        guard case .abs(let downloadId) = identity else { return false }
        return downloadId == secondRow.id
      })
  }

  @Test func pauseDoesNotLoseARaceWithASchedulePassThatHoldsTheRowForWiFi() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    try await harness.database.writeAsync { db in
      var row = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "pause-race.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1, state: .downloading)
      try row.insert(db)
    }
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.backgroundTransferring.armPauseGate()
    let pauseTask = Task(priority: .background) { () -> String? in
      do {
        try await harness.coordinator.pauseDownload(downloadId: downloadId)
        return nil
      } catch {
        return String(reflecting: error)
      }
    }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: downloadId)))
    }

    harness.networkConditions.isConstrainedOrCellular = true
    let scheduleTask = Task(priority: .high) { await harness.coordinator.schedule() }
    await TestSupport.awaitQuiescence(
      "the pause-race adapter state to remain unchanged before release",
      of: {
        let calls = harness.backgroundTransferring.calls
        let state = (try? harness.downloadStore.fetch(downloadId: downloadId))?.state
        return "calls \(calls), state \(String(describing: state))"
      })

    harness.backgroundTransferring.releasePauseGate()
    await scheduleTask.value
    let pauseError = await pauseTask.value

    #expect(pauseError == nil)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)
  }

  @Test func resumingWhileASchedulePassIsAlreadyLinkedDoesNotDeadlock() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let (pendingDownloadId, pausedDownloadId) = try await harness.database.writeAsync { db in
      var pending = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "scheduled.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try pending.insert(db)
      var paused = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "200",
        orderIndex: 1, destinationRelativePath: "resumed.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1, state: .paused)
      try paused.insert(db)
      return (pending.id!, paused.id!)
    }

    let completion = DownloadSchedulingCompletion()
    harness.backgroundTransferring.armEnqueueGate()
    let scheduleTask = Task {
      await harness.coordinator.schedule()
      await completion.markScheduleFinished()
    }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains {
        if case .enqueue(let identity, _, _, _) = $0,
          case .abs(let downloadId) = identity
        {
          return downloadId == pendingDownloadId
        }
        return false
      }
    }

    let resumeTask = Task {
      do {
        try await harness.coordinator.resumeDownload(downloadId: pausedDownloadId)
        await completion.markResumeFinished(succeeded: true)
      } catch {
        await completion.markResumeFinished(succeeded: false)
      }
    }
    harness.backgroundTransferring.releaseEnqueueGate()

    let allFinished = await TestSupport.waitUntil { await completion.allFinished() }
    #expect(allFinished)
    #expect(await completion.didResumeSucceed())
    if allFinished {
      await scheduleTask.value
      await resumeTask.value
    }
    #expect(try harness.downloadStore.fetch(downloadId: pausedDownloadId)?.state == .downloading)
  }

  @Test func rssPauseDoesNotLoseARaceWithASchedulePassThatHoldsTheRowForWiFi() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    let feedID = try #require(
      try harness.rssDownloadStore.transferDetails(downloadId: downloadID)?.feed.id)
    await harness.coordinator.schedule()
    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .downloading)

    harness.backgroundTransferring.armPauseGate()
    let pauseTask = Task { () -> String? in
      do {
        try await harness.coordinator.pauseEpisodeDownload(
          itemID: "rss:\(feedID)", episodeID: "rss-episode")
        return nil
      } catch {
        return String(reflecting: error)
      }
    }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains(.pause(identity: .rss(rowID: downloadID)))
    }

    harness.networkConditions.isConstrainedOrCellular = true
    let scheduleTask = Task { await harness.coordinator.schedule() }
    await TestSupport.awaitQuiescence(
      "the RSS pause-race adapter state to remain unchanged before release",
      of: {
        let calls = harness.backgroundTransferring.calls
        let state = (try? harness.rssDownloadStore.fetch(downloadId: downloadID))?.state
        return "calls \(calls), state \(String(describing: state))"
      })

    harness.backgroundTransferring.releasePauseGate()
    await scheduleTask.value
    #expect(await pauseTask.value == nil)
    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .paused)
  }

  @Test func neverStartedRSSRowHeldForWiFiStartsOnceTheNetworkPolicyAllowsIt() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    harness.networkConditions.isConstrainedOrCellular = true
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)

    await harness.coordinator.schedule()
    let held = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)

    harness.networkConditions.isConstrainedOrCellular = false
    await harness.coordinator.schedule()

    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .downloading)
    #expect(
      harness.backgroundTransferring.calls.contains {
        if case .enqueue(let identity, _, _, _) = $0 { return identity == .rss(rowID: downloadID) }
        return false
      })
  }

  @Test func neverStartedRSSRowHeldForWiFiStartsAfterRelaunch() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    harness.networkConditions.isConstrainedOrCellular = true
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    #expect(
      try harness.rssDownloadStore.fetch(downloadId: downloadID)?.holdReason == .waitingForWiFi)

    let freshDownloads = try DownloadStore(database: harness.database)
    let freshRSS = try RSSDownloadStore(database: harness.database)
    let fresh = harness.makeUnsubscribedCoordinator(
      downloadStore: freshDownloads, rssDownloadStore: freshRSS)
    await fresh.reconcileAfterLaunch()
    harness.networkConditions.isConstrainedOrCellular = false
    await fresh.schedule()

    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .downloading)
  }

  @Test func rssRowHeldForWiFiWithALiveTaskIsResumedNotRestarted() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    harness.networkConditions.isConstrainedOrCellular = true
    await harness.coordinator.schedule()
    #expect(
      try harness.rssDownloadStore.fetch(downloadId: downloadID)?.holdReason == .waitingForWiFi)

    harness.networkConditions.isConstrainedOrCellular = false
    await harness.coordinator.schedule()

    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .downloading)
    let enqueues = harness.backgroundTransferring.calls.filter {
      if case .enqueue(let identity, _, _, _) = $0 { return identity == .rss(rowID: downloadID) }
      return false
    }
    #expect(enqueues.count == 1)
    #expect(harness.backgroundTransferring.calls.contains(.resume(identity: .rss(rowID: downloadID))))
  }

  @Test func itemPauseReachesAWiFiHeldABSRow() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.holdReason == .waitingForWiFi
    }

    try await harness.coordinator.pauseItemDownload(itemID: DownloadCoordinatorHarness.itemID)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)
    harness.networkConditions.simulateChange(isConstrainedOrCellular: false)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)
  }

  @Test func resumingRSSWhileASchedulePassIsAlreadyLinkedDoesNotDeadlock() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload()
    let downloadID = try #require(row.id)
    let feedID = try #require(
      try harness.rssDownloadStore.transferDetails(downloadId: downloadID)?.feed.id)
    await harness.coordinator.schedule()
    try await harness.coordinator.pauseEpisodeDownload(
      itemID: "rss:\(feedID)", episodeID: "rss-episode")

    let pendingABSID = try await harness.database.writeAsync { db -> Int64 in
      var pending = DownloadRecord(
        accountId: harness.accountId, itemId: harness.itemRowId, serverFileIno: "100",
        orderIndex: 0, destinationRelativePath: "rss-resume-race.m4b", expectedBytes: 10,
        expectedMimeType: "audio/mp4", fileDurationSeconds: 1)
      try pending.insert(db)
      return pending.id!
    }
    let completion = DownloadSchedulingCompletion()
    harness.backgroundTransferring.armEnqueueGate()
    let scheduleTask = Task {
      await harness.coordinator.schedule()
      await completion.markScheduleFinished()
    }
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains { call in
        guard case .enqueue(let identity, _, _, _) = call else { return false }
        return identity == .abs(rowID: pendingABSID)
      }
    }

    let resumeTask = Task {
      do {
        try await harness.coordinator.resumeEpisodeDownload(
          itemID: "rss:\(feedID)", episodeID: "rss-episode")
        await completion.markResumeFinished(succeeded: true)
      } catch {
        await completion.markResumeFinished(succeeded: false)
      }
    }
    harness.backgroundTransferring.releaseEnqueueGate()

    let allFinished = await TestSupport.waitUntil { await completion.allFinished() }
    #expect(allFinished)
    #expect(await completion.didResumeSucceed())
    if allFinished {
      await scheduleTask.value
      await resumeTask.value
    }
    #expect(try harness.rssDownloadStore.fetch(downloadId: downloadID)?.state == .downloading)
  }

  // MARK: - Concurrency cap + FIFO

  @Test func atMostTwoTransfersAreActiveAtOnce() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let itemAId = try await harness.seedItem(serverItemId: "item-a")
    let itemBId = try await harness.seedItem(serverItemId: "item-b")
    let itemCId = try await harness.seedItem(serverItemId: "item-c")

    for (id, rowId) in [("item-a", itemAId), ("item-b", itemBId), ("item-c", itemCId)] {
      harness.enqueueBookItemDetail(
        itemID: id, audioFiles: [(index: 0, ino: Int(rowId) + 900, size: 100, mimeType: "audio/mp4", duration: 10)])
      try await harness.coordinator.requestDownload(itemID: id)
    }

    let stateA = try harness.fetchDownloads(itemId: itemAId).first?.state
    let stateB = try harness.fetchDownloads(itemId: itemBId).first?.state
    let stateC = try harness.fetchDownloads(itemId: itemCId).first?.state

    #expect(stateA == .downloading)
    #expect(stateB == .downloading)
    #expect(stateC == .pending, "the cap is two - a third request stays queued")
  }

  @Test func fifoByItemThenFileOrder() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let item1Id = try await harness.seedItem(serverItemId: "item-1")
    harness.enqueueBookItemDetail(
      itemID: "item-1",
      audioFiles: [
        (index: 0, ino: 200, size: 100, mimeType: "audio/mp4", duration: 10),
        (index: 1, ino: 201, size: 100, mimeType: "audio/mp4", duration: 10),
      ])
    try await harness.coordinator.requestDownload(itemID: "item-1")

    let item2Id = try await harness.seedItem(serverItemId: "item-2")
    harness.enqueueBookItemDetail(
      itemID: "item-2",
      audioFiles: [
        (index: 0, ino: 300, size: 100, mimeType: "audio/mp4", duration: 10),
        (index: 1, ino: 301, size: 100, mimeType: "audio/mp4", duration: 10),
      ])
    try await harness.coordinator.requestDownload(itemID: "item-2")

    // Item 1 (requested first) fills both slots with its own two files before item 2 gets any.
    let item1Rows = try harness.fetchDownloads(itemId: item1Id)
    let item2Rows = try harness.fetchDownloads(itemId: item2Id)
    #expect(item1Rows.allSatisfy { $0.state == .downloading })
    #expect(item2Rows.allSatisfy { $0.state == .pending })

    // Freeing one slot starts item 2's first file, never its second.
    let firstDownloadId = try #require(item1Rows.first?.id)
    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: firstDownloadId), temporaryFileURL: try harness.makeTempFile(bytes: 100),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 100)))
    await TestSupport.waitUntil {
      guard let rows = try? harness.fetchDownloads(itemId: item2Id) else { return false }
      return rows.first(where: { $0.orderIndex == 0 })?.state == .downloading
    }

    let refreshedItem2Rows = try harness.fetchDownloads(itemId: item2Id)
    #expect(refreshedItem2Rows.first(where: { $0.orderIndex == 0 })?.state == .downloading)
    #expect(refreshedItem2Rows.first(where: { $0.orderIndex == 1 })?.state == .pending)
  }

  // MARK: - Finish events pass response metadata unchanged into validation

  @Test func finishEventsPassResponseMetadataUnchangedIntoValidation() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.state == .completed
    }

    let completed = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(completed.state == .completed)
    #expect(completed.receivedBytes == 50)
  }

  @Test func mismatchedResponseMetadataFailsWithADistinctValidationCategory() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 999)))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.state == .failed
    }

    let failed = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .validation)
  }

  @Test func progressEventsUpdateReceivedBytesWithoutChangingState() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 100, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.backgroundTransferring.pushEvent(
      .progress(identity: .abs(rowID: downloadId), receivedBytes: 40, expectedBytes: 100))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.receivedBytes == 40
    }

    let row = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(row.state == .downloading)
    #expect(row.receivedBytes == 40)
  }

  @Test func rssProgressAndFinishEventsRouteByTaggedIdentity() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: 50)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()

    await harness.coordinator.handleTransferEvent(
      .progress(identity: .rss(rowID: downloadID), receivedBytes: 20, expectedBytes: 50))
    let progressing = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(progressing.state == .downloading)
    #expect(progressing.actualBytes == 20)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadID), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 50)))

    let completed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(completed.state == .completed)
    #expect(completed.actualBytes == 50)
  }

  @Test("an RSS transfer's reported size reaches a row whose feed declared none")
  func rssProgressBackfillsAnUndeclaredSize() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: nil)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()

    await harness.coordinator.handleTransferEvent(
      .progress(identity: .rss(rowID: downloadID), receivedBytes: 20, expectedBytes: 50))

    let progressing = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(progressing.actualBytes == 20)
    #expect(
      progressing.expectedBytes == 50,
      "without this the episode draws an indeterminate spinner for the whole transfer")
  }

  @Test func rssFailureEventsRouteByTaggedIdentity() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: 50)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()

    await harness.coordinator.handleTransferEvent(
      .failed(identity: .rss(rowID: downloadID), errorDomain: "test", errorCode: -1))

    let failed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .transport)
  }

  /// The "In Our Time" reproduction, end to end through the coordinator: a 40,864,000-byte
  /// declared enclosure whose response is 20,742,157 bytes of audio completes, and the trace says
  /// so under the RSS tag with the local row id and nothing else.
  @Test func anRSSFileSmallerThanItsDeclaredLengthCompletesThroughTheCoordinatorEventPath() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }
    let row = try await harness.seedRSSDownload(bytes: 40_864_000)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    let served = try harness.makeSparseTempFile(bytes: 20_742_157)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadID), temporaryFileURL: served,
        response: BackgroundTransferResponse(
          httpStatusCode: 206, mimeType: "audio/mpeg", contentLength: 20_742_157,
          contentRange: "bytes 0-20742156/20742157")))

    let completed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(completed.state == .completed)
    #expect(completed.actualBytes == 20_742_157)
    #expect(try harness.rssFileStore.validatedLocalURL(episodeId: completed.episodeId) != nil)
    let lines = records.value.map(DownloadDeviceTrace.line)
    #expect(lines.contains("WHIRRDL rssTransfer id=\(downloadID) event=start bytes=40864000"))
    #expect(lines.contains("WHIRRDL rssTransfer id=\(downloadID) event=finish result=stored"))
  }

  /// A rejected RSS completion is traced with the store's own closed reason, and the row carries
  /// the category the store chose. The coordinator does not re-fail it generically.
  @Test func aRejectedRSSCompletionTracesItsClosedReason() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let records = Locked<[DownloadDeviceTrace.Record]>([])
    await harness.coordinator.setDeviceTraceSink { record in records.withValue { $0.append(record) } }
    let row = try await harness.seedRSSDownload(bytes: 40_864_000)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    let truncated = try harness.makeSparseTempFile(bytes: 20_000_000)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadID), temporaryFileURL: truncated,
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 20_742_157)))

    let failed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .validation)
    #expect(FileManager.default.fileExists(atPath: truncated.path) == false)
    #expect(
      records.value.contains(
        .rssTransfer(.init(downloadId: downloadID, event: .finish(.rssRejected(.validation, .responseSizeMismatch))))))
  }

  @Test func unknownSizeRSSCapIsEnforcedThroughTheCoordinatorEventPath() async throws {
    let harness = try await DownloadCoordinatorHarness(startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: nil)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    let oversized = try harness.makeSparseTempFile(bytes: RSSFileStore.sizeCapBytes + 1)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadID), temporaryFileURL: oversized,
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: nil)))

    let failed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .validation)
    #expect(FileManager.default.fileExists(atPath: oversized.path) == false)
  }

  @Test func rssDiskFullCompletionPausesTheSharedQueue() async throws {
    let harness = try await DownloadCoordinatorHarness(
      fileMover: FakeDownloadFileMoving(error: FakeDownloadFileMoving.outOfSpace),
      startSubscriptions: false)
    let row = try await harness.seedRSSDownload(bytes: 50)
    let downloadID = try #require(row.id)
    await harness.coordinator.schedule()
    let pending = try await harness.seedRSSDownload(
      feedID: 42, episodeKey: "pending-after-low-disk", bytes: 50)
    let pendingID = try #require(pending.id)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .rss(rowID: downloadID), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 50)))

    let failed = try #require(try harness.rssDownloadStore.fetch(downloadId: downloadID))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .lowDisk)
    #expect(await harness.coordinator.isQueuePausedForLowDisk())
    #expect(try harness.rssDownloadStore.fetch(downloadId: pendingID)?.state == .pending)
    #expect(
      harness.backgroundTransferring.calls.contains { call in
        guard case .enqueue(let identity, _, _, _) = call else { return false }
        return identity == .rss(rowID: pendingID)
      } == false)
  }

  /// A finish the file store could not complete for a reason it does not classify itself (here a
  /// non-space move error) has no transfer left behind it. Left `.downloading`, it would hold one
  /// of the two slots for the rest of the process.
  @Test func anUnclassifiedCompletionErrorFailsTheRowAndFreesItsSlot() async throws {
    let harness = try await DownloadCoordinatorHarness(
      fileMover: FakeDownloadFileMoving(error: FakeDownloadFileMoving.permissionDenied))
    harness.enqueueBookItemDetail(
      audioFiles: (0..<3).map { (index: $0, ino: 100 + $0, size: 50, mimeType: "audio/mp4", duration: 5) })
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let ids = try harness.fetchDownloads(itemId: harness.itemRowId).map { try #require($0.id) }
    #expect(try harness.downloadStore.fetch(downloadId: ids[2])?.state == .pending)

    await harness.coordinator.handleTransferEvent(
      .finished(
        identity: .abs(rowID: ids[0]), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))

    let failed = try #require(try harness.downloadStore.fetch(downloadId: ids[0]))
    #expect(failed.state == .failed)
    #expect(failed.errorCategory == .storage)
    #expect(try harness.downloadStore.fetch(downloadId: ids[2])?.state == .downloading)
  }

  // MARK: - Pause / resume / cancel / delete intents round-trip through rows and adapter

  @Test func pauseTransitionsToPausedAndCallsAdapterPause() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    try await harness.coordinator.pauseDownload(downloadId: downloadId)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)
    #expect(harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: downloadId))))
  }

  @Test func manualResumeResumesTheExistingTaskWithoutASecondEnqueue() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    try await harness.coordinator.pauseDownload(downloadId: downloadId)

    try await harness.coordinator.resumeDownload(downloadId: downloadId)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)
    let callsForDownload = harness.backgroundTransferring.calls.filter { call in
      switch call {
      case .enqueue(let identity, _, _, _), .pause(let identity), .resume(let identity), .cancel(let identity):
        guard case .abs(let id) = identity else { return false }
        return id == downloadId
      }
    }
    #expect(
      callsForDownload.filter {
        if case .enqueue = $0 { return true }
        return false
      }.count == 1)
    #expect(
      callsForDownload.filter {
        if case .resume = $0 { return true }
        return false
      }.count == 1)
  }

  /// The mirror of the resume-the-existing-task case, and the reason ownership is recorded rather
  /// than assumed: a failed transfer's adapter task is gone, and the adapter's `resume` is silent
  /// when no task exists. Such a row must be enqueued afresh, or it would sit `.downloading`
  /// forever with nothing actually running.
  @Test func resumingAFailedRowEnqueuesAFreshTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    await harness.coordinator.handleTransferEvent(
      .failed(identity: .abs(rowID: downloadId), errorDomain: nil, errorCode: nil))
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .failed)

    try await harness.coordinator.resumeDownload(downloadId: downloadId)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)
    #expect(
      harness.backgroundTransferring.calls.filter {
        if case .enqueue(let identity, _, _, _) = $0,
          case .abs(let id) = identity
        {
          return id == downloadId
        }
        return false
      }.count == 2)
  }

  @Test func manuallyResumedTaskConsumesACapSlotBeforePendingRowsStart() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let secondItemRowId = try await harness.seedItem(serverItemId: "item-b")
    let thirdItemRowId = try await harness.seedItem(serverItemId: "item-c")
    let itemRows = [harness.itemRowId, secondItemRowId, thirdItemRowId]
    let itemIDs = [DownloadCoordinatorHarness.itemID, "item-b", "item-c"]

    for (offset, itemID) in itemIDs.enumerated() {
      harness.enqueueBookItemDetail(
        itemID: itemID,
        audioFiles: [(index: 0, ino: 100 + offset, size: 50, mimeType: "audio/mp4", duration: 5)])
      try await harness.coordinator.requestDownload(itemID: itemID)
    }
    let downloadIds = try itemRows.map { itemRowId in
      try #require(try harness.fetchDownloads(itemId: itemRowId).first?.id)
    }

    try await harness.coordinator.pauseDownload(downloadId: downloadIds[0])
    try await harness.coordinator.resumeDownload(downloadId: downloadIds[0])

    let rows = try itemRows.flatMap(harness.fetchDownloads(itemId:))
    #expect(rows.filter { $0.state == .downloading }.count == 2)
    #expect(rows.first { $0.id == downloadIds[2] }?.state == .pending)
    #expect(
      harness.backgroundTransferring.calls.filter {
        if case .enqueue(let identity, _, _, _) = $0,
          case .abs(let id) = identity
        {
          return id == downloadIds[0]
        }
        return false
      }.count == 1)
  }

  @Test func cancelRemovesTheRowAndCancelsTheAdapterTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    try await harness.coordinator.cancelDownload(downloadId: downloadId)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId) == nil)
    #expect(harness.backgroundTransferring.calls.contains(.cancel(identity: .abs(rowID: downloadId))))
  }

  @Test func deleteRemovesACompletedDownloadsRow() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    harness.backgroundTransferring.pushEvent(
      .finished(
        identity: .abs(rowID: downloadId), temporaryFileURL: try harness.makeTempFile(bytes: 50),
        response: BackgroundTransferResponse(httpStatusCode: 200, mimeType: "audio/mp4", contentLength: 50)))
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.state == .completed
    }
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .completed)

    try await harness.coordinator.deleteDownload(downloadId: downloadId)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId) == nil)
  }

  // MARK: - Cellular gate (opt-in)

  @Test func cellularDisallowedHoldsTheTransferInPendingWithWaitingForWiFiAndAutoStartsOnWiFi() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.networkConditions.isConstrainedOrCellular = true
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)

    let held = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: false)
    let heldDownloadId = try #require(held.id)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: heldDownloadId))?.state == .downloading
    }
    let started = try #require(try harness.downloadStore.fetch(downloadId: heldDownloadId))
    #expect(started.state == .downloading)
  }

  @Test func flippingTheCellularOptInMidWaitStartsTheHeldTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.networkConditions.isConstrainedOrCellular = true
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])

    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let held = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first)
    #expect(held.holdReason == .waitingForWiFi)

    await harness.downloadPreferences.setAllowCellular(true)
    let heldDownloadId = try #require(held.id)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: heldDownloadId))?.state == .downloading
    }
    let started = try #require(try harness.downloadStore.fetch(downloadId: heldDownloadId))
    #expect(started.state == .downloading)
  }

  @Test func wifiLossPausesAnActiveTransferAndWifiReturnResumesIt() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(
      try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.holdReason
        == .waitingForWiFi
    }

    let held = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)
    #expect(
      harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: downloadId))))

    harness.networkConditions.simulateChange(isConstrainedOrCellular: false)
    // Waits on the resume call rather than the row state. The release path transitions the row to
    // `.downloading` first and resumes the suspended task after, so waiting on the state can wake
    // this test inside that gap, because the store call between them suspends. Resuming is the
    // later of the two events, so both assertions below hold at the point this returns.
    await TestSupport.waitUntil {
      harness.backgroundTransferring.calls.contains(.resume(identity: .abs(rowID: downloadId)))
    }

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)
    #expect(
      harness.backgroundTransferring.calls.contains(.resume(identity: .abs(rowID: downloadId))))
    // A held row is released by resuming its existing suspended task, never by starting a second
    // transfer for it. Concurrent scheduling passes can reach that because every store call
    // suspends, and a duplicate enqueue would strand the first task.
    let enqueueCount = harness.backgroundTransferring.calls.count {
      if case .enqueue(let identity, _, _, _) = $0,
        case .abs(let id) = identity
      {
        return id == downloadId
      }
      return false
    }
    #expect(enqueueCount == 1)
  }

  @Test func wifiPolicyRunsWhenBothTransferSlotsAreBusy() async throws {
    let harness = try await DownloadCoordinatorHarness()
    let secondItemID = try await harness.seedItem(serverItemId: "item-b")
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    harness.enqueueBookItemDetail(
      itemID: "item-b",
      audioFiles: [(index: 0, ino: 200, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: "item-b")
    let ids = try
      (harness.fetchDownloads(itemId: harness.itemRowId)
      + harness.fetchDownloads(itemId: secondItemID)).compactMap(\.id)
    #expect(ids.count == 2)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)
    await TestSupport.waitUntil {
      ids.allSatisfy {
        (try? harness.downloadStore.fetch(downloadId: $0))?.holdReason == .waitingForWiFi
      }
    }

    for id in ids {
      #expect(try harness.downloadStore.fetch(downloadId: id)?.state == .pending)
      #expect(harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: id))))
    }
  }

  @Test func disablingCellularMidTransferPausesTheActiveTransfer() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.networkConditions.isConstrainedOrCellular = true
    await harness.downloadPreferences.setAllowCellular(true)
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(
      try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)

    await harness.downloadPreferences.setAllowCellular(false)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.holdReason
        == .waitingForWiFi
    }

    let held = try #require(try harness.downloadStore.fetch(downloadId: downloadId))
    #expect(held.state == .pending)
    #expect(held.holdReason == .waitingForWiFi)
    #expect(harness.backgroundTransferring.calls.contains(.pause(identity: .abs(rowID: downloadId))))
  }

  @Test func userPauseReachesANetworkHeldTransferAndSurvivesWiFiReturn() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(
      audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(
      try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: true)
    await TestSupport.waitUntil {
      (try? harness.downloadStore.fetch(downloadId: downloadId))?.holdReason
        == .waitingForWiFi
    }

    // The row is durably `.pending(.waitingForWiFi)`, not `.downloading`. The intent must still
    // reach it, or the state the user most wants control over is the one it can't touch.
    try await harness.coordinator.pauseDownload(downloadId: downloadId)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)

    harness.networkConditions.simulateChange(isConstrainedOrCellular: false)

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)
  }

  // MARK: - User pause / deleting / pausedAuth never auto-start

  @Test func userPauseSurvivesRelaunchAndIsNotAutoResumed() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    try await harness.coordinator.pauseDownload(downloadId: downloadId)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .paused)

    // Simulated relaunch: constructing a fresh `DownloadStore` performs the launch
    // reconciliation (`.downloading` -> `.interrupted`); `.paused` rows are untouched by that, and
    // a fresh coordinator's `reconcileAfterLaunch` only requeues `.interrupted` rows.
    let freshStore = try DownloadStore(database: harness.database)
    let freshCoordinator = harness.makeCoordinator(downloadStore: freshStore)
    await freshCoordinator.reconcileAfterLaunch()

    #expect(
      try freshStore.fetch(downloadId: downloadId)?.state == .paused,
      "a user pause is never auto-resumed")
  }

  @Test func deletingRowsNeverAutoStart() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .downloading)
    _ = try harness.downloadStore.transition(downloadId: downloadId, to: .deleting)
    let enqueueCountBefore = harness.backgroundTransferring.calls.count

    await harness.coordinator.schedule()

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .deleting)
    #expect(harness.backgroundTransferring.calls.count == enqueueCountBefore)
  }

  @Test func pausedAuthRowsNeverAutoStart() async throws {
    let harness = try await DownloadCoordinatorHarness()
    harness.enqueueBookItemDetail(audioFiles: [(index: 0, ino: 100, size: 50, mimeType: "audio/mp4", duration: 5)])
    try await harness.coordinator.requestDownload(itemID: DownloadCoordinatorHarness.itemID)
    let downloadId = try #require(try harness.fetchDownloads(itemId: harness.itemRowId).first?.id)
    _ = try harness.downloadStore.transition(downloadId: downloadId, to: .pausedAuth)
    let enqueueCountBefore = harness.backgroundTransferring.calls.count

    await harness.coordinator.schedule()

    #expect(try harness.downloadStore.fetch(downloadId: downloadId)?.state == .pausedAuth)
    #expect(harness.backgroundTransferring.calls.count == enqueueCountBefore)
  }
}
