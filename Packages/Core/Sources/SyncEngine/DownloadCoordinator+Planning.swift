import ABSApi
import Foundation
import Persistence

/// Errors `DownloadCoordinator.requestDownload` raises.
public enum DownloadPlanningError: Error, Sendable, Equatable {
  case notAuthenticated
  /// Account removal has begun (`DownloadCoordinator.beginAccountRemoval()`). Terminal for this
  /// account rather than retryable: no later request against it can succeed.
  case accountRemovalInProgress
  case unknownItem(String)
  case unknownPodcastEpisode(itemID: String, episodeID: String)
  case episodeUnavailable
  /// An item-level request against a podcast item's episodes.
  case podcastEpisodesUnsupported
  /// An empty catalog or any nonzero `invalidEntryCount`: the whole plan is rejected, never a
  /// partial set of rows.
  case metadataValidationFailed
}

/// Refusals specific to the ebook planning path. Separate from `DownloadPlanningError` so a caller
/// can tell an advertised-but-unavailable file, an unsupported extension and a missing size apart.
public enum EbookDownloadPlanningError: Error, Sendable, Equatable {
  case ebookFileUnavailable
  case unsupportedEbookFormat
  case missingExpectedSize
}

extension DownloadCoordinator {
  private struct DownloadEnqueueRequest: Sendable {
    let serverFileIno: String
    let orderIndex: Int
    let expectedBytes: Int64
    let expectedMimeType: String
    let fileDurationSeconds: Double
  }

  // MARK: - Planning

  /// Requests every audio file of `itemID` for download (API-CONVENTIONS.md rule 15: one expanded
  /// item-detail fetch, never per file). Idempotent for audio: any surviving audio row means the
  /// item is planned; an ebook row does not count. Rejects the whole plan, inserting no rows, on an
  /// empty catalog or nonzero `invalidEntryCount`. Whole-show podcast requests are rejected:
  /// podcasts plan per episode via `requestEpisodeDownload`.
  public func requestDownload(itemID: String) async throws {
    guard isRemovingAccount == false else {
      throw DownloadPlanningError.accountRemovalInProgress
    }
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw DownloadPlanningError.notAuthenticated
    }
    let account = try tokenAccount(for: accountRecord)
    guard let itemRow = try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else {
      throw DownloadPlanningError.unknownItem(itemID)
    }
    // Rejected from local state before the fetch: an item-level request against a show can never
    // succeed, so an expanded item-detail request would be wasted. The cached media kind is the
    // same signal the response would carry.
    let category = ItemMediaCategory.derive(
      mediaKind: itemRow.mediaKind, numAudioFiles: itemRow.numAudioFiles,
      ebookFormat: itemRow.ebookFormat)
    guard category != .podcast else {
      throw DownloadPlanningError.podcastEpisodesUnsupported
    }

    let existingRows = (try? await downloadStore.fetchDownloadsAsync(itemId: itemRowId)) ?? []
    // An EPUB row is a separate medium and must not make an audio request look already planned.
    guard existingRows.contains(where: { $0.mediaKind == .audio }) == false else { return }

    let detail = try await client.fetchItemDetail(account: account, itemID: itemID)

    guard let media = detail.media else {
      await recordDownloadDiagnostic(accountId: accountId, statusClass: .clientError)
      throw DownloadPlanningError.metadataValidationFailed
    }
    guard case .book(let book) = media else {
      throw DownloadPlanningError.podcastEpisodesUnsupported
    }

    let catalog = book.audioFiles
    guard catalog.invalidEntryCount == 0, catalog.files.isEmpty == false else {
      await recordDownloadDiagnostic(accountId: accountId, statusClass: .clientError)
      throw DownloadPlanningError.metadataValidationFailed
    }

