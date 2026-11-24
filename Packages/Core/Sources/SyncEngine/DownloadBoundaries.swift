import ABSApi
import Foundation

// MARK: - Download preferences

/// Device-local policy for requesting a download when an identity enters Up Next.
public enum QueueAutoDownloadPolicy: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case never
  case wifiOnly
  case always

  public init() {
    self = .never
  }
}

/// Device-local policy for requesting a download when an identity is newly saved to Saved for
/// Later. Its own type rather than a second use of `QueueAutoDownloadPolicy`: both are read off the
/// same `DownloadPreferences` and handed to decorators with identical argument labels, and this
/// one is expected to grow a per-media dimension without dragging Up Next along.
public enum SavedShelfAutoDownloadPolicy: String, Codable, Sendable, Equatable, Hashable,
  CaseIterable
{
  case never
  case wifiOnly
  case always

  public init() {
    self = .never
  }
}

/// The one preference the Up Next auto-download decorator needs. Narrower than the full
/// `DownloadPreferences` surface so the decorator and its tests do not depend on unrelated
/// cellular or delete-when-finished settings.
public protocol QueueAutoDownloadPolicyProviding: Sendable {
  var queueAutoDownloadPolicy: QueueAutoDownloadPolicy { get }
}

/// The one preference the Saved for Later auto-download decorator needs, narrow for the same
/// reason as `QueueAutoDownloadPolicyProviding`.
public protocol SavedShelfAutoDownloadPolicyProviding: Sendable {
  var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy { get }
}

/// Persisted device-side download behavior. `DownloadCoordinator` gates starting transfers
/// through the cellular opt-in combined with `NetworkConditions.isConstrainedOrCellular`;
/// playback completion and explicit finished actions read `deleteWhenFinished` before removing
/// the finished identity. Each change stream is multicast so every interested consumer observes
/// the same user action.
public protocol DownloadPreferences: Sendable, QueueAutoDownloadPolicyProviding,
  SavedShelfAutoDownloadPolicyProviding
{
  /// Defaults to `false` (rule 25): cellular downloads are opt-in.
  var allowCellular: Bool { get }
  func setAllowCellular(_ allowed: Bool) async
  /// A stream of changes. Every stream requested from one preference store receives every update.
  var changes: AsyncStream<Bool> { get }
  /// Defaults to `false`: existing downloads remain on-device unless the user explicitly opts in.
  var deleteWhenFinished: Bool { get }
  func setDeleteWhenFinished(_ enabled: Bool) async
  /// Every observer receives every delete-when-finished preference update.
  var deleteWhenFinishedChanges: AsyncStream<Bool> { get }
  /// Defaults to `.never`: adding to Up Next never requests a download until opted in.
  var queueAutoDownloadPolicy: QueueAutoDownloadPolicy { get }
  func setQueueAutoDownloadPolicy(_ policy: QueueAutoDownloadPolicy) async
  /// Every observer receives every Up Next auto-download policy update.
  var queueAutoDownloadPolicyChanges: AsyncStream<QueueAutoDownloadPolicy> { get }
  /// Defaults to `.never`: saving to Saved for Later never requests a download until opted in.
  var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy { get }
  func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async
  /// Every observer receives every Saved for Later auto-download policy update.
  var savedShelfAutoDownloadPolicyChanges: AsyncStream<SavedShelfAutoDownloadPolicy> { get }
  /// Defaults to `nil` (unlimited). The ceiling is measured in completed download bytes.
  var storageCeilingBytes: Int64? { get }
  func setStorageCeilingBytes(_ ceiling: Int64?) async
  /// Every observer receives every storage-ceiling preference update, including a transition to
  /// `nil` (unlimited).
  var storageCeilingBytesChanges: AsyncStream<Int64?> { get }
}

/// Source-compatible defaults for lightweight App-only preference fakes. The real no-op and
/// UserDefaults implementations below still provide explicit implementations, just as the
/// existing preference surfaces do.
extension DownloadPreferences {
  public var storageCeilingBytes: Int64? { nil }
  public func setStorageCeilingBytes(_ ceiling: Int64?) async {}
  public var storageCeilingBytesChanges: AsyncStream<Int64?> {
    AsyncStream { $0.finish() }
  }
  public var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy { .never }
  public func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async {}
  public var savedShelfAutoDownloadPolicyChanges: AsyncStream<SavedShelfAutoDownloadPolicy> {
    AsyncStream { $0.finish() }
  }
}

