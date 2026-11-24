import Foundation
import GRDB

/// Why a download exists but is not moving. Only holds that cannot clear themselves are here:
/// `queued` and `interrupted` both advance without the reader doing anything, so they stay
/// ordinary `downloading` and keep their bar.
public enum ReaderDownloadHold: Sendable, Equatable {
  /// Held by the cellular opt-in (API-CONVENTIONS.md). On cellular this never advances, so a
  /// progress bar would misrepresent it.
  case waitingForWiFi
  case paused
  case pausedAuth
}

/// The complete reader-facing state for one item. `ebookIdentityNotFetched` means a minified row
/// whose expanded detail is unchecked; `advertisedButUnavailable` is the confirmed absence.
///
/// There is no `finished` case: this projection answers only "where is the file", and a finished
/// state would hide it (the reader would refuse to open, the Contents tab would say "Not
/// Downloaded"). Finishing belongs to `LibraryReading.observeItemPlaybackStatuses`.
public enum ReaderState: Sendable, Equatable {
  case noEpubAdvertised
  case ebookIdentityNotFetched
  case advertisedButUnavailable
  case availableNotDownloaded
  case downloading(progress: Double)
  /// A download that exists but is parked. The fraction rides along for screens that draw a bar.
  case downloadHeld(reason: ReaderDownloadHold, progress: Double)
  case downloadedReady(fileURL: URL)
  case downloadedButFileMissing
  /// A download row that failed for a non-storage reason. Not `availableNotDownloaded`: the failed
  /// row survives and suppresses a new request (`requestEbookDownload` is idempotent), so that
  /// would show a 0% bar nothing can advance.
  case downloadFailed
  /// A download the app rejected because the bytes disagreed with the status, type or length the
  /// server reported. Retrying reproduces it until the server's metadata is corrected, unlike
  /// `downloadFailed`.
  case downloadRejected
}

/// Read side of the reader projection. The returned stream contains only Foundation value types;
/// neither GRDB observations nor database records cross the Persistence boundary.
public protocol ReaderStateReading: Sendable {
  /// `itemId` is the server item id. The item row is resolved inside the tracked fetch closure so
  /// an observation started before the first sync still becomes live when the row appears.
  func observeReaderState(itemId: String) -> AsyncStream<ReaderState>

  /// The stored ebook progress fraction for the item's own (non-episode) progress row, nil while
  /// no row or no ebook progress exists. Separate from `observeReaderState` so the states stay
  /// mutually exclusive; "Continue reading n%" composes the two streams. Defaulted so
  /// state-only conformers (fakes, no-ops) stay source-compatible.
  func observeEbookProgress(itemId: String) -> AsyncStream<Double?>
}

extension ReaderStateReading {
  public func observeEbookProgress(itemId: String) -> AsyncStream<Double?> {
    AsyncStream { $0.finish() }
  }
}

/// Database-backed reader projection. It joins the item row and the item-scoped EPUB download
/// rows in one tracked read. Audio download rows are excluded even when the item is a
/// bundled-EPUB audiobook. Progress rows are not read at all: `observeEbookProgress` is their own
/// stream, so a reading tick cannot re-emit a file location that has not changed.
public struct DefaultReaderStateReading: ReaderStateReading, Sendable {
  private let database: AppDatabase
  private let downloadRootURL: URL

  public init(database: AppDatabase, downloadRootURL: URL) {
    self.database = database
    self.downloadRootURL = downloadRootURL
  }

  public func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
    ObservationBridge.stream(in: database.dbWriter) { [downloadRootURL] db in
      guard
        let item =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .filter(Column("softDeleted") == false)
          .fetchOne(db)
      else {
        return .noEpubAdvertised
      }

      let isEPUB = EbookFormatNormalizer.normalize(item.ebookFormat) == "epub"
      guard isEPUB else { return .noEpubAdvertised }

      // The ino is the identity. A row that carries one was fetched, whatever its coverage
      // marker says: v52 clears that marker library-wide to backfill expected download sizes, and
      // a cleared marker must not retract a reader that already works.
      guard item.ebookFileIno?.isEmpty == false else {
        return item.expandedMetadataFetchedAt == nil
          ? .ebookIdentityNotFetched : .advertisedButUnavailable
      }

      let downloads =
        try DownloadRecord
        .filter(Column("accountId") == item.accountId)
        .filter(Column("itemId") == item.id)
        .filter(Column("podcastEpisodeId") == nil)
        .filter(Column("mediaKind") == DownloadMediaKind.ebook.rawValue)
        .order(Column("orderIndex"), Column("id"))
        .fetchAll(db)

      // Reuses `DownloadStore.status(rows:)` so the reader agrees with every other download
      // surface on priority rules. The state list is coarser: a row that is moving or will move on
      // its own (queued, interrupted) is `downloading`, and one parked until something outside the
      // transfer changes is `downloadHeld`. The item is neither openable nor requestable while any
      // row exists.
      switch DownloadStore.status(rows: downloads) {
      case .notDownloaded, .deleting:
        return .availableNotDownloaded
      case .failed(category: .storage):
        return .downloadedButFileMissing
      case .failed(category: .validation):
        return .downloadRejected
      case .failed:
        return .downloadFailed
      case .completed:
        guard let completed = downloads.first(where: { $0.state == .completed }) else {
          return .availableNotDownloaded
        }
        let fileURL = downloadRootURL.appendingPathComponent(completed.destinationRelativePath)
        return FileManager.default.fileExists(atPath: fileURL.path)
          ? .downloadedReady(fileURL: fileURL)
          : .downloadedButFileMissing
      case .downloading(let progressFraction):
        return .downloading(progress: progressFraction)
      case .waitingForWiFi:
        return .downloadHeld(
          reason: .waitingForWiFi, progress: Self.progressFraction(over: downloads))
      case .paused:
        return .downloadHeld(reason: .paused, progress: Self.progressFraction(over: downloads))
      case .pausedAuth:
        return .downloadHeld(reason: .pausedAuth, progress: Self.progressFraction(over: downloads))
      case .queued, .interrupted:
        return .downloading(progress: Self.progressFraction(over: downloads))
      }
    }
  }

  public func observeEbookProgress(itemId: String) -> AsyncStream<Double?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let item =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .filter(Column("softDeleted") == false)
          .fetchOne(db)
      else {
        return nil
      }
      return
        try MediaProgressRecord
        .filter(Column("accountId") == item.accountId)
        .filter(Column("itemId") == item.id)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)?
        .ebookProgress
    }
  }

  private static func progressFraction(over rows: [DownloadRecord]) -> Double {
    let live = rows.filter { $0.state != .deleting }
    let expected = live.reduce(into: Int64(0)) { $0 += $1.expectedBytes }
    guard expected > 0 else { return 0 }
    let received = live.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
    return min(max(Double(received) / Double(expected), 0), 1)
  }

}

/// Incremental-composition default for consumers that do not yet have a database environment.
public struct NoOpReaderStateReading: ReaderStateReading, Sendable {
  public init() {}

  public func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
    AsyncStream { $0.finish() }
  }
}
