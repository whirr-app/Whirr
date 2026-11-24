import ABSApi
import Foundation
import Persistence

/// Low-disk queue-pause reason, exposed alongside the per-row `DownloadErrorCategory.lowDisk` so a
/// caller can render a single storage-full banner instead of one message per failed row.
public enum DownloadQueuePauseReason: Sendable, Equatable {
  case lowDisk
}

/// Scheduling: network policy on active transfers, then admitting never-started rows into the
/// two transfer slots. Transfer events live in `+TransferEvents`, starting one in `+TransferStart`.
extension DownloadCoordinator {
  private enum ScheduledRow: Sendable {
    case abs(DownloadRecord)
    case rss(RSSDownloadRecord)

    var id: Int64? {
      switch self {
      case .abs(let row): row.id
      case .rss(let row): row.id
      }
    }

    var isRSS: Bool {
      if case .rss = self { return true }
      return false
    }
  }

  // MARK: - Low-disk queue status

  /// `true` once a low-disk condition (proactive via `FreeSpaceReporting`, or reactive via a
  /// disk-full write failure) has paused the whole queue instead of failing rows one at a time.
  /// Cleared only when a transfer actually starts again (see `schedule()`), not on a timer.
  public func isQueuePausedForLowDisk() async -> Bool {
    queuePauseReason == .lowDisk
  }

  // MARK: - Scheduling (DownloadSchedulingTests)

  /// Enforces the current network policy on already-active transfers before considering the slot
  /// cap, then starts as many never-started `.pending` rows as slots allow (max two concurrent
  /// transfers). Order is earliest-requested item first, then file order within the item, both
  /// from sorting on `DownloadRecord.id` ascending (planning inserts one item's catalog in
  /// ascending `orderIndex` order in a single batch).
  func schedule() async {
    let predecessor = serialTail
    let pass = Task { [weak self] in
      await predecessor?.value
      await self?.performSchedule()
    }
    serialTail = pass
    await pass.value
  }

  private func performSchedule() async {
    // The purge's trailing `schedule()` must not restart anything once removal has begun.
    guard isRemovingAccount == false else { return }
    guard let accountRecord = try? await accountDAO.fetchAsync(), accountRecord.id != nil else {
      return
    }
    await requeueDueAutomaticRetries()

    var rows = (try? await downloadStore.fetchAllAsync()) ?? []
    var rssRows = (try? await rssDownloadStore?.fetchAllAsync()) ?? []
    await enforceNetworkPolicy(on: rows, otherActiveCount: rssRows.filter { $0.state == .downloading }.count)
    rows = (try? await downloadStore.fetchAllAsync()) ?? []
    await enforceRSSNetworkPolicy(on: rssRows, otherActiveCount: rows.filter { $0.state == .downloading }.count)
    rows = (try? await downloadStore.fetchAllAsync()) ?? []
    rssRows = (try? await rssDownloadStore?.fetchAllAsync()) ?? []

    let activeCount =
      rows.filter { $0.state == .downloading }.count
      + rssRows.filter { $0.state == .downloading }.count
    let availableSlots = Self.maxConcurrentTransfers - activeCount
    // Before the guards, so a pass that starts nothing still says why (the slot cap, cellular
    // policy and low disk all look like one stalled row in the UI).
    emitScheduleTrace(rows: rows, activeCount: activeCount, availableSlots: availableSlots)
    guard availableSlots > 0 else { return }
    guard let account = try? tokenAccount(for: accountRecord) else { return }

    let pendingRows = pendingScheduleRows(abs: rows, rss: rssRows)
    await startPendingRows(pendingRows, availableSlots: availableSlots, account: account)
  }

  private func emitScheduleTrace(rows: [DownloadRecord], activeCount: Int, availableSlots: Int) {
    let skippedCount = rows.filter {
      guard $0.state == .pending, let id = $0.id else { return false }
      return eventFailedDownloadIds.contains(id)
    }.count
    emitDeviceTraceRecord(
      .schedule(
        DownloadDeviceTrace.Schedule(
          active: activeCount, pending: rows.filter { $0.state == .pending }.count,
          slots: max(0, availableSlots),
          isConstrainedOrCellular: networkConditions.isConstrainedOrCellular,
          allowsCellular: downloadPreferences.allowCellular,
          isQueuePausedForLowDisk: queuePauseReason == .lowDisk, skipped: skippedCount)))
  }