/// The default no-op `DownloadPreferences` conformance: every opt-in is disabled, mutations are
/// silent no-ops, and change streams never yield. Default for
/// `AppDependencies.downloadPreferences`, mirroring `NoOpDownloadIntents`.
public struct NoOpDownloadPreferences: DownloadPreferences, Sendable {
  public init() {}
  public var allowCellular: Bool { false }
  public func setAllowCellular(_ allowed: Bool) async {}
  public var changes: AsyncStream<Bool> { AsyncStream { $0.finish() } }
  public var deleteWhenFinished: Bool { false }
  public func setDeleteWhenFinished(_ enabled: Bool) async {}
  public var deleteWhenFinishedChanges: AsyncStream<Bool> { AsyncStream { $0.finish() } }
  public var queueAutoDownloadPolicy: QueueAutoDownloadPolicy { .never }
  public func setQueueAutoDownloadPolicy(_ policy: QueueAutoDownloadPolicy) async {}
  public var queueAutoDownloadPolicyChanges: AsyncStream<QueueAutoDownloadPolicy> {
    AsyncStream { $0.finish() }
  }
  public var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy { .never }
  public func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async {}
  public var savedShelfAutoDownloadPolicyChanges: AsyncStream<SavedShelfAutoDownloadPolicy> {
    AsyncStream { $0.finish() }
  }
  public var storageCeilingBytes: Int64? { nil }
  public func setStorageCeilingBytes(_ ceiling: Int64?) async {}
  public var storageCeilingBytesChanges: AsyncStream<Int64?> {
    AsyncStream { $0.finish() }
  }
}

// MARK: - Background transfers (the App's background-URLSession adapter)

/// Source-qualified identity for a background transfer, so an ABS row and a device-owned RSS row
/// with the same database id never collide in task maps or launch reconciliation.
///
/// `encoded` is URL/task-description safe: `abs:<rowID>` or `rss:<rowID>`. A bare canonical
/// integer from the older adapter decodes as an ABS identity; encoding never emits it.
public enum TransferIdentity: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
  case abs(rowID: Int64)
  case rss(rowID: Int64)

  public static func abs(_ rowID: Int64) -> Self { .abs(rowID: rowID) }
  public static func rss(_ rowID: Int64) -> Self { .rss(rowID: rowID) }

  public init?(encoded: String) {
    let value = encoded
    guard value.isEmpty == false else { return nil }
    if let separator = value.firstIndex(of: ":") {
      let tag = value[..<separator].lowercased()
      let digits = value[value.index(after: separator)...]
      guard digits.isEmpty == false, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
        let rowID = Int64(digits), rowID > 0
      else { return nil }
      switch tag {
      case "abs": self = .abs(rowID: rowID)
      case "rss": self = .rss(rowID: rowID)
      default: return nil
      }
      return
    }
    // Older task descriptions were a bare Int64. Accept them on relaunch, refusing signs,
    // whitespace, and non-canonical leading zeroes.
    guard value.first != "0", value.allSatisfy({ $0.isASCII && $0.isNumber }),
      let rowID = Int64(value)
    else { return nil }
    guard rowID > 0 else { return nil }
    self = .abs(rowID: rowID)
  }

  public init?(string: String) { self.init(encoded: string) }
  public init?(rawValue: String) { self.init(encoded: rawValue) }
  public static func decode(_ encoded: String) -> Self? { Self(encoded: encoded) }

  public var encoded: String {
    switch self {
    case .abs(let rowID): "abs:\(rowID)"
    case .rss(let rowID): "rss:\(rowID)"
    }
  }

  public var stringValue: String { encoded }
  public var rawValue: String { encoded }
  public var description: String { encoded }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(encoded)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self), let identity = Self(encoded: value) {
      self = identity
      return
    }
    if let rowID = try? container.decode(Int64.self), rowID > 0 {
      self = .abs(rowID: rowID)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container, debugDescription: "Invalid transfer identity")
  }
}

/// Identity plus the one absolute location a background transfer's temp file must move to, and
/// no wider filesystem capability than that single move. `identity` keys every
/// `BackgroundTransferEvent` for this transfer, so the coordinator never tracks an
/// adapter-internal task identifier.
public struct DownloadDestinationToken: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let identity: TransferIdentity
  public let destinationURL: URL

  public init(identity: TransferIdentity, destinationURL: URL) {
    self.identity = identity
    self.destinationURL = destinationURL
  }

  public var description: String { "DownloadDestinationToken(identity: \(identity))" }
  public var debugDescription: String { description }
}

