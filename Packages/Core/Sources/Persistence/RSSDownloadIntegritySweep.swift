import Foundation

/// The RSS half of launch integrity reconciliation. It walks only the shared
/// downloads root's `RSS/` child: an RSS orphan can never cause an ABS account file to be removed,
/// and a numeric RSS row id can never be looked up in the ABS `download` table.
public struct RSSDownloadIntegritySweep: Sendable {
  private let rootURL: URL
  private let downloadStore: RSSDownloadStore

  public init(rootURL: URL, downloadStore: RSSDownloadStore) {
    self.rootURL = rootURL
    self.downloadStore = downloadStore
  }

  @discardableResult
  public func run() throws -> DownloadIntegritySweepResult {
    var rows = try downloadStore.fetchAll()
    var failed: [Int64] = []
    var finished: [Int64] = []

    for row in rows where row.state == .deleting {
      guard let id = row.id else { continue }
      try removeFileIfSafe(relativePath: row.relativePath)
      try downloadStore.finalizeDeletion(downloadId: id)
      finished.append(id)
    }
    let finishedSet = Set(finished)
    rows.removeAll { $0.id.map(finishedSet.contains) ?? false }

    for row in rows where row.state == .completed {
      if let id = try demoteIfFileInvalid(row) { failed.append(id) }
    }

    let keeping: Set<String> = Set(
      rows.compactMap { row in
        guard row.id.map({ failed.contains($0) }) != true else { return nil }
        return isSafeRSSPath(row.relativePath) ? row.relativePath : nil
      })
    let orphans = try collectOrphans(keeping: keeping)
    var removed: [String] = []
    for relativePath in orphans {
      // Re-read just before removal, so this remains safe if a future implementation inserts an
      // async boundary between enumeration and deletion.
      let refreshed: Set<String> = Set(
        try downloadStore.fetchAll().compactMap { row in
          guard row.state != .failed else { return nil }
          return isSafeRSSPath(row.relativePath) ? row.relativePath : nil
        })
      guard refreshed.contains(relativePath) == false else { continue }
      try FileManager.default.removeItem(at: rootURL.appendingPathComponent(relativePath))
      removed.append(relativePath)
    }

    return DownloadIntegritySweepResult(
      failedMissingFileDownloadIds: failed.sorted(),
      finishedDeletionDownloadIds: finished.sorted(),
      removedOrphanRelativePaths: removed.sorted())
  }

  /// Re-checks one episode's completed row, as `run()` does for every row, without touching any
  /// other file. For the play path, which finds a missing file before the next launch does.
  /// Returns the demoted row's id, or `nil` when the row is not completed or its file is intact.
  @discardableResult
  public func validate(episodeId: Int64) throws -> Int64? {
    guard let row = try downloadStore.fetch(episodeId: episodeId), row.state == .completed else {
      return nil
    }
    return try demoteIfFileInvalid(row)
  }

  private func demoteIfFileInvalid(_ row: RSSDownloadRecord) throws -> Int64? {
    guard let id = row.id, isValidCompletedFile(row) == false else { return nil }
    _ = try downloadStore.transition(downloadId: id, to: .failed, errorCode: .storage)
    return id
  }

  private func isValidCompletedFile(_ row: RSSDownloadRecord) -> Bool {
    guard isSafeRSSPath(row.relativePath) else { return false }
    let url = rootURL.appendingPathComponent(row.relativePath)
    guard
      FileManager.default.fileExists(atPath: url.path),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize.map(Int64.init),
      size > 0,
      size == row.actualBytes
    else { return false }
    // The declared enclosure length is advisory and is not rechecked here, matching
    // `RSSFileStore.validatedLocalURL`: the file must be the bytes completion recorded, below the
    // absolute cap.
    return size <= RSSFileStore.sizeCapBytes
  }

  private func removeFileIfSafe(relativePath: String) throws {
    guard isSafeRSSPath(relativePath) else { return }
    let url = rootURL.appendingPathComponent(relativePath)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  private func isSafeRSSPath(_ path: String) -> Bool {
    let ownershipPrefix = RSSFileRoot.directoryName + "/"
    guard path.hasPrefix(ownershipPrefix) else { return false }
    let inner = String(path.dropFirst(ownershipPrefix.count))
    return StoragePath.isContained(
      relativePath: inner,
      under: rootURL.appendingPathComponent(RSSFileRoot.directoryName, isDirectory: true))
  }

  private func collectOrphans(keeping: Set<String>) throws -> [String] {
    let rssRoot = rootURL.appendingPathComponent(RSSFileRoot.directoryName, isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: rssRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return [] }
    var result: [String] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard values.isRegularFile == true else { continue }
      guard let relative = StoragePath.relativePath(of: url, under: rootURL) else { continue }
      guard relative.hasPrefix("RSS/"), keeping.contains(relative) == false else { continue }
      result.append(relative)
    }
    return result
  }
}
