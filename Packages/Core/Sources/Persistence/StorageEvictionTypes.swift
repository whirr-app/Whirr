import Foundation

/// The persistence identity the storage ceiling evicts as one unit: an audiobook item or one
/// podcast episode. A multi-file audiobook is not split into separate candidates, because
/// progress, playback and queue protections are all scoped to this identity.
public enum StorageEvictionSource: String, Codable, Sendable, Equatable {
  case abs
  case rss
}

public struct StorageEvictionIdentity: Hashable, Sendable, Equatable {
  public let source: StorageEvictionSource
  public let itemId: Int64
  public let podcastEpisodeId: Int64?
  /// Row id is carried for source-correct deletion, while item/episode remain the policy identity.
  public let downloadId: Int64?

  public init(itemId: Int64, podcastEpisodeId: Int64?) {
    self.source = .abs
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.downloadId = nil
  }

  public init(source: StorageEvictionSource, itemId: Int64, episodeId: Int64?, downloadId: Int64? = nil) {
    self.source = source
    self.itemId = itemId
    self.podcastEpisodeId = episodeId
    self.downloadId = downloadId
  }

  public static func rss(feedId: Int64, episodeId: Int64) -> Self {
    Self(source: .rss, itemId: feedId, episodeId: episodeId)
  }

  public static func rss(feedID: Int64, episodeID: Int64) -> Self {
    rss(feedId: feedID, episodeId: episodeID)
  }
}

/// One identity that can be selected by the ceiling policy. `byteTotal` is the completed-byte
/// total used for target planning; the atomic claim returns the actual pre-mark rows instead of
/// relying on this estimate after a concurrent database change.
public struct StorageEvictionCandidate: Sendable, Equatable {
  public let source: StorageEvictionSource
  public let itemId: Int64
  public let podcastEpisodeId: Int64?
  public let isFinished: Bool
  public let lastActivityAt: Date?
  public let byteTotal: Int64
  public let isTombstoned: Bool
  public let downloadId: Int64?

  public init(
    itemId: Int64,
    podcastEpisodeId: Int64?,
    isFinished: Bool,
    lastActivityAt: Date?,
    byteTotal: Int64,
    isTombstoned: Bool,
    source: StorageEvictionSource = .abs,
    downloadId: Int64? = nil
  ) {
    self.source = source
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.isFinished = isFinished
    self.lastActivityAt = lastActivityAt
    self.byteTotal = byteTotal
    self.isTombstoned = isTombstoned
    self.downloadId = downloadId
  }

  public var identity: StorageEvictionIdentity {
    StorageEvictionIdentity(source: source, itemId: itemId, episodeId: podcastEpisodeId)
  }
}

/// A source-qualified pre-mark snapshot. RSS rows cannot be represented as `DownloadRecord`
/// because they have no account/item columns; the typed identity avoids the same-number ABS/RSS
/// collision that transfer reconciliation guards against.
public struct StorageEvictionClaimedRow: Sendable, Equatable {
  public let identity: StorageEvictionIdentity
  public let downloadId: Int64
  public let podcastEpisodeId: Int64?
  public let bytes: Int64
  public let state: DownloadState
  public let holdReason: String?
  public var source: StorageEvictionSource { identity.source }

  public init(
    identity: StorageEvictionIdentity, downloadId: Int64, podcastEpisodeId: Int64?, bytes: Int64,
    state: DownloadState, holdReason: String? = nil
  ) {
    self.identity = identity
    self.downloadId = downloadId
    self.podcastEpisodeId = podcastEpisodeId
    self.bytes = bytes
    self.state = state
    self.holdReason = holdReason
  }
}

/// The narrow boundary the SyncEngine pass needs from Persistence. Candidate enumeration remains
/// public on `StorageEvictionStore` for persistence tests and diagnostics, but the ceiling pass
/// only needs the atomic claim operation.
public protocol StorageEvictionClaiming: Sendable {
  /// The one claim the ceiling pass performs. Its result is source-qualified because an RSS row
  /// cannot be represented as a `DownloadRecord`; an ABS-only signature would let a fake pass
  /// while production's union path was broken.
  func claimUnion(targetBytes: Int64) async throws -> [StorageEvictionClaimedRow]
}