/// The response metadata a finished transfer carries (HTTP status, response MIME, response
/// length, and the raw `Content-Range` value), passed unchanged into
/// `DownloadFileStore.completeTransfer` validation. That store, never the App adapter, owns the
/// status/MIME/final-size decision (SECURITY.md §13).
public struct BackgroundTransferResponse: Sendable, Equatable {
  public let httpStatusCode: Int
  public let mimeType: String?
  public let contentLength: Int64?
  public let contentRange: String?

  public init(
    httpStatusCode: Int, mimeType: String? = nil, contentLength: Int64? = nil,
    contentRange: String? = nil
  ) {
    self.httpStatusCode = httpStatusCode
    self.mimeType = mimeType
    self.contentLength = contentLength
    self.contentRange = contentRange
  }
}

/// One event the App's background `URLSession` adapter reports back through the single
/// `BackgroundTransferring.events` stream. Every case is keyed by `identity`
/// (`DownloadDestinationToken`'s identity), never an adapter-internal task identifier.
public enum BackgroundTransferEvent: Sendable, Equatable {
  case progress(identity: TransferIdentity, receivedBytes: Int64, expectedBytes: Int64?)
  case finished(identity: TransferIdentity, temporaryFileURL: URL, response: BackgroundTransferResponse)
  case failed(identity: TransferIdentity, errorDomain: String?, errorCode: Int?)
  case authChallenge(identity: TransferIdentity)

}

/// One background task the adapter currently believes is live, reported by
/// `BackgroundTransferring.currentTasks()` for launch reconciliation.
public struct BackgroundTransferSnapshot: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let identity: TransferIdentity
  public init(identity: TransferIdentity) { self.identity = identity }
  public var description: String { "BackgroundTransferSnapshot(identity: \(identity))" }
  public var debugDescription: String { description }
}

/// The App's background-download adapter, as SyncEngine sees it (ARCHITECTURE.md §2 rule 2):
/// enqueue an already-authorized audio or ebook request at a destination, pause/resume/cancel by
/// download identity, and an event stream carrying every outcome. The concrete conformance wraps a
/// background `URLSession`; it never stores a refresh token or mints an endpoint, since every
/// request was minted and authorized by ABSApi.
///
/// `events` is single-consumer: only `DownloadCoordinator`'s internal subscriber iterates it.
public protocol BackgroundTransferring: Sendable {
  func enqueue(_ request: AuthorizedTransferRequest, destination: DownloadDestinationToken) async
  func pause(identity: TransferIdentity) async
  func resume(identity: TransferIdentity) async
  func cancel(identity: TransferIdentity) async
  var events: AsyncStream<BackgroundTransferEvent> { get }
  /// Every task the adapter currently believes is live. Used only for launch reconciliation,
  /// never mid-session.
  func currentTasks() async -> [BackgroundTransferSnapshot]
  /// Transfers whose `.finished` the adapter has yielded but no coordinator has acknowledged. A
  /// finished task is gone from `currentTasks()`, yet its file is already at the destination, so
  /// launch reconciliation must reattach its row rather than requeue it for a second transfer.
  func undeliveredFinishes() async -> Set<TransferIdentity>
  /// Called once the coordinator has handled a `.finished`, whatever the outcome.
  func acknowledgeFinish(identity: TransferIdentity) async
}

extension BackgroundTransferring {
  public func undeliveredFinishes() async -> Set<TransferIdentity> { [] }
  public func acknowledgeFinish(identity: TransferIdentity) async {}
}

// MARK: - Download intents

/// Item-scoped download intents, as AppModel sees them. AppModel may not import SyncEngine's
/// concrete `DownloadCoordinator` (ARCHITECTURE.md §2), so its conformance sits behind this
/// boundary, as with `PlaybackSyncing`. Methods are keyed by server item id; the per-file
/// `downloadId` (rule 24: downloads are per audio file) never crosses it.
public protocol DownloadIntents: Sendable {
  /// Requests every audio file of `itemID` for download. Idempotent: a no-op if the item already
  /// has any surviving download row.
  func requestDownload(itemID: String) async throws

  /// Requests the one stored EPUB row for `itemID`. This is medium-scoped: an existing audio row
  /// neither suppresses nor changes the ebook request.
  func requestEbookDownload(itemID: String) async throws

  /// Requests one supplement PDF of `itemID` on its own .
  /// Idempotent over a live row for the same file; a failed row is retried. The PDF never changes
  /// the item's own download state.
  func requestSupplementDownload(itemID: String, fileIno: String) async throws

