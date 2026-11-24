import Foundation

/// One item's download state, rolled up across every one of its per-file `download` rows
/// `none` when the item has no rows at all; `complete` only when every row is `completed`;
/// `partial` otherwise, including when some rows have failed or are mid-transfer. Rows in
/// `deleting` never count toward the rollup (they are never playable or schedulable).
public enum DownloadAggregateState: String, Sendable, Equatable {
  case none
  case partial
  case complete
}

/// A read-only, UI-facing projection (like `ItemSummary`/`LibrarySyncStatus`). The raw
/// `DownloadRecord`/`DownloadState` values stay Persistence-internal.
public struct DownloadAggregate: Sendable, Equatable {
  public let state: DownloadAggregateState
  /// Received/expected bytes across every counted row, clamped to `0...1`. `1.0` when `state ==
  /// .complete`; `0` when `state == .none`.
  public let progressFraction: Double

  public init(state: DownloadAggregateState, progressFraction: Double) {
    self.state = state
    self.progressFraction = progressFraction
  }
}