    // Sorted by index before insertion: `schedule()`'s FIFO ordering comes from row-insertion
    // order (`DownloadRecord.id`), so this keeps file order within an item.
    try await enqueueDownloads(
      accountId: accountId,
      itemId: itemRowId,
      podcastEpisodeId: nil,
      origin: .manual,
      mediaKind: .audio,
      requests: catalog.files.sorted(by: { $0.index < $1.index }).map { file in
        DownloadEnqueueRequest(
          serverFileIno: file.ino,
          orderIndex: file.index,
          expectedBytes: Int64(file.expectedSize),
          expectedMimeType: file.mimeType,
          fileDurationSeconds: file.duration)
      },
      // Chapters are persisted before scheduling.
      scheduleAfterEnqueue: false)
    try await itemChapterStore.replaceAsync(
      accountId: accountId,
      itemId: itemRowId,
      chapters: storedItemChapters(from: book.chapters, duration: book.duration))
    await enqueueSupplements(
      book.supplements, detail: detail, accountId: accountId, itemRowId: itemRowId, itemID: itemID)
    await schedule()
  }

  /// The PDFs that ride along with an audiobook download, enqueued after the audio rows so FIFO
  /// scheduling fetches the book first. Planned from the same expanded response (rule 15) and
  /// best-effort: a supplement must not fail the audio plan, which has already committed.
  private func enqueueSupplements(
    _ supplements: [SupplementFileInfo], detail: ItemDetail, accountId: Int64, itemRowId: Int64,
    itemID: String
  ) async {
    guard supplements.isEmpty == false else { return }
    // The viewer reads the stored set, so a book downloaded straight from a list still shows its
    // PDF without a detail visit first.
    await expandedItemPersistor.persist(
      ExpandedItemPersistor.persistable(from: detail),
      accountId: accountId,
      serverItemId: itemID,
      fetchedAt: Date())
    for (position, file) in supplements.enumerated() {
      do {
        try await enqueueDownloads(
          accountId: accountId,
          itemId: itemRowId,
          podcastEpisodeId: nil,
          origin: .manual,
          mediaKind: .supplement,
          requests: [Self.supplementRequest(file, position: position)],
          scheduleAfterEnqueue: false)
      } catch {
        // `duplicateDownload` is a row that already exists; anything else leaves the PDF to be
        // planned on first view.
        continue
      }
    }
  }

  /// Plans one supplement PDF on its own, for viewing a PDF whose audiobook is not downloaded or
  /// was downloaded before supplements existed. Idempotent over a live row for the same file; a
  /// failed row is retried in place. Uses the stored description, so no network request is made
  /// unless a row must be created.
  public func requestSupplementDownload(itemID: String, fileIno: String) async throws {
    guard isRemovingAccount == false else {
      throw DownloadPlanningError.accountRemovalInProgress
    }
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw DownloadPlanningError.notAuthenticated
    }
    guard let itemRow = try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else {
      throw DownloadPlanningError.unknownItem(itemID)
    }

    let existingRows = (try? await downloadStore.fetchDownloadsAsync(itemId: itemRowId)) ?? []
    if let existing = existingRows.first(where: {
      $0.mediaKind == .supplement && $0.serverFileIno == fileIno && $0.podcastEpisodeId == nil
    }) {
      switch existing.state {
      case .failed, .paused, .interrupted:
        if let downloadId = existing.id { try await resumeDownload(downloadId: downloadId) }
      case .completed:
        // A completed row whose file vanished is demoted by the integrity sweep; run it for this
        // item so the next view can replan rather than reporting ready forever.
        _ = try? DownloadIntegritySweep(
          rootURL: downloadFileStore.rootURL, downloadStore: downloadStore
        ).validate(itemID: itemRowId)
        if let refreshed = try? await downloadStore.fetchDownloadsAsync(itemId: itemRowId)
          .first(where: { $0.id == existing.id }), refreshed.state == .failed,
          let downloadId = refreshed.id
        {
          try await resumeDownload(downloadId: downloadId)
        }
      case .pending, .downloading, .pausedAuth, .deleting:
        break
      }
      return
    }

    let stored = try await supplementStore.fetchStored(accountId: accountId, itemId: itemRowId)
    guard let file = stored.first(where: { $0.serverFileIno == fileIno }), file.sizeBytes > 0 else {
      throw DownloadPlanningError.metadataValidationFailed
    }
    do {
      try await enqueueDownloads(
        accountId: accountId,
        itemId: itemRowId,
        podcastEpisodeId: nil,
        origin: .manual,
        mediaKind: .supplement,
        requests: [
          Self.supplementRequest(
            SupplementFileInfo(ino: file.serverFileIno, filename: file.filename, size: Int(file.sizeBytes)),
            position: file.position)
        ])
    } catch let error as DownloadStoreError {
      // A concurrent request won the unique index; it schedules.
      guard case .duplicateDownload = error else { throw error }
    }
  }

  /// The file route's `Content-Type` for a PDF. Completion quarantines any other base MIME, so
  /// this must match what the server sends.
  static let supplementMimeType = "application/pdf"

  private static func supplementRequest(
    _ file: SupplementFileInfo, position: Int
  ) -> DownloadEnqueueRequest {
    DownloadEnqueueRequest(
      serverFileIno: file.ino,
      orderIndex: position,
      expectedBytes: Int64(file.size),
      expectedMimeType: supplementMimeType,
      fileDurationSeconds: 0)
  }

  /// Requests the one primary EPUB file for `itemID`. Unlike `requestDownload`, needs no expanded
  /// audio catalog (an ebook-only item has no audio). The persisted ebook identity is the action
  /// gate and row identity; the expanded detail fetch supplies the expected byte count the
  /// authorised request and completion contract need.
  ///
  /// Idempotent per medium: a surviving ebook row suppresses a repeat request; an audio row for
  /// the item neither suppresses nor is changed by it. The ordinary scheduler applies the
  /// two-transfer and cellular policy.
  public func requestEbookDownload(itemID: String) async throws {
    guard isRemovingAccount == false else {
      throw DownloadPlanningError.accountRemovalInProgress
    }
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw DownloadPlanningError.notAuthenticated
    }
    guard let itemRow = try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else {
      throw DownloadPlanningError.unknownItem(itemID)
    }

    guard EbookFormatNormalizer.normalize(itemRow.ebookFormat) == "epub" else {
      throw EbookDownloadPlanningError.unsupportedEbookFormat
    }
    guard let ino = itemRow.ebookFileIno, ino.isEmpty == false else {
      // The list may advertise EPUB before expanded metadata has supplied a persisted file
      // identity. Do not fall back to the detail response's transient ino.
      throw EbookDownloadPlanningError.ebookFileUnavailable
    }
    guard EbookFormatNormalizer.normalize(itemRow.ebookFileExt) == "epub" else {
      throw EbookDownloadPlanningError.unsupportedEbookFormat
    }

    let existingRows = (try? await downloadStore.fetchDownloadsAsync(itemId: itemRowId)) ?? []
    guard existingRows.contains(where: { $0.mediaKind == .ebook }) == false else { return }

    let account = try tokenAccount(for: accountRecord)
    let detail = try await client.fetchItemDetail(account: account, itemID: itemID)
    guard case .book(let book) = detail.media, let ebookFile = book.ebookFile,
      ebookFile.ino.isEmpty == false
    else {
      throw EbookDownloadPlanningError.ebookFileUnavailable
    }
    guard EbookFormatNormalizer.normalize(ebookFile.ext) == "epub" else {
      throw EbookDownloadPlanningError.unsupportedEbookFormat
    }
    guard let expectedSize = ebookFile.size, expectedSize > 0 else {
      throw EbookDownloadPlanningError.missingExpectedSize
    }

    // A file replaced on the server keeps its item but gets a new inode and size at the next
    // library scan. This response is the authoritative shape the persistor writes from, so a
    // mismatch means the local copy is stale, not that the file is gone. Refusing would strand the
    // item, since nothing else rewrites `ebookFileIno` once a row has been expanded.
    if ebookFile.ino != ino {
      await expandedItemPersistor.persist(
        ExpandedItemPersistor.persistable(from: detail),
        accountId: accountId,
        serverItemId: itemID,
        fetchedAt: Date())
    }

    try await enqueueDownloads(
      accountId: accountId,
      itemId: itemRowId,
      podcastEpisodeId: nil,
      origin: .manual,
      mediaKind: .ebook,
      requests: [
        DownloadEnqueueRequest(
          serverFileIno: ebookFile.ino,
          orderIndex: 0,
          expectedBytes: Int64(expectedSize),
          expectedMimeType: EbookRequest.acceptedMIMETypes[0],
          fileDurationSeconds: 0)
      ])
  }

  /// Plans the single stored audio file for one cached podcast episode. The expanded podcast
  /// refresh already validated and persisted the locator/size/MIME/duration tuple, so this never
  /// refetches item detail or falls back to feed enclosure metadata. Always plans `.manual`: only
  /// this actor's internal `requestAutomaticEpisodeDownload` may request `.automatic`, never
  /// anything reachable from AppModel or the UI.
  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await planEpisodeDownload(itemID: itemID, episodeID: episodeID, origin: .manual)
  }

  /// The automatic-download pass's sole entry point into episode planning
  /// (`AutomaticEpisodeDownloadPlanning`). Shares every rule of `requestEpisodeDownload`
  /// (cached audio identity only, idempotent, not part of `DownloadIntents` so unreachable from
  /// AppModel or the UI); only the origin stamped on a new row differs.
  public func requestAutomaticEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await planEpisodeDownload(itemID: itemID, episodeID: episodeID, origin: .automatic)
  }

  private func planRSSEpisodeDownload(
    itemID: String, feedId: Int64, episodeID: String, origin: DownloadOrigin
  ) async throws {
    guard isRemovingAccount == false else { throw DownloadPlanningError.accountRemovalInProgress }
    guard (try? await accountDAO.fetchAsync()) != nil else { throw DownloadPlanningError.notAuthenticated }
    guard let rssDownloadStore,
      let episode = try await RSSEpisodeStore(database: database).fetchEpisode(feedId: feedId, identityKey: episodeID),
      episode.id != nil
    else { throw DownloadPlanningError.unknownPodcastEpisode(itemID: itemID, episodeID: episodeID) }
    let existing = try await rssDownloadStore.fetchAsync(episodeId: episode.id!)
    if let existing {
      if origin == .manual, existing.origin == .automatic, let id = existing.id {
        // RSS has the same one-way automatic -> manual promotion as ABS.
        _ = try? await rssDownloadStore.promoteToManualAsync(downloadId: id)
      }
      return
    }
    _ = try await rssDownloadStore.claimOrCreateAsync(episodeId: episode.id!, origin: origin)
    await schedule()
  }

  /// Shared by `requestEpisodeDownload` (`.manual`) and `requestAutomaticEpisodeDownload`
  /// (`.automatic`). Idempotent per `(item, episode)`. The only origin-aware behaviour is one-way
  /// promotion: a `.manual` request against an episode with a surviving `.automatic` row promotes
  /// it to `.manual`, taking it out of the automatic-download reaper's reach. Nothing else changes
  /// an existing row's origin.
  private func planEpisodeDownload(
    itemID: String, episodeID: String, origin: DownloadOrigin
  ) async throws {
    // Source dispatch belongs here, but the authenticated transfer paths remain separate:
    // RSS uses its feed store and ABS uses the account-owned download store.
    if let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      try await planRSSEpisodeDownload(
        itemID: itemID, feedId: feedId, episodeID: episodeID, origin: origin)
      return
    }
    guard isRemovingAccount == false else {
      throw DownloadPlanningError.accountRemovalInProgress
    }
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw DownloadPlanningError.notAuthenticated
    }
    guard let itemRow = try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else {
      throw DownloadPlanningError.unknownItem(itemID)
    }
    guard
      let episode = try? await podcastEpisodeDAO.fetchOneAsync(
        itemId: itemRowId, serverEpisodeId: episodeID),
      episode.accountId == accountId,
      let episodeRowId = episode.id
    else {
      throw DownloadPlanningError.unknownPodcastEpisode(
        itemID: itemID, episodeID: episodeID)
    }

    let existingRows = try await downloadStore.fetchDownloadsAsync(
      itemId: itemRowId, podcastEpisodeId: episodeRowId)
    if let existing = existingRows.first {
      if origin == .manual, existing.origin == .automatic, let downloadId = existing.id {
        _ = try await downloadStore.promoteToManualAsync(downloadId: downloadId)
      }
      return
    }

    guard
      let ino = episode.storedAudioIno, ino.isEmpty == false,
      let expectedSize = episode.storedAudioExpectedSize, expectedSize > 0,
      let mimeType = episode.storedAudioMimeType, mimeType.isEmpty == false,
      let duration = episode.storedAudioDurationSeconds, duration.isFinite, duration > 0
    else {
      throw DownloadPlanningError.episodeUnavailable
    }

    do {
      try await enqueueDownloads(
        accountId: accountId,
        itemId: itemRowId,
        podcastEpisodeId: episodeRowId,
        origin: origin,
        mediaKind: .audio,
        requests: [
          DownloadEnqueueRequest(
            serverFileIno: ino,
            orderIndex: 0,
            expectedBytes: Int64(expectedSize),
            expectedMimeType: mimeType,
            fileDurationSeconds: duration)
        ])
    } catch let error as DownloadStoreError {
      // Store calls suspend, so the existence check and this insert are not one actor turn: a
      // second tap for the same episode can see no row and reach here too. The unique index is the
      // serialisation point, and coalescing onto the winner repeats what the existence check
      // would have done, including `.automatic` → `.manual` promotion. The winner schedules, so
      // this loser does not.
      guard case .duplicateDownload = error else { throw error }
      guard origin == .manual else { return }
      let rows = try await downloadStore.fetchDownloadsAsync(
        itemId: itemRowId, podcastEpisodeId: episodeRowId)
      if let existing = rows.first, existing.origin == .automatic, let downloadId = existing.id {
        _ = try await downloadStore.promoteToManualAsync(downloadId: downloadId)
      }
      return
    }
  }

  // MARK: - Helpers

  private func enqueueDownloads(
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64?,
    origin: DownloadOrigin,
    mediaKind: DownloadMediaKind,
    requests: [DownloadEnqueueRequest],
    scheduleAfterEnqueue: Bool = true
  ) async throws {
    for request in requests {
      let relativePath = DownloadFileStore.destinationRelativePath(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        orderIndex: request.orderIndex,
        serverFileIno: request.serverFileIno,
        mimeType: request.expectedMimeType)
      _ = try await downloadStore.enqueueAsync(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        serverFileIno: request.serverFileIno,
        orderIndex: request.orderIndex,
        destinationRelativePath: relativePath,
        expectedBytes: request.expectedBytes,
        expectedMimeType: request.expectedMimeType,
        fileDurationSeconds: request.fileDurationSeconds,
        origin: origin,
        mediaKind: mediaKind)
    }
    if scheduleAfterEnqueue {
      await schedule()
    }
  }

}