  /// Requests the one stored audio file backing a podcast episode. Idempotent for the full
  /// `(item, episode)` identity; a sibling episode's row never suppresses this request.
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws
  func pauseEpisodeDownload(itemID: String, episodeID: String) async throws
  func resumeEpisodeDownload(itemID: String, episodeID: String) async throws
  func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws

  /// Ebook-scoped controls affect only the item's `.ebook` row. The item-wide controls below pause,
  /// resume, or purge every medium belonging to the item.
  func pauseEbookDownload(itemID: String) async throws
  func resumeEbookDownload(itemID: String) async throws
  func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws

  /// Pauses every currently-`.downloading` file of `itemID`. A no-op if none are downloading.
  func pauseItemDownload(itemID: String) async throws

  /// Resumes every paused/failed/interrupted file of `itemID`, re-entering the ordinary
  /// scheduler. A no-op if nothing is eligible (e.g. every row is `.pausedAuth`, whose only exit
  /// is a successful re-authentication).
  func resumeItemDownload(itemID: String) async throws

  /// Purges every download row of `itemID`. The one item-level removal action, uniform across
  /// cancel-in-flight, remove-failed, and delete-completed.
  func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws

  /// Purges every download on the account, behind `StorageModel`'s purge confirmation.
  func purgeAllDownloads(source: DownloadPurgeSource) async throws

  /// Reclaims downloads whose podcast episode the server no longer lists, behind `StorageModel`'s
  /// confirmation. Account-wide since a soft-deleted episode has no row on any screen to key by
  /// (see `DownloadCoordinator.purgeTombstonedEpisodeDownloads`). Never automatic: soft-delete is
  /// a reversible sync inference.
  func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws

  /// Whether the queue is paused for low disk, shown in `StorageModel`'s banner.
  func isQueuePausedForLowDisk() async -> Bool
}

/// Feed-settings credential saves notify the device-owned RSS scheduler through this narrow
/// boundary. Separate from successful ABS reauthentication: crossing these paths would let one
/// credential class release the other's durable auth holds.
public protocol FeedCredentialUpdateHandling: Sendable {
  func handleFeedCredentialUpdate(feedId: Int64) async
}

public struct NoOpFeedCredentialUpdateHandler: FeedCredentialUpdateHandling, Sendable {
  public init() {}
  public func handleFeedCredentialUpdate(feedId _: Int64) async {}
}

/// The default no-op conformance: every intent is a silent no-op and the queue never reports
/// paused-for-low-disk. Default for `AppDependencies.downloadIntents`, mirroring
/// `NoOpDiagnosticsRecording`.
public struct NoOpDownloadIntents: DownloadIntents, Sendable {
  public init() {}
  public func requestDownload(itemID: String) async throws {}
  public func requestEbookDownload(itemID: String) async throws {}
  public func requestSupplementDownload(itemID: String, fileIno: String) async throws {}
  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {}
  public func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {}
  public func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {}
  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {}
  public func pauseEbookDownload(itemID: String) async throws {}
  public func resumeEbookDownload(itemID: String) async throws {}
  public func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {}
  public func pauseItemDownload(itemID: String) async throws {}
  public func resumeItemDownload(itemID: String) async throws {}
  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {}
  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {}
  public func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {}
  public func isQueuePausedForLowDisk() async -> Bool { false }
}

// MARK: - Automatic episode download planning

/// The boundary the automatic-download pass plans episode downloads through. Distinct from
/// `DownloadIntents.requestEpisodeDownload`, which no AppModel/UI surface can reach with anything
/// but a `.manual` intent. Only `DownloadCoordinator`'s own episode planner, called through this
/// method, writes an `.automatic`-origin row.
public protocol AutomaticEpisodeDownloadPlanning: Sendable {
  func requestAutomaticEpisodeDownload(itemID: String, episodeID: String) async throws
}

// MARK: - Free space (injected low-disk seam)

/// The injected free-space seam. `DownloadCoordinator` never asks an iOS storage API directly,
/// so its low-disk queue pause is deterministically testable.
/// Bytes available for new downloads on the volume the downloads root lives on.
public protocol FreeSpaceReporting: Sendable {
  func availableCapacityBytes() -> Int64
}

/// The default `FreeSpaceReporting` conformance: reports abundant space, so a caller that never
/// wires the real seam never pauses for low disk.
public struct UnboundedFreeSpaceReporting: FreeSpaceReporting, Sendable {
  public init() {}
  public func availableCapacityBytes() -> Int64 { .max }
}
