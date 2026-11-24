import Foundation
import GRDB

/// Lifecycle states for an on-disk download. `interrupted` is never entered through
/// `DownloadStore.transition`; launch reconciliation infers it (ARCHITECTURE.md §4: force-quit
/// cancels background transfers, so a row left `downloading` cannot be trusted). `deleting` is
/// terminal for `DownloadStore`: the recoverable deletion protocol removes the row itself.
public enum DownloadState: String, Codable, Sendable, DatabaseValueConvertible {
  case pending
  case downloading
  case paused
  /// A durable pause entered only on a `401` while transferring. Its only automatic exit is a
  /// successful re-authentication moving the row back to `pending`. It never resumes directly to
  /// `downloading`, and the user cannot resume it the way plain `paused` allows.
  case pausedAuth
  /// Force-quit inference only (see above), never a caller-requested transition.
  case interrupted
  case deleting
  case completed
  case failed
}

/// A durable, non-error hold on a `pending` row (`waitingForWiFi`, distinct from an error).
/// Meaningful only while `state == .pending`; `DownloadStore.transition` clears it on every other
/// transition.
public enum DownloadHoldReason: String, Codable, Sendable, DatabaseValueConvertible {
  case waitingForWiFi
}

/// A privacy-safe error category only, never a raw error message or payload (mirrors
/// `SyncRunRecord.errorCategory`). Meaningful only while `state == .failed`; `DownloadStore
/// .transition` clears it on every other transition.
public enum DownloadErrorCategory: String, Codable, Sendable, DatabaseValueConvertible {
  case transport
  case auth
  case validation
  case storage
  /// A disk-full failure while moving a completed transfer into place. Distinct and actionable,
  /// so not folded into `.transport` (a network condition) or `.validation` (a content-mismatch
  /// condition); callers can react to it specifically.
  case lowDisk
  case unknown
}

/// Who requested this download. Every row created by a manual tap is `.manual`; only the
/// automatic pass writes `.automatic`. The only permitted change afterwards is a manual request
/// promoting an `.automatic` row to `.manual`, never the reverse. Retention reaps only
/// `.automatic` rows.
public enum DownloadOrigin: String, Codable, Sendable, DatabaseValueConvertible {
  case manual
  case automatic
}

/// The medium represented by one download row. Rows that predate ebook downloads migrate as
/// `.audio`. The discriminator is independent of the expected MIME so consumers do not have to
/// infer media kind from a transport header.
public enum DownloadMediaKind: String, Codable, Sendable, DatabaseValueConvertible {
  case audio
  case ebook
  /// A PDF that accompanies an audiobook. It rides along with the item's download but never
  /// changes what the item is downloaded as: every item-level fold counts `itemMedia` kinds only.
  case supplement

  /// The kinds that make up an item's own download. A supplement is excluded so a pending or
  /// failed PDF can never make a complete audiobook partial, block offline promotion, or put an
  /// undownloaded book on the Downloads screen.
  public var isItemMedia: Bool { self != .supplement }

  /// The SQL twin of `isItemMedia`. `table` is the `download` table's name or alias in the query.
  public static func itemMediaSQL(_ table: String = "download") -> String {
    "\(table).mediaKind IN ('audio', 'ebook')"
  }
}

/// One downloaded (or downloading) audio or ebook file. Downloads are per server file (see
/// API-CONVENTIONS.md), so an item has one row per media file. `mediaKind` defaults to `.audio`
/// for pre-ebook callers. `destinationRelativePath` is relative to the downloads root so no
/// absolute path that could move between launches is persisted. `podcastEpisodeId` stays
/// nullable even though ebook downloads are item-scoped.
public struct DownloadRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "download"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var podcastEpisodeId: Int64?
  /// The server audio file's identity (the `{fileid}`/`ino` path segment), part of this row's
  /// uniqueness alongside account/item/episode.
  public var serverFileIno: String
  /// This file's position within its item's audio files, for reassembling playback order across
  /// multiple downloaded files (mirrors `audioFiles[].index`).
  public var orderIndex: Int
  public var destinationRelativePath: String
  public var expectedBytes: Int64
  public var expectedMimeType: String
  public var fileDurationSeconds: Double
  public var receivedBytes: Int64
  public var state: DownloadState
  public var holdReason: DownloadHoldReason?
  public var errorCategory: DownloadErrorCategory?
  public var origin: DownloadOrigin
  public var mediaKind: DownloadMediaKind
  /// Automatic retries already spent on this row. Written only by the retry requeue (increment),
  /// the generic `.failed -> .pending` edge that Try Again takes (reset) and `complete` (reset),
  /// so it survives relaunch and the overnight wake.
  public var autoRetryCount: Int
  /// The earliest automatic retry of a failed automatic row; `nil` whenever the row is not waiting
  /// for one. Every transition clears it; only `armAutomaticRetry` sets it.
  public var autoRetryNotBefore: Date?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    serverFileIno: String,
    orderIndex: Int,
    destinationRelativePath: String,
    expectedBytes: Int64,
    expectedMimeType: String,
    fileDurationSeconds: Double,
    receivedBytes: Int64 = 0,
    state: DownloadState = .pending,
    holdReason: DownloadHoldReason? = nil,
    errorCategory: DownloadErrorCategory? = nil,
    origin: DownloadOrigin = .manual,
    mediaKind: DownloadMediaKind = .audio,
    autoRetryCount: Int = 0,
    autoRetryNotBefore: Date? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.serverFileIno = serverFileIno
    self.orderIndex = orderIndex
    self.destinationRelativePath = destinationRelativePath
    self.expectedBytes = expectedBytes
    self.expectedMimeType = expectedMimeType
    self.fileDurationSeconds = fileDurationSeconds
    self.receivedBytes = receivedBytes
    self.state = state
    self.holdReason = holdReason
    self.errorCategory = errorCategory
    self.origin = origin
    self.mediaKind = mediaKind
    self.autoRetryCount = autoRetryCount
    self.autoRetryNotBefore = autoRetryNotBefore
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  /// A completed row is the only one safe to hand to the playback path, since only a fully
  /// verified file is playable. `deleting` is never playable or schedulable.
  public var isPlayable: Bool { state == .completed }

  /// True only for the one state the scheduler may pick up and start a transfer for. Every other
  /// state, including `deleting`, is excluded.
  public var isSchedulable: Bool { state == .pending }
}
