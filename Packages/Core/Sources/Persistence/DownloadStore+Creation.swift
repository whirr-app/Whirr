import Foundation
import GRDB

extension DownloadStore {
  // MARK: - Creation

  /// Inserts a new `pending` row for one server audio or ebook file. Throws `.duplicateDownload` if
  /// (account, item, episode-or-null, server file) already has a row. The schema's partial unique
  /// indexes enforce this, including the null-episode (audiobook) case a plain nullable unique
  /// column would silently miss.
  @discardableResult
  public func enqueue(
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    serverFileIno: String,
    orderIndex: Int,
    destinationRelativePath: String,
    expectedBytes: Int64,
    expectedMimeType: String,
    fileDurationSeconds: Double,
    origin: DownloadOrigin = .manual,
    mediaKind: DownloadMediaKind = .audio
  ) throws -> DownloadRecord {
    try database.write { db in
      try Self.enqueue(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        serverFileIno: serverFileIno,
        orderIndex: orderIndex,
        destinationRelativePath: destinationRelativePath,
        expectedBytes: expectedBytes,
        expectedMimeType: expectedMimeType,
        fileDurationSeconds: fileDurationSeconds,
        origin: origin,
        mediaKind: mediaKind,
        in: db)
    }
  }

  @discardableResult
  public func enqueueAsync(
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    serverFileIno: String,
    orderIndex: Int,
    destinationRelativePath: String,
    expectedBytes: Int64,
    expectedMimeType: String,
    fileDurationSeconds: Double,
    origin: DownloadOrigin = .manual,
    mediaKind: DownloadMediaKind = .audio
  ) async throws -> DownloadRecord {
    try await database.writeAsync { db in
      try Self.enqueue(
        accountId: accountId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        serverFileIno: serverFileIno,
        orderIndex: orderIndex,
        destinationRelativePath: destinationRelativePath,
        expectedBytes: expectedBytes,
        expectedMimeType: expectedMimeType,
        fileDurationSeconds: fileDurationSeconds,
        origin: origin,
        mediaKind: mediaKind,
        in: db)
    }
  }

  private static func enqueue(
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64?,
    serverFileIno: String,
    orderIndex: Int,
    destinationRelativePath: String,
    expectedBytes: Int64,
    expectedMimeType: String,
    fileDurationSeconds: Double,
    origin: DownloadOrigin,
    mediaKind: DownloadMediaKind,
    in db: Database
  ) throws -> DownloadRecord {
    var record = DownloadRecord(
      accountId: accountId,
      itemId: itemId,
      podcastEpisodeId: podcastEpisodeId,
      serverFileIno: serverFileIno,
      orderIndex: orderIndex,
      destinationRelativePath: destinationRelativePath,
      expectedBytes: expectedBytes,
      expectedMimeType: expectedMimeType,
      fileDurationSeconds: fileDurationSeconds,
      origin: origin,
      mediaKind: mediaKind)
    do {
      try record.insert(db)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw DownloadStoreError.duplicateDownload(
        accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
        serverFileIno: serverFileIno)
    }
    return record
  }
}
