import Observation
import Persistence
import SyncEngine

/// The explicit item-level download choices exposed to a mixed-format menu. This is separate from
/// `DownloadMediaKind`, whose values identify one persisted row; `.both` is a user intent that
/// expands into two coordinator requests.
public enum ItemDownloadFormat: Sendable, Equatable, Hashable {
  case audio
  case ebook
  case both
}

extension DownloadIntents {
  /// Issues the coordinator requests one `ItemDownloadFormat` means. Both manual download surfaces
  /// route through this rather than each expanding `.both` themselves.
  ///
  /// The coordinator serialises the resulting planning and scheduling passes; the two requests
  /// stay independent so an EPUB row is not suppressed by an audio row (or vice versa).
  func requestDownload(itemID: String, format: ItemDownloadFormat) async throws {
    switch format {
    case .audio:
      try await requestDownload(itemID: itemID)
    case .ebook:
      try await requestEbookDownload(itemID: itemID)
    case .both:
      async let audioRequest: Void = requestDownload(itemID: itemID)
      async let ebookRequest: Void = requestEbookDownload(itemID: itemID)
      try await audioRequest
      try await ebookRequest
    }
  }
}

/// One item's download control cluster. Renders entirely from `DownloadReading
/// .observeItemDownloadStatus` (never a direct API call, including at construction) and forwards
/// download/pause/resume/remove intents to `DownloadIntents`. `status` reuses the `Persistence`
/// type directly, so there is no AppModel-local enum to keep in step.
@MainActor
@Observable
public final class ItemDownloadModel {
  public private(set) var status: ItemDownloadStatus = .notDownloaded
  /// The status of each format's own rows. A `.notDownloaded` member means that format has no
  /// surviving row, which is how the model distinguishes "not requested" without consulting the
  /// item's metadata.
  public private(set) var formatStatus = ItemFormatDownloadStatus()

  /// False only while `status` is the placeholder (no `initialStatus` and the first local read
  /// not back), so compact controls do not present `.notDownloaded` as real.
  public private(set) var hasResolvedInitialStatus = false

  /// The last user-initiated intent's failure, as renderable copy; `nil` whenever the most recent
  /// intent succeeded. Surfaced so a rejected download doesn't look like a dead button.
  public private(set) var actionErrorMessage: String?

  private let itemID: String
  private let downloadIntents: any DownloadIntents

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var formatTask: Task<Void, Never>?

  /// - Parameter initialStatus: the state a caller already knows, in production
  ///   `DownloadStatusStore.provisionalStatus(for:)`. Lets the control render correctly on the
  ///   first frame instead of waiting on a database read queued behind sync and download writes.
  ///   `nil` keeps the placeholder and `hasResolvedInitialStatus` false until the read returns.
  public init(
    itemID: String,
    initialStatus: ItemDownloadStatus? = nil,
    initialFormatStatus: ItemFormatDownloadStatus? = nil,
    downloadReading: any DownloadReading,
    downloadIntents: any DownloadIntents
  ) {
    self.itemID = itemID
    self.downloadIntents = downloadIntents
    if let initialStatus {
      self.status = initialStatus
      self.hasResolvedInitialStatus = true
    }
    if let initialFormatStatus {
      self.formatStatus = initialFormatStatus
    }

    // Subscribed synchronously in `init`, so no emission is missed before the `Task` below runs.
    let stream = downloadReading.observeItemDownloadStatus(itemId: itemID)
    task = Task { [weak self, downloadReading, itemID] in
      guard let self else { return }

      // The stream is subscribed before this task starts and buffers its newest snapshot. Apply
      // the async seed first; any status emitted while the read was suspended is then consumed
      // by the loop and wins over this provisional value.
      let seed = await downloadReading.currentItemDownloadStatusAsync(itemId: itemID)
      guard Task.isCancelled == false else { return }
      self.status = seed
      self.hasResolvedInitialStatus = true

      for await status in stream {
        self.status = status
      }
    }

    let formatStream = downloadReading.observeItemFormatDownloadStatus(itemId: itemID)
    formatTask = Task { [weak self, downloadReading, itemID] in
      guard let self else { return }
      let seed = await downloadReading.currentItemFormatDownloadStatusAsync(itemId: itemID)
      guard Task.isCancelled == false else { return }
      self.formatStatus = seed

      for await formatStatus in formatStream {
        self.formatStatus = formatStatus
      }
    }
  }

  deinit {
    task?.cancel()
    formatTask?.cancel()
  }

  /// The copy this state renders. Components render this text rather than hardcoding their own.
  public var statusText: String { ItemDownloadCopy.text(for: status) }

  /// The "downloaded" badge (browse/search rows, item detail): true only once every live row
  /// across every requested medium has verified locally and at least one live row exists.
  public var isDownloaded: Bool { status == .completed }

  /// The "available offline" badge. Same as `isDownloaded` (a partial download is never
  /// offline-playable), but a separate name because the badges answer different questions.
  public var isAvailableOffline: Bool { status == .completed }

  /// `deleting` disables every intent below until removal finishes (the item is non-playable and
  /// non-schedulable from the moment it is marked). A view uses this to disable its whole download
  /// control cluster, including play.
  public var isActionable: Bool { status != .deleting }

  /// Requests this item's download. A no-op while `isActionable == false`.
  public func requestDownload(category: ItemMediaCategory = .audiobook) async {
    await perform(.download) {
      if category == .ebook {
        try await $0.requestEbookDownload(itemID: $1)
      } else {
        try await $0.requestDownload(itemID: $1)
      }
    }
  }

  /// Requests one explicit medium, or both media kinds concurrently for a mixed item. The row
  /// long-press menu shares this expansion.
  public func requestDownload(format: ItemDownloadFormat) async {
    await perform(.download) { try await $0.requestDownload(itemID: $1, format: format) }
  }

  /// Explicit convenience entry points for the mixed-format menu.
  public func requestAudioDownload() async {
    await requestDownload(format: .audio)
  }

  public func requestEbookDownload() async {
    await requestDownload(format: .ebook)
  }

  public func requestBothDownloads() async {
    await requestDownload(format: .both)
  }

  /// Pauses this item's in-flight download. A no-op while `isActionable == false`.
  public func pause() async {
    await perform(.pause) { try await $0.pauseItemDownload(itemID: $1) }
  }

  /// Resumes this item's paused/failed/interrupted download. A no-op while
  /// `isActionable == false`.
  public func resume() async {
    await perform(.resume) { try await $0.resumeItemDownload(itemID: $1) }
  }

  /// Removes this item's download (cancel in flight, remove failed, or delete completed) through
  /// one uniform purge. A no-op while `isActionable == false` (already removing).
  public func remove() async {
    await perform(.remove) {
      try await $0.purgeItemDownload(itemID: $1, source: .itemDetail)
    }
  }

  /// Clears a surfaced failure once its presentation has been dismissed.
  public func dismissActionError() {
    actionErrorMessage = nil
  }

  /// Every intent's shared shape: gated on `isActionable`, and either clearing the last failure
  /// (success) or replacing it with this action's own copy (failure).
  private func perform(
    _ action: ItemDownloadCopy.Action,
    _ intent: (any DownloadIntents, String) async throws -> Void
  ) async {
    guard isActionable else { return }
    do {
      try await intent(downloadIntents, itemID)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = ItemDownloadCopy.actionFailed(action, error: error)
    }
  }
}
