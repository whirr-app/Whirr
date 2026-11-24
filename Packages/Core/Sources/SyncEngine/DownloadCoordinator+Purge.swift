import ABSApi
import Foundation
import Persistence

/// Purge and account removal. Every purge follows the same mark / cancel / delete protocol:
/// `DownloadStore` marks rows `.deleting` in one transaction, transfers are cancelled, then the
/// idempotent file-delete/row-delete protocol finishes each row, so a crash resumes from the
/// durable marker via `DownloadIntegritySweep` on next launch.
extension DownloadCoordinator {
  private func tracePurge(
    scope: DownloadDeviceTrace.PurgeScope, source: DownloadPurgeSource, rows: Int
  ) {
    emitDeviceTraceRecord(
      .purge(DownloadDeviceTrace.Purge(scope: scope, source: source, rows: rows)))
  }

  // MARK: - Episode purge

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      let didPurge = try await onChain { [self] in
        try await self.performPurgeRSSEpisodeDownload(
          feedId: feedId, episodeID: episodeID, source: source)
      }
      if didPurge { await schedule() }
      return
    }
    guard
      let (itemRowId, episodeRowId) = try await resolveEpisodeRowIDs(
        itemID: itemID, episodeID: episodeID)
    else {
      tracePurge(scope: .episode, source: source, rows: 0)
      return
    }
    if source.isAutomatic {
      let rows = try await downloadStore.fetchDownloadsAsync(
        itemId: itemRowId, podcastEpisodeId: episodeRowId)
      guard Self.hasWorkInFlight(rows) == false else {
        tracePurge(scope: .episode, source: source, rows: 0)
        return
      }
    }
    let markedRows = try await downloadStore.markDeletingAsync(
      itemId: itemRowId, podcastEpisodeId: episodeRowId)
    tracePurge(scope: .episode, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Reaper-only RSS purge. The active-playback predicate comes from the RSS playback tracker and
  /// is evaluated inside the deletion transaction, not against the candidate-selection snapshot.
  /// ABS callers use the ordinary item/episode purge path.
  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource,
    activePlaybackExclusion: @escaping @Sendable (Int64) -> Bool
  ) async throws {
    guard let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      try await purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
      return
    }
    let didPurge = try await onChain { [self] in
      try await self.performPurgeRSSEpisodeDownload(
        feedId: feedId, episodeID: episodeID, source: source,
        activePlaybackExclusion: activePlaybackExclusion)
    }
    if didPurge { await schedule() }
  }

  /// Purges only ebook rows for `itemID`. `purgeItemDownload` still removes all media, for the
  /// explicit item-wide removal action.
  public func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {
    guard let itemRowId = try await resolveItemRowId(itemID: itemID) else {
      tracePurge(scope: .ebook, source: source, rows: 0)
      return
    }
    let markedRows = try await downloadStore.markDeletingAsync(itemId: itemRowId, mediaKind: .ebook)
    tracePurge(scope: .ebook, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Purges only an audiobook's audio rows, leaving its ebook and supplements. A pinned list's
  /// release uses it: the pin downloaded the audio and nothing else. An automatic source steps
  /// aside while any of the item's own media is still transferring, as `purgeItem` does.
  public func purgeItemAudioDownload(itemID: String, source: DownloadPurgeSource) async throws {
    guard let itemRowId = try await resolveItemRowId(itemID: itemID) else {
      tracePurge(scope: .audio, source: source, rows: 0)
      return
    }
    if source.isAutomatic {
      let rows = try await downloadStore.fetchDownloadsAsync(itemId: itemRowId)
      guard Self.hasWorkInFlight(rows) == false else {
        tracePurge(scope: .audio, source: source, rows: 0)
        return
      }
    }
    let markedRows = try await downloadStore.markDeletingAsync(itemId: itemRowId, mediaKind: .audio)
    tracePurge(scope: .audio, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Resolves the server `itemID` to its internal row id and defers to `purgeItem(itemId:source:)`.
  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      try await purgeRSSFeed(feedId: feedId, source: source)
      return
    }
    guard let itemRowId = try await resolveItemRowId(itemID: itemID) else {
      tracePurge(scope: .item, source: source, rows: 0)
      return
    }
    try await purgeItem(itemId: itemRowId, source: source)
  }

  /// `source` decides what an in-flight row means. The reaper path (`activePlaybackExclusion`)
  /// claims only completed automatic rows inside its own transaction and needs no further guard.
  /// The ordinary path removes whatever it finds for an explicit source, cancelling a live
  /// transfer. An automatic source (the finished-download auto-delete) steps aside for any row
  /// still in flight, as for ABS rows: a transfer in flight means the user wants the file now.
  private func performPurgeRSSEpisodeDownload(
    feedId: Int64, episodeID: String, source: DownloadPurgeSource,
    activePlaybackExclusion: (@Sendable (Int64) -> Bool)? = nil
  ) async throws -> Bool {
    if let activePlaybackExclusion {
      guard let rssDownloadStore, let rssFileStore else { return false }
      // Phase one: recheck and claim, atomically. Both predicates are evaluated by the same
      // transaction that marks the row, so a promotion to manual or a playback start after
      // candidate selection is seen. A row that fails a recheck is left unchanged, so the next
      // pass can offer it again.
      let claimed = try await database.writeAsync { db -> RSSDownloadRecord? in
        guard
          let row = try RSSDownloadRecord.fetchOne(
            db,
            sql: """
              SELECT download.*
              FROM rssDownload AS download
              JOIN rssEpisode AS episode ON episode.id = download.episodeId
              WHERE episode.feedId = ? AND episode.identityKey = ?
              """,
            arguments: [feedId, episodeID]),
          row.id != nil,
          row.state == .completed,
          row.origin == .automatic,
          activePlaybackExclusion(row.episodeId) == false
        else { return nil }
        var marked = row
        marked.state = .deleting
        try marked.update(db)
        return marked
      }
      guard let claimed, let deletedDownloadID = claimed.id else { return false }

      // Phase two: the file, then the row, outside the transaction and in that order. Holding the
      // SQLite write lock across file I/O would serialise every writer behind a delete, and
      // removing the file inside the transaction would let a crash before commit leave a
      // `completed` row pointing at a missing file. `RSSDownloadIntegritySweep` finishes an
      // interrupted purge at launch from the `deleting` marker.
      let destination = try rssFileStore.transferDestinationURL(forRelativePath: claimed.relativePath)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try await rssDownloadStore.finalizeDeletionAsync(downloadId: deletedDownloadID)
      rssLiveTaskOwnedDownloadIds.remove(deletedDownloadID)
      rssSuspendedTaskDownloadIds.remove(deletedDownloadID)
      return true
    }

    guard let rssDownloadStore, let row = try await rssDownload(feedId: feedId, episodeID: episodeID), let id = row.id
    else { return false }
    if source.isAutomatic, Self.isInFlight(row.state) {
      return false
    }
    if row.state != .deleting {
      _ = try await rssDownloadStore.transitionAsync(downloadId: id, to: .deleting)
    }
    // A paused row still owns its suspended adapter task; see `performCancel`.
    if row.state == .downloading || rssLiveTaskOwnedDownloadIds.contains(id)
      || rssSuspendedTaskDownloadIds.contains(id)
    {
      await backgroundTransferring.cancel(identity: .rss(rowID: id))
    }
    rssLiveTaskOwnedDownloadIds.remove(id)
    rssSuspendedTaskDownloadIds.remove(id)
    try rssFileStore?.delete(downloadId: id)
    return true
  }

  // MARK: - Item and feed purge

  /// Purges every surviving download row of one item; `source` is the bounded caller label for the
  /// device trace. Ordering matters: first transactionally mark all rows `.deleting`
  /// (`DownloadStore.markDeleting(itemId:)`), making the item non-playable and non-schedulable at
  /// once; then cancel transfers (every marked row for account removal, otherwise only
  /// `.downloading` ones); then the idempotent file-delete/row-delete protocol finishes each row.
  /// A crash after the mark resumes from `.deleting` via `DownloadIntegritySweep` on next launch.
  public func purgeItem(itemId: Int64, source: DownloadPurgeSource) async throws {
    if source.isAutomatic {
      let rows = try await downloadStore.fetchDownloadsAsync(itemId: itemId)
      guard Self.hasWorkInFlight(rows) == false else {
        tracePurge(scope: .item, source: source, rows: 0)
        return
      }
    }
    let markedRows = try await downloadStore.markDeletingAsync(itemId: itemId)
    tracePurge(scope: .item, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Device-owned RSS item purge for the AppModel item actions. The RSS feed id is the item id at
  /// this boundary, so no account-owned item lookup is needed.
  public func purgeRSSFeed(feedId: Int64, source: DownloadPurgeSource) async throws {
    let didPurge = try await onChain { [self] in
      try await self.performPurgeRSSFeed(feedId: feedId, source: source)
    }
    if didPurge { await schedule() }
  }

  private func performPurgeRSSFeed(feedId: Int64, source: DownloadPurgeSource) async throws -> Bool {
    guard let rssDownloadStore else { return false }
    let episodeStore = RSSEpisodeStore(database: database)
    var didPurge = false
    for row in try await rssDownloadStore.fetchAllAsync() {
      guard let episode = try await episodeStore.fetchEpisode(episodeId: row.episodeId),
        episode.feedId == feedId
      else { continue }
      didPurge =
        try await performPurgeRSSEpisodeDownload(
          feedId: feedId, episodeID: episode.identityKey, source: source) || didPurge
    }
    return didPurge
  }

  /// A transferring download means the user wants the file now, so an automatic purge steps aside
  /// for the whole item (marking an item finished mid-download would otherwise cancel the live
  /// transfer). User-initiated purges are unaffected. Item-wide because a multi-file book is one
  /// unit of intent: a completed file is not swept from under a transferring sibling.
  ///
  /// Item media only: a supplement PDF held for Wi-Fi would keep a finished audiobook on disk
  /// indefinitely; the purge removes it with everything else.
  private static func hasWorkInFlight(_ rows: [DownloadRecord]) -> Bool {
    rows.contains { $0.mediaKind.isItemMedia && isInFlight($0.state) }
  }

  /// Shared by both download tables: `RSSDownloadRecord` mirrors `DownloadRecord`'s states.
  private static func isInFlight(_ state: DownloadState) -> Bool {
    switch state {
    case .pending, .downloading, .paused, .pausedAuth, .interrupted: return true
    case .completed, .failed, .deleting: return false
    }
  }

  // MARK: - Sweeps and account removal

  /// Reclaims downloads whose podcast episode was soft-deleted; otherwise only purging the whole
  /// show frees them, since the show screen stops listing a tombstoned episode.
  ///
  /// Explicit, not automatic: soft-delete is a reversible sync inference, so
  /// `DownloadIntegritySweep` must not turn it into a file deletion on next launch (see
  /// `DownloadStore.tombstonedEpisodeDownloads`). Same mark, cancel, delete ordering as
  /// `purgeItem`, per episode, so siblings are untouched and a crash resumes from `.deleting`.
  public func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {
    if rssDownloadStore != nil {
      let marked = try await downloadStore.markTombstonedIncludingRSSAsync()
      tracePurge(
        scope: .tombstoned, source: source, rows: marked.abs.count + marked.rss.count)
      await finishPurge(marked.abs, source: source, scheduleAtEnd: false)
      try await finishRSSPurge(marked.rss)
      await schedule()
      return
    }
    let stranded = try await downloadStore.tombstonedEpisodeDownloadsAsync()
    var markedRows: [DownloadRecord] = []
    for row in stranded {
      guard let episodeRowId = row.podcastEpisodeId else { continue }
      markedRows += try await downloadStore.markDeletingAsync(
        itemId: row.itemId, podcastEpisodeId: episodeRowId)
    }
    tracePurge(scope: .tombstoned, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Closes this coordinator to new work ahead of `purgeAllDownloads(source: .accountRemoval)`.
  /// `AccountRemovalCoordinator` calls it at its `.intentsStopped` boundary so a download
  /// requested between "stop accepting intents" and the purge cannot survive as a background
  /// transfer still authorised for the account being removed. One-way: the rebuilt environment
  /// composes a new coordinator.
  public func beginAccountRemoval() {
    isRemovingAccount = true
  }

  /// Purges every download row across every item. Same ordering as `purgeItem(itemId:source:)`,
  /// applied to the whole table in one transaction.
  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    // RSS is device-owned and must survive account removal. Storage's explicit Delete All is the
    // one cross-source purge. Mark both tables before any cancellation or file I/O so scheduling
    // cannot see a pending RSS row in the gap between the ABS and RSS halves.
    if source == .storage, rssDownloadStore != nil {
      let marked = try await downloadStore.markAllDeletingIncludingRSSAsync()
      tracePurge(scope: .all, source: source, rows: marked.abs.count + marked.rss.count)
      await finishPurge(marked.abs, source: source, scheduleAtEnd: false)
      try await finishRSSPurge(marked.rss)
      await schedule()
      return
    }
    let markedRows = try await downloadStore.markAllDeletingAsync()
    tracePurge(scope: .all, source: source, rows: markedRows.count)
    await finishPurge(markedRows, source: source)
  }

  /// Shared second half of both purge entry points. `rows` are the pre-mark snapshots
  /// `DownloadStore`'s bulk mark methods return, so `row.state` is what each row was doing before
  /// it was marked `.deleting`. Account removal cancels every marked row; other sources cancel
  /// only live transfers.
  private func finishPurge(
    _ rows: [DownloadRecord], source: DownloadPurgeSource, scheduleAtEnd: Bool = true
  ) async {
    for row in rows {
      guard let downloadId = row.id else { continue }
      authRetriedDownloadIds.remove(downloadId)
      // A held or paused row can still own a suspended adapter task that outlives its row.
      let ownsTask =
        liveTaskOwnedDownloadIds.contains(downloadId) || suspendedTaskDownloadIds.contains(downloadId)
      if source == .accountRemoval || row.state == .downloading || ownsTask {
        await backgroundTransferring.cancel(identity: .abs(rowID: downloadId))
      }
      liveTaskOwnedDownloadIds.remove(downloadId)
      suspendedTaskDownloadIds.remove(downloadId)
    }
    for row in rows {
      guard let downloadId = row.id else { continue }
      try? downloadFileStore.delete(downloadId: downloadId)
    }
    if scheduleAtEnd { await schedule() }
  }

  private func finishRSSPurge(_ rows: [RSSDownloadRecord]) async throws {
    for row in rows {
      guard let downloadId = row.id else { continue }
      let ownsTask =
        rssLiveTaskOwnedDownloadIds.contains(downloadId)
        || rssSuspendedTaskDownloadIds.contains(downloadId)
      rssLiveTaskOwnedDownloadIds.remove(downloadId)
      rssSuspendedTaskDownloadIds.remove(downloadId)
      if row.state == .downloading || ownsTask {
        await backgroundTransferring.cancel(identity: .rss(rowID: downloadId))
      }
      try rssFileStore?.delete(downloadId: downloadId)
    }
  }
}
