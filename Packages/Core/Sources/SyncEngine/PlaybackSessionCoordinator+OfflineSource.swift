import Foundation
import Persistence

extension PlaybackSessionCoordinator {
  // MARK: - Offline source resolution

  /// What `resolveSource` decided for one `startSession` call: play the item as a complete local
  /// session (rule 10), or fall through to the ordinary online `/play` flow.
  /// `wasDemotedFromCompleteLocal` separates an item never (or only partly) downloaded from one
  /// the integrity sweep found missing under a previously `completed` set of rows. Only
  /// `performStart`'s catch clause uses the distinction.
  enum SourceResolution {
    case local(LocalSourceMaterial)
    case streaming(wasDemotedFromCompleteLocal: Bool)
  }

  /// Everything a fresh or resumed local `PreparedPlayback` needs, built from the download store's
  /// persisted order/duration, never from `ItemDetail` or a network call.
  struct LocalSourceMaterial {
    let tracks: [PreparedPlaybackTrack]
    let duration: Double
    let chapters: [PreparedPlaybackChapter]
  }

  /// Decides whether `itemID` plays as a complete local session or streams. Runs the
  /// selected-item integrity validation first so a file that vanished under a `completed` row is
  /// never trusted. Reads every download row directly, not `DownloadStore.aggregate`, which
  /// excludes `deleting` rows and would misreport a row mid-removal as complete. A `deleting` row
  /// (a concurrent purge) fails closed rather than falling back silently.
  func resolveSource(
    accountId: Int64, itemID: String, itemRowId: Int64, episodeRowId: Int64?
  ) async throws -> SourceResolution {
    guard let downloadStore, let downloadFileStore else {
      return .streaming(wasDemotedFromCompleteLocal: false)
    }

    // Checked before the sweep: a row already `deleting` means a purge is mid-removal for this
    // item. The sweep would finish that removal (it resumes any `deleting` row) and leave only
    // the remaining rows, which could misreport as complete if every other file is downloaded.
    // Fail closed on the mid-removal state itself, ahead of the sweep resolving it.
    let rowsBeforeSweep = try await downloadStore.fetchDownloadsAsync(itemId: itemRowId)
      .filter { $0.podcastEpisodeId == episodeRowId && $0.mediaKind == .audio }
    guard rowsBeforeSweep.isEmpty == false else {
      return .streaming(wasDemotedFromCompleteLocal: false)
    }
    if rowsBeforeSweep.contains(where: { $0.state == .deleting }) {
      throw PlaybackCoordinatorError.localSourceUnavailable(itemID: itemID)
    }

    // Validate only this item on the latency-sensitive playback path. The full tree/orphan sweep
    // remains launch maintenance and is already detached at utility priority.
    _ = try? DownloadIntegritySweep(
      rootURL: downloadFileStore.rootURL, downloadStore: downloadStore
    ).validate(itemID: itemRowId)

    let rows = try await downloadStore.fetchDownloadsAsync(itemId: itemRowId)
      .filter { $0.podcastEpisodeId == episodeRowId && $0.mediaKind == .audio }
    guard rows.isEmpty == false else {
      return .streaming(wasDemotedFromCompleteLocal: false)
    }
    if rows.contains(where: { $0.state == .deleting }) {
      throw PlaybackCoordinatorError.localSourceUnavailable(itemID: itemID)
    }
    guard rows.allSatisfy({ $0.state == .completed }) else {
      // `.storage` is the category `DownloadIntegritySweep` stamps when it demotes a previously
      // `completed` row whose file went missing, never one an ordinary unfinished download carries.
      let wasDemoted = rows.contains { $0.state == .failed && $0.errorCategory == .storage }
      return .streaming(wasDemotedFromCompleteLocal: wasDemoted)
    }

    let ordered = rows.sorted { $0.orderIndex < $1.orderIndex }
    var tracks: [PreparedPlaybackTrack] = []
    tracks.reserveCapacity(ordered.count)
    var cursor: Double = 0
    for row in ordered {
      let url = downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
      tracks.append(
        PreparedPlaybackTrack(
          index: row.orderIndex, startOffset: cursor, duration: row.fileDurationSeconds, url: url,
          mimeType: row.expectedMimeType, title: nil))
      cursor += row.fileDurationSeconds
    }
    // An episode's chapters live on its own rows; `itemChapter` is the book snapshot and holds
    // nothing for a podcast item.
    let storedChapters: [StoredItemChapter]
    if let episodeRowId {
      storedChapters = try await podcastEpisodeChapterStore.fetchAsync(
        accountId: accountId, podcastEpisodeId: episodeRowId)
    } else {
      storedChapters = try await itemChapterStore.fetchAsync(accountId: accountId, itemId: itemRowId)
    }
    let chapters =
      storedChapters
      .map {
        PreparedPlaybackChapter(
          id: $0.serverChapterId,
          start: $0.start,
          end: $0.end,
          title: $0.title)
      }
    return .local(
      LocalSourceMaterial(tracks: tracks, duration: cursor, chapters: chapters))
  }

  /// Starts a brand-new local session row (no active offline session for this item): fresh client
  /// UUID, wall-clock `startedAt`, `isOffline == true`. Start position is this device's last
  /// known progress for the item, with no server observation to merge as `resolveStartPosition`
  /// does for an online start.
  func startFreshLocalSession(
    accountId: Int64, itemID: String, itemRowId: Int64, episodeID: String?,
    episodeRowId: Int64?, material: LocalSourceMaterial
  ) async throws -> PreparedPlayback {
    let startedAt = clock.now()
    let started = try await sessionStore.startSessionAsync(
      accountId: accountId,
      clientSessionId: generateClientSessionID(),
      itemId: itemRowId,
      podcastEpisodeId: episodeRowId,
      duration: material.duration,
      startedAt: startedAt,
      isOffline: true
    )
    guard let sessionId = started.id else {
      throw PlaybackCoordinatorError.persistenceFailed
    }
    let startPosition =
      (try? await mediaProgressDAO.fetchCurrentAsync(
        accountId: accountId,
        identity: Self.progressIdentity(
          itemRowId: itemRowId, episodeRowId: episodeRowId)))?.currentTime ?? 0
    // Frozen onto the row: the only record of where the session began, and its `local-all`
    // upload is the only thing that tells the server.
    _ = try? await sessionStore.setStartPositionAsync(sessionId: sessionId, startPosition: startPosition)
    let prepared = PreparedPlayback(
      itemID: itemID, episodeID: episodeID, startPosition: startPosition, duration: material.duration,
      tracks: material.tracks, chapters: material.chapters, source: .local)
    preparedBySessionID[sessionId] = prepared
    return prepared
  }
}