  /// Every never-started `.pending` row, ABS and RSS, in start order.
  private func pendingScheduleRows(
    abs rows: [DownloadRecord], rss rssRows: [RSSDownloadRecord]
  ) -> [ScheduledRow] {
    var pendingRows: [ScheduledRow] = rows.filter {
      guard $0.state == .pending else { return false }
      guard let id = $0.id else { return true }
      return eventFailedDownloadIds.contains(id) == false
    }.map(ScheduledRow.abs)
    pendingRows += rssRows.filter {
      // A Wi-Fi hold with no live task (never started, or its task died with the process) has
      // nothing for `enforceRSSNetworkPolicy` to resume, so it re-enters the start path; a held
      // row that does own a task is skipped below. Feed-credential holds are `.pausedAuth`.
      guard $0.state == .pending, $0.holdReason == nil || $0.holdReason == .waitingForWiFi,
        let id = $0.id
      else { return false }
      return rssEventFailedDownloadIds.contains(id) == false
    }.map(ScheduledRow.rss)
    pendingRows.sort { ($0.id ?? 0, $0.isRSS ? 1 : 0) < ($1.id ?? 0, $1.isRSS ? 1 : 0) }
    return pendingRows
  }

  /// Admits rows in order until the slots run out. `availableSlots` is this pass's own budget;
  /// each admitted row spends one, and a low-disk read pauses the queue and ends the pass.
  private func startPendingRows(
    _ pendingRows: [ScheduledRow], availableSlots: Int, account: TokenAccount
  ) async {
    var availableSlots = availableSlots
    for scheduled in pendingRows {
      guard availableSlots > 0, let downloadId = scheduled.id else { break }

      if networkConditions.isConstrainedOrCellular, downloadPreferences.allowCellular == false {
        switch scheduled {
        case .abs(let row) where row.holdReason != .waitingForWiFi:
          await holdForWiFi(downloadId: downloadId)
        case .rss(let row) where row.holdReason != .waitingForWiFi:
          await holdRSSForWiFi(downloadId: downloadId)
        default: break
        }
        continue
      }

      // A row still in `liveTaskOwnedDownloadIds` owns a suspended adapter task and belongs to
      // `enforceNetworkPolicy`'s resume path, not to `startTransfer`. Store calls suspend, so a
      // second concurrent pass can reach this loop while the first is still inside
      // `enforceNetworkPolicy`. Without this guard it would start a new transfer for a row about
      // to be resumed, and the resume would then fail on the already-`.downloading` row.
      switch scheduled {
      case .abs where liveTaskOwnedDownloadIds.contains(downloadId): continue
      case .rss where rssLiveTaskOwnedDownloadIds.contains(downloadId): continue
      default: break
      }

      // Read free space up front and pause the whole queue (not just this row) rather than start
      // a transfer that cannot fit and fail at write time. Rows stay `.pending`; the next
      // `schedule()` (a condition change, a resume, a purge freeing space) resumes once there's
      // room.
      let admissionBytes: Int64 =
        switch scheduled {
        case .abs(let row): row.expectedBytes
        case .rss(let row): RSSFileStore.admissionBytes(expectedBytes: row.expectedBytes)
        }
      guard freeSpaceReporting.availableCapacityBytes() >= admissionBytes else {
        queuePauseReason = .lowDisk
        break
      }

      let didStart: Bool
      switch scheduled {
      case .abs(let row):
        didStart = await startTransfer(row: row, downloadId: downloadId, account: account)
      case .rss(let row): didStart = await startRSSTransfer(row: row, downloadId: downloadId)
      }
      if didStart {
        queuePauseReason = nil
        availableSlots -= 1
      }
    }
  }

