import ABSApi
import Foundation
import Persistence

/// Errors the pause/resume/cancel/delete intents raise.
public enum DownloadIntentError: Error, Sendable, Equatable {
  case downloadNotFound(Int64)
}

/// Pause, resume, cancel and delete, plus the item- and episode-scoped forms the UI calls.
/// Purge and account removal live in `DownloadCoordinator+Purge.swift`.
extension DownloadCoordinator {
  // MARK: - Intents

  public func pauseDownload(downloadId: Int64) async throws {
    try await onChain { [self] in
      try await self.performPause(downloadId: downloadId)
    }
  }

  /// A Wi-Fi-held row is durably `.pending` but owns a suspended adapter task, so item-, episode-
  /// and ebook-scoped pauses must select it alongside `.downloading` rows; `performPause` then
  /// applies the per-row held-transfer handling.
  private func isPausableABSRow(_ row: DownloadRecord) -> Bool {
    row.state == .downloading
      || (row.state == .pending && row.id.map(liveTaskOwnedDownloadIds.contains) == true)
  }

  private func performPause(downloadId: Int64) async throws {
    guard let row = try await downloadStore.fetchAsync(downloadId: downloadId) else {
      throw DownloadIntentError.downloadNotFound(downloadId)
    }
    // A network-held transfer is durably `.pending(.waitingForWiFi)` but still owns a suspended
    // adapter task, so an explicit user pause must reach it too.
    let isNetworkHeld = liveTaskOwnedDownloadIds.contains(downloadId)
    guard row.state == .downloading || isNetworkHeld else { return }
    await backgroundTransferring.pause(identity: .abs(rowID: downloadId))
    authRetriedDownloadIds.remove(downloadId)
    liveTaskOwnedDownloadIds.remove(downloadId)
    // The pause reached a live task (`.downloading`, or held with its task suspended), so a later
    // resume can hand that same task back instead of enqueuing a second one.
    suspendedTaskDownloadIds.insert(downloadId)
    if isNetworkHeld, row.state == .pending {
      // `.pending` → `.paused` has no direct edge in `DownloadStore`'s matrix; go back out via
      // `.downloading` (see `holdForWiFi`).
      guard (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)) != nil else {
        return
      }
    }
    _ = try await downloadStore.transitionAsync(downloadId: downloadId, to: .paused)
  }

  /// Re-enters `.pending` first (`DownloadStore` has no direct `.paused`/`.failed`/`.interrupted`
  /// → `.downloading` edge) and restarts through the ordinary scheduler. A row that still owns a
  /// suspended adapter task takes the scheduler's live-task release path instead of
  /// `startTransfer`, so the task is handed back rather than duplicated.
  public func resumeDownload(downloadId: Int64) async throws {
    try await onChain { [self] in
      try await self.performResume(downloadId: downloadId)
    }
    await schedule()
  }

  private func performResume(downloadId: Int64) async throws {
    guard let row = try await downloadStore.fetchAsync(downloadId: downloadId) else {
      throw DownloadIntentError.downloadNotFound(downloadId)
    }
    guard row.state == .paused || row.state == .failed || row.state == .interrupted else { return }
    if suspendedTaskDownloadIds.remove(downloadId) != nil {
      liveTaskOwnedDownloadIds.insert(downloadId)
    }
    _ = try await downloadStore.transitionAsync(downloadId: downloadId, to: .pending)
    eventFailedDownloadIds.remove(downloadId)
  }

  /// Cancels an in-flight or not-yet-started transfer through the recoverable deletion protocol,
  /// which is legal from every state except `.deleting`.
  public func cancelDownload(downloadId: Int64) async throws {
    try await onChain { [self] in
      try await self.performCancel(downloadId: downloadId)
    }
    emitDeviceTraceRecord(.cancel(downloadId: downloadId))
    await schedule()
  }

  private func performCancel(downloadId: Int64) async throws {
    guard let row = try await downloadStore.fetchAsync(downloadId: downloadId) else {
      throw DownloadIntentError.downloadNotFound(downloadId)
    }
    // A paused row still owns its suspended adapter task. Left alive, that task holds a per-host
    // connection, and later transfers from the same host stall.
    if row.state == .downloading || liveTaskOwnedDownloadIds.contains(downloadId)
      || suspendedTaskDownloadIds.contains(downloadId)
    {
      await backgroundTransferring.cancel(identity: .abs(rowID: downloadId))
    }
    authRetriedDownloadIds.remove(downloadId)
    liveTaskOwnedDownloadIds.remove(downloadId)
    suspendedTaskDownloadIds.remove(downloadId)
    try downloadFileStore.delete(downloadId: downloadId)
  }

  /// Removes a (typically `.completed`) download. Shares `cancelDownload`'s implementation, as the
  /// deletion protocol is uniform across source states.
  public func deleteDownload(downloadId: Int64) async throws {
    try await cancelDownload(downloadId: downloadId)
  }

  // MARK: - Storage-ceiling deletion boundary

  /// Cancels the adapter task for a row already atomically claimed by the storage-ceiling pass.
  /// The pass decides whether the pre-mark snapshot was `.downloading` or a Wi-Fi-held pending
  /// row. Does not schedule, so a whole batch can be cancelled and deleted before the one
  /// trailing schedule.
  public func cancelStorageCeilingDownload(downloadId: Int64) async {
    await backgroundTransferring.cancel(identity: .abs(rowID: downloadId))
    authRetriedDownloadIds.remove(downloadId)
    liveTaskOwnedDownloadIds.remove(downloadId)
    suspendedTaskDownloadIds.remove(downloadId)
  }

  /// Finishes the file delete and row finalize for a row already marked `.deleting` by the atomic
  /// claim. `DownloadFileStore.delete` is idempotent for the file, then calls
  /// `DownloadStore.finalizeDeletion`, so launch crash recovery still applies.
  public func deleteStorageCeilingDownload(downloadId: Int64) async throws {
    try downloadFileStore.delete(downloadId: downloadId)
  }

  public func cancelStorageCeilingDownload(identity: StorageEvictionIdentity) async {
    let downloadId = identity.downloadId
    guard identity.source == .rss else {
      await cancelStorageCeilingDownload(downloadId: downloadId ?? identity.itemId)
      return
    }
    guard let downloadId else { return }
    await backgroundTransferring.cancel(identity: .rss(rowID: downloadId))
    rssLiveTaskOwnedDownloadIds.remove(downloadId)
    rssSuspendedTaskDownloadIds.remove(downloadId)
  }

  public func deleteStorageCeilingDownload(identity: StorageEvictionIdentity) async throws {
    guard identity.source == .rss else {
      try await deleteStorageCeilingDownload(downloadId: identity.downloadId ?? identity.itemId)
      return
    }
    guard let downloadId = identity.downloadId, let rssFileStore else { return }
    try rssFileStore.delete(downloadId: downloadId)
  }

  /// The storage-ceiling pass calls this once after its whole batch.
  public func scheduleAfterStorageCeiling() async {
    await schedule()
  }

  // MARK: - Item-scoped intents (`DownloadIntents` conformance)

  /// Pauses every pausable row belonging to `itemID`, via `pauseDownload(downloadId:)`.
  public func pauseItemDownload(itemID: String) async throws {
    for row in try await itemDownloadRows(itemID: itemID) where isPausableABSRow(row) {
      guard let downloadId = row.id else { continue }
      try await pauseDownload(downloadId: downloadId)
    }
  }

  /// Resumes every paused/failed/interrupted row belonging to `itemID`, applying
  /// `resumeDownload(downloadId:)`'s eligible-state guard across all of the item's files.
  public func resumeItemDownload(itemID: String) async throws {
    for row in try await itemDownloadRows(itemID: itemID)
    where row.state == .paused || row.state == .failed || row.state == .interrupted {
      guard let downloadId = row.id else { continue }
      try await resumeDownload(downloadId: downloadId)
    }
  }

  public func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      try await onChain { [self] in
        try await self.performPauseRSSEpisodeDownload(feedId: feedId, episodeID: episodeID)
      }
      return
    }
    for row in try await episodeDownloadRows(itemID: itemID, episodeID: episodeID)
    where isPausableABSRow(row) {
      guard let downloadId = row.id else { continue }
      try await pauseDownload(downloadId: downloadId)
    }
  }

  public func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      try await onChain { [self] in
        try await self.performResumeRSSEpisodeDownload(feedId: feedId, episodeID: episodeID)
      }
      await schedule()
      return
    }
    for row in try await episodeDownloadRows(itemID: itemID, episodeID: episodeID)
    where row.state == .paused || row.state == .failed || row.state == .interrupted {
      guard let downloadId = row.id else { continue }
      try await resumeDownload(downloadId: downloadId)
    }
  }

  /// Pauses only the ebook row for `itemID`, leaving any audiobook rows untouched.
  public func pauseEbookDownload(itemID: String) async throws {
    for row in try await itemDownloadRows(itemID: itemID, mediaKind: .ebook)
    where isPausableABSRow(row) {
      guard let downloadId = row.id else { continue }
      try await pauseDownload(downloadId: downloadId)
    }
  }

  /// Resumes only paused/failed/interrupted ebook rows. The ordinary scheduler starts the
  /// transfer once the row re-enters `.pending`.
  public func resumeEbookDownload(itemID: String) async throws {
    for row in try await itemDownloadRows(itemID: itemID, mediaKind: .ebook)
    where row.state == .paused || row.state == .failed || row.state == .interrupted {
      guard let downloadId = row.id else { continue }
      try await resumeDownload(downloadId: downloadId)
    }
  }

  // MARK: - Row lookups shared with the purge block

  func resolveItemRowId(itemID: String) async throws -> Int64? {
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      return nil
    }
    return try await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID)?.id
  }

  private func itemDownloadRows(
    itemID: String, mediaKind: DownloadMediaKind? = nil
  ) async throws -> [DownloadRecord] {
    guard let itemRowId = try await resolveItemRowId(itemID: itemID) else { return [] }
    let rows = try await downloadStore.fetchDownloadsAsync(itemId: itemRowId)
    guard let mediaKind else { return rows }
    return rows.filter { $0.mediaKind == mediaKind }
  }

  private func episodeDownloadRows(
    itemID: String, episodeID: String
  ) async throws -> [DownloadRecord] {
    guard
      let (itemRowId, episodeRowId) = try await resolveEpisodeRowIDs(
        itemID: itemID, episodeID: episodeID)
    else { return [] }
    return try await downloadStore.fetchDownloadsAsync(
      itemId: itemRowId, podcastEpisodeId: episodeRowId)
  }

  func resolveEpisodeRowIDs(
    itemID: String, episodeID: String
  ) async throws -> (itemRowId: Int64, episodeRowId: Int64)? {
    guard let accountRecord = try await accountDAO.fetchAsync(), let accountId = accountRecord.id,
      let itemRow = try await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id,
      let episode = try await podcastEpisodeDAO.fetchOneAsync(
        itemId: itemRowId, serverEpisodeId: episodeID),
      episode.accountId == accountId,
      let episodeRowId = episode.id
    else { return nil }
    return (itemRowId, episodeRowId)
  }

  func rssDownload(feedId: Int64, episodeID: String) async throws -> RSSDownloadRecord? {
    guard
      let episode = try await RSSEpisodeStore(database: database).fetchEpisode(feedId: feedId, identityKey: episodeID)
    else { return nil }
    return try await rssDownloadStore?.fetchAsync(episodeId: episode.id!)
  }

  // MARK: - RSS pause / resume

  private func performPauseRSSEpisodeDownload(feedId: Int64, episodeID: String) async throws {
    guard let rssDownloadStore, let row = try await rssDownload(feedId: feedId, episodeID: episodeID), let id = row.id
    else { return }
    let isHeld = rssLiveTaskOwnedDownloadIds.contains(id)
    guard row.state == .downloading || isHeld else { return }
    await backgroundTransferring.pause(identity: .rss(rowID: id))
    rssLiveTaskOwnedDownloadIds.remove(id)
    rssSuspendedTaskDownloadIds.insert(id)
    if isHeld, row.state == .pending {
      guard (try? await rssDownloadStore.transitionAsync(downloadId: id, to: .downloading)) != nil else { return }
    }
    _ = try await rssDownloadStore.transitionAsync(downloadId: id, to: .paused)
  }

  private func performResumeRSSEpisodeDownload(feedId: Int64, episodeID: String) async throws {
    guard let rssDownloadStore, let row = try await rssDownload(feedId: feedId, episodeID: episodeID), let id = row.id
    else { return }
    guard row.state == .paused || row.state == .failed || row.state == .interrupted else { return }
    if rssSuspendedTaskDownloadIds.remove(id) != nil { rssLiveTaskOwnedDownloadIds.insert(id) }
    _ = try await rssDownloadStore.transitionAsync(downloadId: id, to: .pending)
    rssEventFailedDownloadIds.remove(id)
  }
}
