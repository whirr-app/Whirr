import Foundation
import GRDB

/// One PDF accompanying an audiobook, as the expanded item response last described it.
/// `position` preserves the server order, primary first.
public struct StoredItemSupplement: Sendable, Equatable {
  public let serverFileIno: String
  public let position: Int
  public let filename: String?
  public let sizeBytes: Int64

  public init(serverFileIno: String, position: Int, filename: String?, sizeBytes: Int64) {
    self.serverFileIno = serverFileIno
    self.position = position
    self.filename = filename
    self.sizeBytes = sizeBytes
  }
}

/// Where one supplement's file stands on this device. Coarser than `ItemDownloadStatus`: the
/// viewer distinguishes only what it says differently.
public enum ItemSupplementFileState: Sendable, Equatable {
  case notDownloaded
  case downloading(progress: Double)
  /// Parked by the cellular opt-in (API-CONVENTIONS.md rule 25) and never advancing on cellular.
  case waitingForWiFi
  case paused
  case ready(fileURL: URL)
  /// The row failed, or claims completion while the file is gone. A fresh request replans it.
  case failed
  case deleting
}

/// The supplement as the App sees it: the stored description joined with its download row.
public struct ItemSupplement: Sendable, Equatable, Identifiable {
  public var id: String { serverFileIno }
  public let serverFileIno: String
  public let filename: String?
  public let sizeBytes: Int64
  /// Device-local only; never written to the server.
  public let lastViewedPage: Int?
  public let fileState: ItemSupplementFileState

  public init(
    serverFileIno: String, filename: String?, sizeBytes: Int64, lastViewedPage: Int?,
    fileState: ItemSupplementFileState
  ) {
    self.serverFileIno = serverFileIno
    self.filename = filename
    self.sizeBytes = sizeBytes
    self.lastViewedPage = lastViewedPage
    self.fileState = fileState
  }
}

/// Read side of an item's supplements. The stream carries Foundation value types only.
public protocol ItemSupplementReading: Sendable {
  /// `itemId` is the server item id, resolved inside the tracked fetch so the stream goes live
  /// when the item row or its supplements first appear.
  func observeSupplements(itemId: String) -> AsyncStream<[ItemSupplement]>
  func setLastViewedPage(itemId: String, serverFileIno: String, page: Int) async
}

/// Persists the supplement snapshot and the viewer's device-local page memory.
public struct ItemSupplementStore: ItemSupplementReading, Sendable {
  private let database: AppDatabase
  private let downloadRootURL: URL

  public init(database: AppDatabase, downloadRootURL: URL) {
    self.database = database
    self.downloadRootURL = downloadRootURL
  }

  /// Replaces one item's set. A supplement whose `ino` survives keeps its `lastViewedPage`; one
  /// the server no longer lists is dropped with its page. An empty authoritative list clears the
  /// set, matching `ItemChapterStore.replace`.
  static func replace(
    _ db: Database, accountId: Int64, itemId: Int64, supplements: [StoredItemSupplement]
  ) throws {
    let existing =
      try ItemSupplementRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
      .fetchAll(db)
    let pagesByIno = Dictionary(
      existing.compactMap { record in record.lastViewedPage.map { (record.serverFileIno, $0) } },
      uniquingKeysWith: { first, _ in first })
    try ItemSupplementRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
      .deleteAll(db)
    for supplement in supplements {
      var record = ItemSupplementRecord(
        accountId: accountId,
        itemId: itemId,
        position: supplement.position,
        serverFileIno: supplement.serverFileIno,
        filename: supplement.filename,
        sizeBytes: supplement.sizeBytes,
        lastViewedPage: pagesByIno[supplement.serverFileIno])
      try record.insert(db)
    }
  }

  public func fetchStored(accountId: Int64, itemId: Int64) async throws -> [StoredItemSupplement] {
    try await database.readAsync { db in
      try ItemSupplementRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .order(Column("position"))
        .fetchAll(db)
        .map {
          StoredItemSupplement(
            serverFileIno: $0.serverFileIno, position: $0.position, filename: $0.filename,
            sizeBytes: $0.sizeBytes)
        }
    }
  }

  public func observeSupplements(itemId: String) -> AsyncStream<[ItemSupplement]> {
    ObservationBridge.stream(in: database.dbWriter) { [downloadRootURL] db in
      try Self.supplements(db, itemId: itemId, downloadRootURL: downloadRootURL)
    }
  }

  public func supplements(itemId: String) async throws -> [ItemSupplement] {
    try await database.readAsync { [downloadRootURL] db in
      try Self.supplements(db, itemId: itemId, downloadRootURL: downloadRootURL)
    }
  }

  public func setLastViewedPage(itemId: String, serverFileIno: String, page: Int) async {
    _ = try? await database.writeAsync { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .select(Column("id"), as: Int64.self)
          .fetchOne(db)
      else { return }
      try ItemSupplementRecord
        .filter(Column("itemId") == itemRowId)
        .filter(Column("serverFileIno") == serverFileIno)
        .updateAll(db, Column("lastViewedPage").set(to: max(page, 0)))
    }
  }

  static func supplements(
    _ db: Database, itemId: String, downloadRootURL: URL
  ) throws -> [ItemSupplement] {
    guard
      let item =
        try ItemRecord
        .filter(Column("serverItemId") == itemId)
        .filter(Column("softDeleted") == false)
        .fetchOne(db),
      let itemRowId = item.id
    else { return [] }
    let records =
      try ItemSupplementRecord
      .filter(Column("accountId") == item.accountId)
      .filter(Column("itemId") == itemRowId)
      .order(Column("position"))
      .fetchAll(db)
    guard records.isEmpty == false else { return [] }
    let rows =
      try DownloadRecord
      .filter(Column("itemId") == itemRowId)
      .filter(Column("podcastEpisodeId") == nil)
      .filter(Column("mediaKind") == DownloadMediaKind.supplement.rawValue)
      .fetchAll(db)
    let rowsByIno = Dictionary(grouping: rows, by: \.serverFileIno)
    return records.map { record in
      ItemSupplement(
        serverFileIno: record.serverFileIno,
        filename: record.filename,
        sizeBytes: record.sizeBytes,
        lastViewedPage: record.lastViewedPage,
        fileState: fileState(rowsByIno[record.serverFileIno] ?? [], downloadRootURL: downloadRootURL))
    }
  }

  static func fileState(_ rows: [DownloadRecord], downloadRootURL: URL) -> ItemSupplementFileState {
    switch DownloadStore.status(rows: rows) {
    case .notDownloaded:
      return .notDownloaded
    case .deleting:
      return .deleting
    case .completed:
      guard let row = rows.first(where: { $0.state == .completed }) else { return .notDownloaded }
      let fileURL = downloadRootURL.appendingPathComponent(row.destinationRelativePath)
      return FileManager.default.fileExists(atPath: fileURL.path) ? .ready(fileURL: fileURL) : .failed
    case .downloading(let progress):
      return .downloading(progress: progress)
    case .queued, .interrupted:
      return .downloading(progress: progressFraction(rows))
    case .waitingForWiFi:
      return .waitingForWiFi
    case .paused, .pausedAuth:
      return .paused
    case .failed:
      return .failed
    }
  }

  private static func progressFraction(_ rows: [DownloadRecord]) -> Double {
    let expected = rows.reduce(into: Int64(0)) { $0 += $1.expectedBytes }
    let received = rows.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
    guard expected > 0 else { return 0 }
    return min(max(Double(received) / Double(expected), 0), 1)
  }
}