  /// Pauses live work as soon as cellular/constrained access becomes disallowed, even when both
  /// transfer slots are occupied. On Wi-Fi (or opt-in), only those suspended adapter tasks are
  /// resumed; pending rows continue through `startTransfer`.
  private func enforceNetworkPolicy(on rows: [DownloadRecord], otherActiveCount: Int = 0) async {
    let isDisallowed =
      networkConditions.isConstrainedOrCellular && downloadPreferences.allowCellular == false

    if isDisallowed {
      for row in rows where row.state == .downloading {
        guard let downloadId = row.id else { continue }
        await backgroundTransferring.pause(identity: .abs(rowID: downloadId))
        authRetriedDownloadIds.remove(downloadId)
        if (try? await downloadStore.transitionAsync(
          downloadId: downloadId, to: .pending, holdReason: .waitingForWiFi)) != nil
        {
          liveTaskOwnedDownloadIds.insert(downloadId)
          trace(downloadId, .hold(origin: .active))
        } else {
          await backgroundTransferring.resume(identity: .abs(rowID: downloadId))
        }
      }
      return
    }

    var availableSlots = Self.maxConcurrentTransfers - rows.filter { $0.state == .downloading }.count - otherActiveCount
    let heldRows = rows.filter { row in
      guard row.state == .pending, let id = row.id else { return false }
      return liveTaskOwnedDownloadIds.contains(id)
    }.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    for row in heldRows {
      guard availableSlots > 0, let downloadId = row.id else { break }
      // A network-held row bypasses `startTransfer` on resume, so re-check the item here.
      // Quarantine releases the suspended adapter task but leaves the durable row pending; local
      // progress and any completed file stay available to the reader.
      guard let itemRecord = try? await itemDAO.fetchOneAsync(id: row.itemId) else { continue }
      guard itemRecord.softDeleted == false else {
        liveTaskOwnedDownloadIds.remove(downloadId)
        await backgroundTransferring.cancel(identity: .abs(rowID: downloadId))
        continue
      }
      if (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil {
        liveTaskOwnedDownloadIds.remove(downloadId)
        await backgroundTransferring.resume(identity: .abs(rowID: downloadId))
        availableSlots -= 1
        trace(downloadId, .release)
      }
    }
  }

  private func enforceRSSNetworkPolicy(on rows: [RSSDownloadRecord], otherActiveCount: Int) async {
    guard let rssDownloadStore else { return }
    let isDisallowed = networkConditions.isConstrainedOrCellular && downloadPreferences.allowCellular == false
    if isDisallowed {
      for row in rows where row.state == .downloading {
        guard let id = row.id else { continue }
        await backgroundTransferring.pause(identity: .rss(rowID: id))
        if (try? await rssDownloadStore.transitionAsync(
          downloadId: id, to: .pending, holdReason: .waitingForWiFi)) != nil
        {
          rssLiveTaskOwnedDownloadIds.insert(id)
        } else {
          await backgroundTransferring.resume(identity: .rss(rowID: id))
        }
      }
      return
    }
    var availableSlots =
      Self.maxConcurrentTransfers
      - rows.filter { $0.state == .downloading }.count - otherActiveCount
    for id in rows.compactMap(\.id).filter({ rssLiveTaskOwnedDownloadIds.contains($0) }).sorted() {
      guard availableSlots > 0 else { break }
      guard (try? await rssDownloadStore.transitionAsync(downloadId: id, to: .downloading)) != nil else { continue }
      rssLiveTaskOwnedDownloadIds.remove(id)
      await backgroundTransferring.resume(identity: .rss(rowID: id))
      availableSlots -= 1
    }
  }

  /// The only legal path to a `.pending` row with the durable `waitingForWiFi` hold is a
  /// `.downloading` -> `.pending` transition (`DownloadStore` has no `.pending` -> `.pending`
  /// edge), so this round trip represents a hold and is never a real transfer attempt.
  private func holdForWiFi(downloadId: Int64) async {
    guard (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil else {
      return
    }
    _ = try? await downloadStore.transitionAsync(
      downloadId: downloadId, to: .pending, holdReason: .waitingForWiFi)
    trace(downloadId, .hold(origin: .pending))
  }

  private func holdRSSForWiFi(downloadId: Int64) async {
    guard let rssDownloadStore,
      (try? await rssDownloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil
    else { return }
    _ = try? await rssDownloadStore.transitionAsync(
      downloadId: downloadId, to: .pending, holdReason: .waitingForWiFi)
  }
}

// MARK: - Auto-download low-disk gate

/// `isQueuePausedForLowDisk()` already satisfies `PodcastAutoDownloadLowDiskGating`, so the empty
/// conformance is the whole wiring.
extension DownloadCoordinator: PodcastAutoDownloadLowDiskGating {}
