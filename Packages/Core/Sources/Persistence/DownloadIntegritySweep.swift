import Foundation

/// What one `DownloadIntegritySweep.run()` pass did, for diagnostics/tests. Ids and paths are
/// sorted for deterministic comparison; the sweep itself has no ordering requirement.
public struct DownloadIntegritySweepResult: Sendable, Equatable {
  public let failedMissingFileDownloadIds: [Int64]
  public let finishedDeletionDownloadIds: [Int64]
  public let removedOrphanRelativePaths: [String]
}

/// Reconciles the `download` table against the downloads directory. Every pass re-derives its
/// answer from the current rows and file tree (no tracked manifest), so it is safe on every
/// launch. Playback source resolution uses the scoped `validate(itemID:)` variant instead.
///
/// - A `deleting` row (crash-interrupted at either boundary of the deletion protocol) finishes
///   deletion: file removed if present, then the row.
/// - A `completed` row whose file went missing (not via `DownloadFileStore`'s deletion protocol)
///   is demoted to `failed`/redownloadable, never handed to playback.
/// - A file that no row's `destinationRelativePath` points at is an orphan and is deleted.
///
/// A download whose podcast episode is soft-deleted is none of these: its row survives (a soft
/// delete cascades nothing), so its path stays in `keepRelativePaths` and its file is kept. See
/// `DownloadStore.tombstonedEpisodeDownloads` for why a reversible sync inference must never
/// delete files here, and `DownloadCoordinator.purgeTombstonedEpisodeDownloads` for the explicit
/// intent that reclaims them.
public struct DownloadIntegritySweep: Sendable {
  private let rootURL: URL
  private let downloadStore: DownloadStore
  private let beforeOrphanRemoval: (@Sendable () throws -> Void)?

  public init(rootURL: URL, downloadStore: DownloadStore) {
    self.rootURL = rootURL
    self.downloadStore = downloadStore
    beforeOrphanRemoval = nil
  }

  /// Test-only seam for placing a committed download between the row snapshot and orphan walk.
  /// Production construction uses the public initializer above.
  init(
    rootURL: URL,
    downloadStore: DownloadStore,
    beforeOrphanRemoval: @escaping @Sendable () throws -> Void
  ) {
    self.rootURL = rootURL
    self.downloadStore = downloadStore
    self.beforeOrphanRemoval = beforeOrphanRemoval
  }

  @discardableResult
  public func run() throws -> DownloadIntegritySweepResult {
    let reconciliation = try reconcile(rows: downloadStore.fetchAll())
    let keepRelativePaths = Set(reconciliation.remainingRows.map(\.destinationRelativePath))
    try beforeOrphanRemoval?()
    let orphanCandidates = try collectOrphanFiles(keeping: keepRelativePaths)
    // Re-reading the rows after the walk keeps orphan removal safe if `run()` gains suspension
    // points.
    let refreshedKeepRelativePaths = Set(
      try downloadStore.fetchAll().map(\.destinationRelativePath))
    let removedOrphans = try removeOrphanFiles(
      candidates: orphanCandidates, keeping: refreshedKeepRelativePaths)

    return DownloadIntegritySweepResult(
      failedMissingFileDownloadIds: reconciliation.failedMissingFileIds.sorted(),
      finishedDeletionDownloadIds: reconciliation.finishedDeletionIds.sorted(),
      removedOrphanRelativePaths: removedOrphans.sorted())
  }

  /// Validates only one item's rows. Unlike `run()`, it never enumerates the downloads tree, so it
  /// cannot repair or remove anything belonging to another item.
  @discardableResult
  public func validate(itemID: Int64) throws -> DownloadIntegritySweepResult {
    let reconciliation = try reconcile(rows: downloadStore.fetchDownloads(itemId: itemID))
    return DownloadIntegritySweepResult(
      failedMissingFileDownloadIds: reconciliation.failedMissingFileIds.sorted(),
      finishedDeletionDownloadIds: reconciliation.finishedDeletionIds.sorted(),
      removedOrphanRelativePaths: [])
  }

  private func reconcile(rows inputRows: [DownloadRecord]) throws -> (
    finishedDeletionIds: [Int64],
    failedMissingFileIds: [Int64],
    remainingRows: [DownloadRecord]
  ) {
    var rows = inputRows
    var finishedDeletionIds: [Int64] = []
    var failedMissingFileIds: [Int64] = []

    for row in rows where row.state == .deleting {
      guard let id = row.id else { continue }
      try removeFileIfPresent(relativePath: row.destinationRelativePath)
      try downloadStore.finalizeDeletion(downloadId: id)
      finishedDeletionIds.append(id)
    }
    let finishedIdSet = Set(finishedDeletionIds)
    rows.removeAll { row in row.id.map(finishedIdSet.contains) ?? false }

    for row in rows where row.state == .completed {
      guard let id = row.id else { continue }
      let url = rootURL.appendingPathComponent(row.destinationRelativePath)
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let ebookSizeMatches: Bool
      if row.mediaKind != .audio, fileExists {
        let actualSize =
          try FileManager.default.attributesOfItem(atPath: url.path)[.size]
          as? NSNumber
        ebookSizeMatches = actualSize?.int64Value == row.expectedBytes
      } else {
        // Audio is existence-only here: its completion path already validates the final size.
        // Size is checked at launch for EPUB rows and supplement PDFs, whose planning refuses an
        // unknown expected size.
        ebookSizeMatches = true
      }
      if fileExists == false || ebookSizeMatches == false {
        _ = try downloadStore.transition(downloadId: id, to: .failed, errorCategory: .storage)
        failedMissingFileIds.append(id)
      }
    }

    return (finishedDeletionIds, failedMissingFileIds, rows)
  }

  private func removeFileIfPresent(relativePath: String) throws {
    guard StoragePath.isContained(relativePath: relativePath, under: rootURL) else { return }
    let url = rootURL.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// Walks every ABS-owned regular file under the root and collects any whose path (relative to
  /// the root) is not in `keeping`. The sibling RSS store owns the whole `RSS/` subtree, so this
  /// sweep must not inspect it.
  private func collectOrphanFiles(keeping: Set<String>) throws -> [String] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
      return []
    }

    var candidates: [String] = []
    let rssRootPath =
      rootURL.appendingPathComponent(RSSFileRoot.directoryName, isDirectory: true)
      .standardizedFileURL.path
    let rssPathPrefix = rssRootPath.hasSuffix("/") ? rssRootPath : rssRootPath + "/"
    for case let fileURL as URL in enumerator {
      let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
      let filePath = fileURL.standardizedFileURL.path
      if filePath == rssRootPath {
        enumerator.skipDescendants()
        continue
      }
      if filePath.hasPrefix(rssPathPrefix) {
        continue
      }
      guard resourceValues.isRegularFile == true else { continue }
      guard let relativePath = StoragePath.relativePath(of: fileURL, under: rootURL) else {
        continue
      }

      if keeping.contains(relativePath) == false {
        candidates.append(relativePath)
      }
    }
    return candidates
  }

  private func removeOrphanFiles(candidates: [String], keeping: Set<String>) throws -> [String] {
    var removed: [String] = []
    for relativePath in candidates where keeping.contains(relativePath) == false {
      try FileManager.default.removeItem(at: rootURL.appendingPathComponent(relativePath))
      removed.append(relativePath)
    }
    return removed
  }
}
