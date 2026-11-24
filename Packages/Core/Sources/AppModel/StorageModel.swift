import Observation
import Persistence
import SyncEngine

/// The account's download storage screen: account totals plus one row per item that actually has
/// downloads, both from `StorageReading`, and a purge confirmation flow that forwards to
/// `DownloadIntents`. Rows come from `observeDownloadedItems()` rather than a caller-supplied
/// item list, which would list every loaded book at zero bytes.
@MainActor
@Observable
public final class StorageModel {
  public struct ItemRow: Sendable, Equatable, Identifiable {
    public var id: String { itemId }
    public let itemId: String
    public let title: String
    public internal(set) var author: String?
    public internal(set) var source: DownloadedItemSource
    public internal(set) var totalBytes: Int64 = 0
    /// The share of `totalBytes` (not additional to it) stranded behind a podcast episode the
    /// server no longer lists (`DownloadedItemTotals.tombstonedEpisodeBytes`). Always `0` for a
    /// book and for any show with no soft-deleted episode.
    public internal(set) var tombstonedEpisodeBytes: Int64 = 0
    /// True from the moment a purge is confirmed until removal finishes, so a view can show
    /// `StorageCopy.deletingProgress` before the file and row removal completes.
    public internal(set) var isDeleting: Bool = false

    /// Whether the removed-episode reclaim would act on this row. A row with none is not
    /// annotated with a zero.
    public var hasTombstonedEpisodeBytes: Bool { tombstonedEpisodeBytes > 0 }

    public init(
      itemId: String, title: String, author: String? = nil, source: DownloadedItemSource = .abs
    ) {
      self.itemId = itemId
      self.title = title
      self.author = author
      self.source = source
    }
  }

  /// What a confirmed `confirmPurge()` call will act on. Set by `requestPurge`/`requestPurgeAll`,
  /// cleared by `cancelPurge`/`confirmPurge`.
  public enum PurgeTarget: Sendable, Equatable {
    case item(itemId: String, title: String)
    case all
    /// Only the downloads stranded behind episodes the server no longer lists. Account-wide, since
    /// a soft-deleted episode has no row left to key it by. Carries the figure the confirmation
    /// quotes so the staged offer cannot drift from what was measured.
    case tombstonedEpisodes(bytes: Int64)
  }

  public private(set) var accountTotalBytes: Int64 = 0
  public private(set) var rows: [ItemRow] = []
  /// Whether the downloaded-items observation has delivered its first complete snapshot.
  ///
  /// `rows.isEmpty` cannot tell "still loading" from "no downloads". The shared Downloads screen
  /// uses this flag to avoid rendering library metadata before its matching byte totals.
  public private(set) var hasLoadedDownloadedItems = false
  public private(set) var isQueuePausedForLowDisk = false
  public private(set) var pendingPurgeConfirmation: PurgeTarget?
  /// True from the moment a removed-episode reclaim is confirmed until it finishes. The reclaim
  /// action shows `StorageCopy.deletingProgress` and ignores taps meanwhile. Not a row mark: the
  /// reclaim removes part of a show's storage, not the show's download.
  public private(set) var isReclaimingTombstonedEpisodes = false
  /// The last reclaim's failure as renderable copy, `nil` when the last one succeeded. Cleared by
  /// `dismissReclaimError()`. Surfaced so a failed tap is not indistinguishable from a dead button.
  public private(set) var reclaimErrorMessage: String?
  /// The last purge's failure as renderable copy, on the same terms as `reclaimErrorMessage`.
  public private(set) var purgeErrorMessage: String?
  /// The last automatic storage-ceiling result, projected from rows the coordinator actually
  /// deleted. It is persisted by the App composition so this disclosure survives relaunch.
  public private(set) var lastStorageCeilingSummary: StorageCeilingEvictionSummary?

  private let downloadIntents: any DownloadIntents

  @ObservationIgnored private var tasks: [Task<Void, Never>] = []

