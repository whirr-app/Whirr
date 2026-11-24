import Foundation

/// Per-item download observation surface. Screens observe this projection, never the raw
/// `DownloadRecord`/`DownloadState` values, mirroring `LibraryReading`'s own boundary.
public protocol DownloadReading: Sendable {
  /// The current detailed status for one item for synchronous callers. The async sibling is the
  /// non-blocking initial projection for MainActor models; the observation remains authoritative.
  func currentItemDownloadStatus(itemId: String) -> ItemDownloadStatus

  /// The same initial status projection without synchronously blocking the caller's executor.
  /// Query failures have the same `.notDownloaded` fallback as the synchronous sibling; the
  /// observation below remains authoritative for subsequent changes.
  func currentItemDownloadStatusAsync(itemId: String) async -> ItemDownloadStatus

  /// This item's aggregate download state (none/partial/complete) and byte-progress fraction,
  /// re-emitted whenever a per-file download row changes state or progress. Runs off the main
  /// actor; AppModel hops to main only to assign into `@Observable` state.
  func observeItemDownloadAggregate(itemId: String) -> AsyncStream<DownloadAggregate>

  /// This item's detailed rollup status, richer than `observeItemDownloadAggregate` (which cannot
  /// tell "waiting for Wi-Fi" from "queued" or "paused" from "downloading"), with the same
  /// triggers. `ItemDownloadModel` is the sole consumer. Per-item, for one-item screens (item
  /// detail's download cluster); a list must use `observeItemDownloadPresence` or pay one
  /// observation per row.
  func observeItemDownloadStatus(itemId: String) -> AsyncStream<ItemDownloadStatus>

  /// The detailed status of each item-level medium for one item. A medium with no surviving row
  /// is `.notDownloaded`; a row that exists but is being removed remains `.deleting`. The
  /// format-aware companion to `observeItemDownloadStatus`, item-scoped so byte-progress updates
  /// do not fan out through the shared list projection.
  func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus
  func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus
  func observeItemFormatDownloadStatus(itemId: String)
    -> AsyncStream<ItemFormatDownloadStatus>

  /// Every item with download rows, coarsely summarised and keyed by server item id, for browse,
  /// search and home rows and their context menus. One observation serves a screen, so it is
  /// deduplicated with no progress fraction (see `ItemDownloadPresence`). An item with no rows is
  /// absent, so the map tracks the downloaded set, not the library.
  func observeItemDownloadPresence() -> AsyncStream<[String: ItemDownloadPresence]>

  /// The episode-scoped counterpart, keyed by the full `(show, episode)` identity. Covers the
  /// rows `observeItemDownloadPresence` excludes, from both download spines: an account-owned
  /// episode under its server ids, a device-owned one under the reserved `rss:` item id and its
  /// identity key. The player's overflow menu acts on one episode, so it must read that episode's
  /// own download state; a show has none. Coarse and deduplicated like the item projection.
  func observeEpisodeDownloadPresence() -> AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>
}

/// Source-compatible defaults for lightweight readers that only implement the single-status
/// surface. The production reader overrides all three methods below; other conformances inherit
/// a no-op format fallback.
extension DownloadReading {
  public func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus {
    ItemFormatDownloadStatus(audio: currentItemDownloadStatus(itemId: itemId))
  }

  public func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus {
    // Does not call the single-status async read: ItemDownloadModel seeds both surfaces
    // concurrently, and a small fake may only support one outstanding continuation.
    // Production readers override this with the real per-format query.
    ItemFormatDownloadStatus()
  }

  public func observeItemFormatDownloadStatus(itemId: String)
    -> AsyncStream<ItemFormatDownloadStatus>
  {
    // Inert rather than a second single-status subscription: a lightweight fake may only retain
    // one continuation, and the single-status observation must stay authoritative.
    AsyncStream { continuation in
      continuation.yield(ItemFormatDownloadStatus())
      continuation.finish()
    }
  }
}

/// The default no-op `DownloadReading` conformance: every stream finishes immediately without
/// yielding, so `AppDependencies.downloadReading`'s default keeps fake-composed callers
/// compiling.
public struct NoOpDownloadReading: DownloadReading, Sendable {
  public init() {}
  public func currentItemDownloadStatus(itemId: String) -> ItemDownloadStatus { .notDownloaded }
  public func currentItemDownloadStatusAsync(itemId: String) async -> ItemDownloadStatus {
    .notDownloaded
  }
  public func observeItemDownloadAggregate(itemId: String) -> AsyncStream<DownloadAggregate> {
    AsyncStream { $0.finish() }
  }
  public func observeItemDownloadStatus(itemId: String) -> AsyncStream<ItemDownloadStatus> {
    AsyncStream { $0.finish() }
  }
  public func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus {
    ItemFormatDownloadStatus()
  }
  public func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus {
    ItemFormatDownloadStatus()
  }
  public func observeItemFormatDownloadStatus(itemId: String)
    -> AsyncStream<ItemFormatDownloadStatus>
  {
    AsyncStream { $0.finish() }
  }
  public func observeItemDownloadPresence() -> AsyncStream<[String: ItemDownloadPresence]> {
    AsyncStream { $0.finish() }
  }
  public func observeEpisodeDownloadPresence()
    -> AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>
  {
    AsyncStream { $0.finish() }
  }
}
