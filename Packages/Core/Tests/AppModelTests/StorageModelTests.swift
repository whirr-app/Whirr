import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// `StorageModel` renders account/per-item purgeable totals from `StorageReading`
/// and forwards purge intents (with a destructive-copy confirmation step) to `DownloadIntents`.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct StorageModelTests {

  @Test func accountTotalsUpdateFromObservation() async {
    let (model, storageReading, _) = makeModel()
    storageReading.pushAccountTotals(StorageTotals(totalBytes: 12_345))

    await waitUntil { model.accountTotalBytes == 12_345 }
    #expect(model.accountTotalBytes == 12_345)
  }

  @Test func rowsAreOnlyTheItemsThatActuallyHaveDownloads() async {
    let (model, storageReading, _) = makeModel()
    #expect(model.rows.isEmpty, "nothing is listed until the download rows themselves say so")
    #expect(model.hasLoadedDownloadedItems == false)

    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "item-1", title: "Book One", totalBytes: 1_000),
      DownloadedItemTotals(itemId: "item-2", title: "Book Two", totalBytes: 2_000),
    ])
    await waitUntil { model.rows.count == 2 }

    #expect(model.rows.map(\.itemId) == ["item-1", "item-2"])
    #expect(model.rows.map(\.title) == ["Book One", "Book Two"])
    #expect(model.rows.map(\.totalBytes) == [1_000, 2_000])
    #expect(model.hasLoadedDownloadedItems)
    #expect(model.downloadedItemsTotalBytes == 3_000)
  }

  @Test func rssStorageRowsPreserveSourceAndAuthorMetadata() async {
    let (model, storageReading, _) = makeModel()
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(
        itemId: "rss:7", title: "The Feed", totalBytes: 1_000,
        author: "Host", source: .rss)
    ])
    await waitUntil { model.rows.count == 1 }

    #expect(model.rows[0].source == .rss)
    #expect(model.rows[0].author == "Host")
  }

  @Test func anItemWhoseDownloadsAreGoneLeavesTheList() async {
    let (model, storageReading, _) = makeModel()
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "item-1", title: "Book One", totalBytes: 1_000),
      DownloadedItemTotals(itemId: "item-2", title: "Book Two", totalBytes: 2_000),
    ])
    await waitUntil { model.rows.count == 2 }

    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "item-2", title: "Book Two", totalBytes: 2_000)
    ])
    await waitUntil { model.rows.count == 1 }

    #expect(model.rows.map(\.itemId) == ["item-2"])
  }

  @Test func anInFlightDeletionSurvivesAFurtherObservationUpdate() async {
    let (model, storageReading, _) = makeModel()
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "item-1", title: "Book One", totalBytes: 1_000)
    ])
    await waitUntil { model.rows.count == 1 }
    model.requestPurge(itemId: "item-1", title: "Book One")
    await model.confirmPurge()?.value

    // The purge's own progress update (bytes falling as files disappear) must not reset the row
    // to a non-deleting state while the removal is still running.
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "item-1", title: "Book One", totalBytes: 0)
    ])
    await waitUntil { model.rows.first?.totalBytes == 0 }

    #expect(model.rows.first?.isDeleting == true)
  }

  @Test func noAPICallHappensOnConstruction() {
    let intents = FakeDownloadIntents()
    _ = StorageModel(storageReading: FakeStorageReading(), downloadIntents: intents)

    #expect(intents.calls.isEmpty)
  }

  @Test func selectedPurgeUsesExactItemScopeAndAttemptsEveryID() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["book": "Book", "show": "Show"])
    await model.purgeSelectedItemDownloads(["book"])
    #expect(intents.calls == [.purgeItemDownload(itemID: "book", source: .storage)])
  }

  @Test func selectedPurgeSkipsMissingAndAlreadyDeletingRows() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["book": "Book"])
    model.requestPurge(itemId: "book", title: "Book")
    await model.confirmPurge()?.value
    await model.purgeSelectedItemDownloads(["book", "missing"])
    #expect(intents.calls.count == 1)
  }

  @Test func selectedPurgeRetainsFailureUntilDismissedAndEmptySelectionClearsIt() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["book": "Book"])
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())
    await model.purgeSelectedItemDownloads(["book"])
    #expect(model.purgeErrorMessage == StorageCopy.purgeFailed)
    intents.stubNextCall(throwing: nil)
    await model.purgeSelectedItemDownloads([])
    #expect(model.purgeErrorMessage == nil)
  }

  @Test func selectedPurgeKeepsFailureAfterLaterSuccessfulRemoval() async {
    let reading = FakeStorageReading()
    let intents = SelectionPurgeTestIntents(failureID: "a")
    let model = StorageModel(storageReading: reading, downloadIntents: intents)
    await seedRows(reading, model: model, ["a": "A", "b": "B"])
    await model.purgeSelectedItemDownloads(["a", "b"])
    #expect(await intents.purgedItems == ["a", "b"])
    #expect(model.purgeErrorMessage == StorageCopy.purgeFailed)
    #expect(model.rows.first { $0.itemId == "a" }?.isDeleting == false)
    #expect(model.rows.first { $0.itemId == "b" }?.isDeleting == true)
  }

  @Test func lastStorageCeilingSummaryUsesThePersistedActualResult() async {
    let storageReading = FakeStorageReading()
    let intents = FakeDownloadIntents()
    let summaryReading = FakeStorageCeilingSummaryReading(
      initial: StorageCeilingEvictionSummary(
        capBytes: 100, removedBytes: 25, removedRows: 1, unmetBytes: 0))
    let model = StorageModel(
      storageReading: storageReading,
      downloadIntents: intents,
      storageCeilingSummary: summaryReading)

    #expect(model.lastStorageCeilingSummary?.removedBytes == 25)

    let next = StorageCeilingEvictionSummary(
      capBytes: 100, removedBytes: 40, removedRows: 2, unmetBytes: 10)
    summaryReading.push(next)
    await waitUntil { model.lastStorageCeilingSummary == next }

    #expect(model.lastStorageCeilingSummary == next)
    #expect(StorageCopy.storageCeilingEvictionSummary(next).contains("40"))
    #expect(StorageCopy.storageCeilingEvictionSummary(next).contains("protected"))
  }

  // MARK: - Purge confirmation flow (destructive copy)

  @Test func requestingAnItemPurgeShowsDestructiveConfirmationCopyAndDoesNotPurgeYet() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One"])

    model.requestPurge(itemId: "item-1", title: "Book One")

    #expect(model.pendingPurgeConfirmation == .item(itemId: "item-1", title: "Book One"))
    #expect(StorageCopy.purgeItemMessage(title: "Book One").contains("Book One"))
    #expect(
      StorageCopy.purgeItemMessage(title: "Book One").contains("all downloads"),
      "the same confirmation must accurately cover a multi-episode podcast")
    #expect(
      StorageCopy.purgeItemMessage(title: "Book One").contains("download them again") == false,
      "the confirmation should omit recovery guidance that adds noise")
    #expect(intents.calls.isEmpty)
  }

  @Test func cancellingAPurgeLeavesEverythingIntact() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One"])
    model.requestPurge(itemId: "item-1", title: "Book One")

    model.cancelPurge()

    #expect(model.pendingPurgeConfirmation == nil)
    await model.confirmPurge()?.value
    #expect(intents.calls.isEmpty, "a cancelled confirmation must never purge")
  }

  @Test func confirmingAnItemPurgeMarksItDeletingAndForwardsExactlyOnce() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One"])
    model.requestPurge(itemId: "item-1", title: "Book One")

    await model.confirmPurge()?.value

    #expect(model.rows.first?.isDeleting == true, "deleting progress must be visible immediately")
    #expect(intents.calls == [.purgeItemDownload(itemID: "item-1", source: .storage)])
    #expect(model.pendingPurgeConfirmation == nil)
  }

  @Test func requestingPurgeAllShowsDestructiveConfirmationCopy() {
    let (model, _, _) = makeModel()

    model.requestPurgeAll()

    #expect(model.pendingPurgeConfirmation == .all)
    #expect(
      StorageCopy.purgeAllMessage
        == "This removes all downloads from your server and from podcasts you follow on this device.")
    #expect(StorageCopy.purgeAllMessage.localizedCaseInsensitiveContains("rss") == false)
    #expect(StorageCopy.purgeAllMessage.localizedCaseInsensitiveContains("audiobookshelf") == false)
    #expect(StorageCopy.purgeAllMessage.contains("download them again") == false)
    #expect(
      StorageCopy.purgeAllAction.hasSuffix("?") == false,
      "the action that opens the confirmation is a command, not the confirmation's own question")
  }

  @Test func confirmingPurgeAllMarksEveryRowDeletingAndForwardsExactlyOnce() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One", "item-2": "Book Two"])
    model.requestPurgeAll()

    await model.confirmPurge()?.value

    #expect(model.rows.allSatisfy { $0.isDeleting })
    #expect(intents.calls == [.purgeAllDownloads(source: .storage)])
  }

  /// A confirmation alert writes `false` to its `isPresented` binding on every dismissal,
  /// including the one the Delete button itself causes, and the screen turns that write into
  /// `cancelPurge()`. If `confirmPurge` only read its staged target after suspending, the cancel
  /// would win, find nothing staged, and the purge would silently do nothing. A confirmation
  /// already given cannot be withdrawn by the dismissal that accompanies it.
  @Test func aConfirmedPurgeIsNotUndoneByTheDismissalThatAccompaniesIt() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One", "item-2": "Book Two"])
    model.requestPurgeAll()

    let confirmed = model.confirmPurge()
    model.cancelPurge()
    await confirmed?.value

    #expect(intents.calls == [.purgeAllDownloads(source: .storage)])
  }

  /// The other half of the same invariant, and the reason the alert can be dismissed at all: the
  /// staged target is gone the instant the confirmation is given, not one main-actor turn later.
  /// A deferred clear would leave the screen's `isPresented` getter reporting `true` after its
  /// own alert had been dismissed.
  @Test func confirmingClearsTheStagedTargetBeforeItSuspends() async {
    let (model, storageReading, _) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One"])
    model.requestPurge(itemId: "item-1", title: "Book One")

    let confirmed = model.confirmPurge()

    #expect(model.pendingPurgeConfirmation == nil, "nothing is left for a dismissal to cancel")
    #expect(model.rows.first?.isDeleting == true)
    await confirmed?.value
  }

  @Test func aFailedPurgeSurfacesRecoverablyRatherThanSilently() async {
    let (model, storageReading, intents) = makeModel()
    await seedRows(storageReading, model: model, ["item-1": "Book One", "item-2": "Book Two"])
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())
    model.requestPurgeAll()

    await model.confirmPurge()?.value

    #expect(model.purgeErrorMessage == StorageCopy.purgeFailed)
    #expect(
      model.rows.allSatisfy { $0.isDeleting == false },
      "a purge that failed must not leave every row reading Removing… forever")

    model.dismissPurgeError()
    #expect(model.purgeErrorMessage == nil)
  }

  // MARK: - Reclaiming a removed episode's stranded download

  @Test func rowsCarryStrandedEpisodeBytesAndOfferTheReclaimOnlyWhenThereAreSome() async {
    let (model, storageReading, _) = makeModel()
    #expect(model.hasTombstonedEpisodeBytes == false, "nothing is offered before any row arrives")

    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "book-1", title: "Book One", totalBytes: 1_000),
      DownloadedItemTotals(
        itemId: "show-1", title: "Show One", totalBytes: 2_000, tombstonedEpisodeBytes: 600),
    ])
    await waitUntil { model.rows.count == 2 }

    #expect(model.rows.map(\.tombstonedEpisodeBytes) == [0, 600])
    #expect(model.rows.map(\.hasTombstonedEpisodeBytes) == [false, true])
    #expect(model.tombstonedEpisodeBytes == 600, "the account figure is the sum of the rows'")
    #expect(model.hasTombstonedEpisodeBytes)
    #expect(model.canReclaimTombstonedEpisodeDownloads)
  }

  @Test func aLibraryWithNothingStrandedNeverOffersTheReclaim() async {
    let (model, storageReading, intents) = makeModel()
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "book-1", title: "Book One", totalBytes: 1_000)
    ])
    await waitUntil { model.rows.count == 1 }

    #expect(model.tombstonedEpisodeBytes == 0)
    #expect(model.hasTombstonedEpisodeBytes == false)
    #expect(model.canReclaimTombstonedEpisodeDownloads == false)

    model.requestReclaimTombstonedEpisodes()
    #expect(model.pendingPurgeConfirmation == nil, "nothing stranded, nothing to confirm")
    await model.confirmPurge()?.value
    #expect(intents.calls.isEmpty, "an unoffered action can never reach the intent")
  }

  @Test func requestingTheReclaimConfirmsFirstAndReclaimsNothingYet() async {
    let (model, storageReading, intents) = makeModel()
    await seedStrandedShow(storageReading, model: model)

    model.requestReclaimTombstonedEpisodes()

    #expect(model.pendingPurgeConfirmation == .tombstonedEpisodes(bytes: 600))
    #expect(intents.calls.isEmpty, "explicit intent means confirmed intent")
    model.cancelPurge()
    await model.confirmPurge()?.value
    #expect(intents.calls.isEmpty, "a cancelled reclaim must never purge")
  }

  @Test func confirmingTheReclaimForwardsTheIntentExactlyOnce() async {
    let (model, storageReading, intents) = makeModel()
    await seedStrandedShow(storageReading, model: model)
    model.requestReclaimTombstonedEpisodes()

    await model.confirmPurge()?.value

    #expect(intents.calls == [.purgeTombstonedEpisodeDownloads(source: .storage)])
    #expect(model.pendingPurgeConfirmation == nil)
    #expect(model.isReclaimingTombstonedEpisodes == false, "the in-flight mark clears on success")
    #expect(model.reclaimErrorMessage == nil)
    #expect(
      model.rows.allSatisfy { $0.isDeleting == false },
      "reclaiming a stranded episode never marks the whole show as being removed")
  }

  @Test func aFailedReclaimSurfacesRecoverablyRatherThanSilently() async {
    let (model, storageReading, intents) = makeModel()
    await seedStrandedShow(storageReading, model: model)
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())
    model.requestReclaimTombstonedEpisodes()

    await model.confirmPurge()?.value

    #expect(model.reclaimErrorMessage == StorageCopy.reclaimEpisodesFailed)
    #expect(model.reclaimErrorMessage?.isEmpty == false, "a failed tap must never look like nothing happened")
    #expect(model.isReclaimingTombstonedEpisodes == false)
    #expect(model.canReclaimTombstonedEpisodeDownloads, "the offer survives so the user can retry")

    model.dismissReclaimError()
    #expect(model.reclaimErrorMessage == nil)
  }

  @Test func reclaimCopyPresentsTheRealByteFigureAndNeverAFabricatedZero() {
    let figure = StorageCopy.formattedBytes(600)

    #expect(StorageCopy.reclaimEpisodesAction(bytes: 600).contains(figure))
    #expect(StorageCopy.reclaimEpisodesMessage(bytes: 600).contains(figure))
    #expect(
      StorageCopy.reclaimEpisodesTitle.hasSuffix("?"),
      "the confirmation is a question; the action that opens it is not")
    #expect(StorageCopy.reclaimEpisodesAction(bytes: 600).hasSuffix("?") == false)

    let strandedDetail = StorageCopy.itemSizeDetail(totalBytes: 2_000, removedEpisodeBytes: 600)
    #expect(strandedDetail.contains(StorageCopy.formattedBytes(2_000)))
    #expect(strandedDetail.contains(figure))
    #expect(
      strandedDetail
        == "\(StorageCopy.formattedBytes(2_000)), including \(figure) from removed episodes")

    let plainDetail = StorageCopy.itemSizeDetail(totalBytes: 2_000, removedEpisodeBytes: 0)
    #expect(plainDetail == StorageCopy.formattedBytes(2_000), "a zero share is never rendered at all")
    #expect(plainDetail.contains(StorageCopy.formattedBytes(0)) == false)
  }

  // MARK: - Low-disk banner state

  @Test func lowDiskStatusRefreshesFromDownloadIntents() async {
    let (model, _, intents) = makeModel()
    intents.queuePausedForLowDisk = true

    await model.refreshLowDiskStatus()

    #expect(model.isQueuePausedForLowDisk)
  }

  @Test func modelDeinitializesWhileItsObservationStreamsRemainAlive() async {
    let storageReading = FakeStorageReading()
    weak var observer: StorageModel?
    var model: StorageModel?

    do {
      model = StorageModel(storageReading: storageReading, downloadIntents: FakeDownloadIntents())
      observer = model
      storageReading.pushAccountTotals(StorageTotals(totalBytes: 12_345))
      #expect(await waitUntil { model?.accountTotalBytes == 12_345 })
      model = nil
    }

    #expect(await waitUntil { observer == nil })
  }

  // MARK: - Helpers

  private func makeModel() -> (StorageModel, FakeStorageReading, FakeDownloadIntents) {
    let storageReading = FakeStorageReading()
    let intents = FakeDownloadIntents()
    let model = StorageModel(storageReading: storageReading, downloadIntents: intents)
    return (model, storageReading, intents)
  }

  /// Seeds the rows the purge flow acts on the only way the model ever gets them: through
  /// `observeDownloadedItems()`.
  private func seedRows(
    _ storageReading: FakeStorageReading, model: StorageModel, _ titlesByItemId: [String: String]
  ) async {
    storageReading.pushDownloadedItems(
      titlesByItemId.sorted { $0.key < $1.key }.map {
        DownloadedItemTotals(itemId: $0.key, title: $0.value, totalBytes: 1_000)
      })
    await waitUntil { model.rows.count == titlesByItemId.count }
  }

  /// Seeds one show carrying 600 stranded bytes behind a soft-deleted episode, plus one ordinary
  /// book carrying none.
  private func seedStrandedShow(_ storageReading: FakeStorageReading, model: StorageModel) async {
    storageReading.pushDownloadedItems([
      DownloadedItemTotals(itemId: "book-1", title: "Book One", totalBytes: 1_000),
      DownloadedItemTotals(
        itemId: "show-1", title: "Show One", totalBytes: 2_000, tombstonedEpisodeBytes: 600),
    ])
    await waitUntil { model.tombstonedEpisodeBytes == 600 }
  }
}

private final class FakeStorageCeilingSummaryReading: StorageCeilingSummaryReading, @unchecked Sendable {
  private let lock = NSLock()
  private var summary: StorageCeilingEvictionSummary?
  private var continuation: AsyncStream<StorageCeilingEvictionSummary?>.Continuation?

  init(initial: StorageCeilingEvictionSummary?) {
    summary = initial
  }

  var lastStorageCeilingSummary: StorageCeilingEvictionSummary? {
    lock.lock()
    defer { lock.unlock() }
    return summary
  }

  var storageCeilingSummaryChanges: AsyncStream<StorageCeilingEvictionSummary?> {
    AsyncStream { continuation in
      lock.lock()
      self.continuation = continuation
      lock.unlock()
    }
  }

  func push(_ summary: StorageCeilingEvictionSummary) {
    lock.lock()
    self.summary = summary
    let continuation = self.continuation
    lock.unlock()
    continuation?.yield(summary)
  }
}