  public init(
    storageReading: any StorageReading,
    downloadIntents: any DownloadIntents,
    storageCeilingSummary: any StorageCeilingSummaryReading = NoOpStorageCeilingSummaryStore()
  ) {
    self.downloadIntents = downloadIntents
    lastStorageCeilingSummary = storageCeilingSummary.lastStorageCeilingSummary

    let accountStream = storageReading.observeAccountStorageTotals()
    tasks.append(
      Task { [weak self] in
        for await totals in accountStream {
          guard let self else { return }
          self.accountTotalBytes = totals.totalBytes
        }
      })

    let downloadedItems = storageReading.observeDownloadedItems()
    tasks.append(
      Task { [weak self] in
        for await items in downloadedItems {
          guard let self else { return }
          self.apply(downloadedItems: items)
        }
      })

    let storageCeilingSummaries = storageCeilingSummary.storageCeilingSummaryChanges
    tasks.append(
      Task { [weak self] in
        for await summary in storageCeilingSummaries {
          guard let self else { return }
          self.lastStorageCeilingSummary = summary
        }
      })
  }

  /// Rebuilds `rows` from an observation update, carrying each surviving row's in-flight
  /// `isDeleting` mark across. A purge's own byte-total updates arrive on this stream mid-removal,
  /// and rebuilding from scratch would flip the row out of its "Removing…" state.
  private func apply(downloadedItems: [DownloadedItemTotals]) {
    let deletingItemIds = Set(rows.filter(\.isDeleting).map(\.itemId))
    rows = downloadedItems.map { item in
      var row = ItemRow(
        itemId: item.itemId, title: item.title, author: item.author, source: item.source)
      row.totalBytes = item.totalBytes
      row.tombstonedEpisodeBytes = item.tombstonedEpisodeBytes
      row.isDeleting = deletingItemIds.contains(item.itemId)
      return row
    }
    hasLoadedDownloadedItems = true
  }

  /// The total represented by the same downloaded-item snapshot as `rows`.
  ///
  /// Exists alongside `accountTotalBytes` (an independent account observation) so a list can
  /// render its header and all row sizes from one observation.
  public var downloadedItemsTotalBytes: Int64 {
    rows.reduce(into: Int64(0)) { $0 += $1.totalBytes }
  }

  deinit {
    for task in tasks { task.cancel() }
  }

  // MARK: - Purge confirmation flow

  /// Stages a single item's purge behind `StorageCopy`'s destructive confirmation copy. Nothing is
  /// purged until `confirmPurge()` is called.
  public func requestPurge(itemId: String, title: String) {
    pendingPurgeConfirmation = .item(itemId: itemId, title: title)
  }

  /// Stages the whole account's purge-all behind its own destructive confirmation copy.
  public func requestPurgeAll() {
    pendingPurgeConfirmation = .all
  }

  /// Stages the removed-episode reclaim behind its own destructive confirmation copy. A no-op
  /// unless `canReclaimTombstonedEpisodeDownloads`, so a stale tap cannot confirm a reclaim of
  /// nothing.
  public func requestReclaimTombstonedEpisodes() {
    guard canReclaimTombstonedEpisodeDownloads else { return }
    pendingPurgeConfirmation = .tombstonedEpisodes(bytes: tombstonedEpisodeBytes)
  }

  /// Discards a staged confirmation without forwarding a purge intent.
  public func cancelPurge() {
    pendingPurgeConfirmation = nil
  }

  /// Forwards the staged confirmation's purge intent once, marking the affected row(s)
  /// `isDeleting` immediately so a view can show `StorageCopy.deletingProgress`. No-op if nothing
  /// is staged (e.g. already cancelled).
  ///
  /// The staged target is read and cleared synchronously, before any suspension: a confirmation
  /// alert writes `false` to its `isPresented` binding on every dismissal, including the Delete
  /// button's, and the Downloads screen turns that write into `cancelPurge()`.
  ///
  /// The returned task is the removal in flight; tests await it, a view discards it.
  @discardableResult
  public func confirmPurge() -> Task<Void, Never>? {
    guard let target = pendingPurgeConfirmation else {
      DownloadDeviceTrace.emit(
        .purgeIntent(
          DownloadDeviceTrace.PurgeIntent(scope: nil, source: .storage, outcome: .unstaged)))
      return nil
    }
    pendingPurgeConfirmation = nil

    switch target {
    case .item(let itemId, _):
      updateRow(itemId: itemId) { $0.isDeleting = true }
      return Task { await self.purgeItem(itemId: itemId) }
    case .all:
      for index in rows.indices { rows[index].isDeleting = true }
      return Task { await self.purgeAll() }
    case .tombstonedEpisodes:
      return Task { await self.reclaimTombstonedEpisodes() }
    }
  }

  /// Clears a surfaced purge failure once its presentation has been dismissed.
  public func dismissPurgeError() {
    purgeErrorMessage = nil
  }

