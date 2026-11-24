import Foundation

/// One item's detailed download status, rolled up across its per-file `download` rows. Richer than
/// `DownloadAggregate`'s none/partial/complete, which cannot tell "waiting for Wi-Fi" from
/// "queued" or "paused" from "downloading" as `ItemDownloadModel` needs. When files disagree,
/// `DownloadStore.itemStatus`'s priority-ordered derivation picks the most blocking condition.
public enum ItemDownloadStatus: Sendable, Equatable {
  case notDownloaded
  case waitingForWiFi
  case queued
  case downloading(progressFraction: Double)
  case paused
  case pausedAuth
  case interrupted
  case deleting
  case failed(category: DownloadErrorCategory)
  case completed
}

/// The detailed status of each item-level download medium. A medium with no surviving row is
/// represented by `.notDownloaded`, following `DownloadStore.itemStatus`'s shape rather than adding
/// a second "never requested" state. `.deleting` means a row exists but is in the recoverable
/// removal protocol, so it stays distinguishable from a medium never requested.
public struct ItemFormatDownloadStatus: Sendable, Equatable {
  public let audio: ItemDownloadStatus
  public let ebook: ItemDownloadStatus

  public init(
    audio: ItemDownloadStatus = .notDownloaded,
    ebook: ItemDownloadStatus = .notDownloaded
  ) {
    self.audio = audio
    self.ebook = ebook
  }

  public subscript(mediaKind: DownloadMediaKind) -> ItemDownloadStatus {
    switch mediaKind {
    case .audio: audio
    case .ebook: ebook
    // A supplement is not one of the item's formats; `ItemSupplementsModel` observes its rows.
    case .supplement: .notDownloaded
    }
  }
}

/// The coarse, list-facing summary of one item's downloads: what a browse, search or home row and
/// its context menu render. Carries less than `ItemDownloadStatus`.
///
/// `DownloadReading.observeItemDownloadPresence` feeds every visible row from one observation, so
/// `.partial` carries no progress fraction or hold reason (a row shows neither) and progress
/// writes deduplicate away instead of re-rendering the list. Item detail's download cluster
/// observes `ItemDownloadStatus` for its one item.
public enum ItemDownloadPresence: Sendable, Equatable {
  /// No download rows at all. Never stored in the projection map; an absent key means this.
  case none
  /// Live rows exist but are not all completed: queued, waiting for Wi-Fi, in flight, paused,
  /// paused for auth, interrupted, or failed. All render the same row affordance ("remove this
  /// download"), so they collapse together.
  case partial
  case completed
  /// Mid-removal: every live row is gone. Blocks the row's download affordance until the
  /// deletion protocol finishes, as `ItemDownloadStatus.deleting` does.
  case deleting

  /// The summary of a detailed rollup. An explicit mapping rather than derived in SQL, so
  /// `DownloadStore.itemStatus`'s priority ordering stays the single source of truth.
  public static func resolve(_ status: ItemDownloadStatus) -> Self {
    switch status {
    case .notDownloaded: return .none
    case .deleting: return .deleting
    case .completed: return .completed
    case .waitingForWiFi, .queued, .downloading, .paused, .pausedAuth, .interrupted, .failed:
      return .partial
    }
  }
}

/// One podcast episode's download identity in a presence projection: the show's server item id
/// plus the episode's server id (the `(itemId, serverEpisodeId)` episode identity). A struct
/// rather than a joined string key so neither id can be truncated or confused for the other by a
/// caller assembling one by hand.
public struct EpisodeDownloadKey: Sendable, Hashable {
  public let itemID: String
  public let episodeID: String

  public init(itemID: String, episodeID: String) {
    self.itemID = itemID
    self.episodeID = episodeID
  }
}