  /// Removes a confirmed native selection. All requests run to completion so one failure does not
  /// hide later failures or stop the remaining rows being attempted.
  public func purgeSelectedItemDownloads(_ itemIDs: Set<String>) async {
    purgeErrorMessage = nil
    let eligible = itemIDs.filter { itemID in
      rows.contains { $0.itemId == itemID && $0.isDeleting == false }
    }.sorted()
    guard eligible.isEmpty == false else { return }
    for itemID in eligible { updateRow(itemId: itemID) { $0.isDeleting = true } }
    var failed = false
    for itemID in eligible {
      do {
        try await downloadIntents.purgeItemDownload(itemID: itemID, source: .storage)
      } catch {
        failed = true
        updateRow(itemId: itemID) { $0.isDeleting = false }
      }
    }
    purgeErrorMessage = failed ? StorageCopy.purgeFailed : nil
  }

  /// Both purge intents keep their failure and unmark the rows they marked, so a purge that threw
  /// does not leave every affected row reading "Removing…" forever.
  private func purgeItem(itemId: String) async {
    do {
      trace(scope: .item, outcome: .forwarded)
      try await downloadIntents.purgeItemDownload(itemID: itemId, source: .storage)
      purgeErrorMessage = nil
    } catch {
      trace(scope: .item, outcome: .failed)
      updateRow(itemId: itemId) { $0.isDeleting = false }
      purgeErrorMessage = StorageCopy.purgeFailed
    }
  }

  private func purgeAll() async {
    do {
      trace(scope: .all, outcome: .forwarded)
      try await downloadIntents.purgeAllDownloads(source: .storage)
      purgeErrorMessage = nil
    } catch {
      trace(scope: .all, outcome: .failed)
      for index in rows.indices { rows[index].isDeleting = false }
      purgeErrorMessage = StorageCopy.purgeFailed
    }
  }

  private func trace(
    scope: DownloadDeviceTrace.PurgeScope, outcome: DownloadDeviceTrace.PurgeIntentOutcome
  ) {
    DownloadDeviceTrace.emit(
      .purgeIntent(
        DownloadDeviceTrace.PurgeIntent(scope: scope, source: .storage, outcome: outcome)))
  }

  // MARK: - Removed-episode reclaim

  /// Every stranded byte across every row, the figure the reclaim offer quotes. Summed from the
  /// rows so it cannot disagree with what they show.
  public var tombstonedEpisodeBytes: Int64 {
    rows.reduce(into: Int64(0)) { $0 += $1.tombstonedEpisodeBytes }
  }

  /// Whether anything is stranded at all. A screen offers the reclaim only when this is true.
  public var hasTombstonedEpisodeBytes: Bool { tombstonedEpisodeBytes > 0 }

  /// Whether the reclaim can be started right now: there is something to reclaim and no reclaim is
  /// already in flight.
  public var canReclaimTombstonedEpisodeDownloads: Bool {
    hasTombstonedEpisodeBytes && isReclaimingTombstonedEpisodes == false
  }

  /// Clears a surfaced reclaim failure once its presentation has been dismissed.
  public func dismissReclaimError() {
    reclaimErrorMessage = nil
  }

  /// Forwards the reclaim once and keeps its failure. Rows are left unmarked: this frees part of a
  /// show's storage, and "Removing…" on the whole row would claim the download was going away.
  private func reclaimTombstonedEpisodes() async {
    isReclaimingTombstonedEpisodes = true
    defer { isReclaimingTombstonedEpisodes = false }
    do {
      trace(scope: .tombstoned, outcome: .forwarded)
      try await downloadIntents.purgeTombstonedEpisodeDownloads(source: .storage)
      reclaimErrorMessage = nil
    } catch {
      trace(scope: .tombstoned, outcome: .failed)
      reclaimErrorMessage = StorageCopy.reclaimEpisodesFailed
    }
  }

  // MARK: - Low-disk banner state

  /// Refreshes the low-disk queue-pause banner from `DownloadIntents`. The source is a plain
  /// getter, not observable, so a caller re-runs this when the screen appears or storage changes.
  public func refreshLowDiskStatus() async {
    isQueuePausedForLowDisk = await downloadIntents.isQueuePausedForLowDisk()
  }

  // MARK: - Helpers

  private func updateRow(itemId: String, _ mutate: (inout ItemRow) -> Void) {
    guard let index = rows.firstIndex(where: { $0.itemId == itemId }) else { return }
    mutate(&rows[index])
  }
}
