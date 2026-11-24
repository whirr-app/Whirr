import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

/// `ItemDownloadModel` renders one state per item from `DownloadReading
/// .observeItemDownloadStatus` and forwards download/pause/resume/remove intents to
/// `DownloadIntents`. It never talks to the network itself.
@MainActor
@Suite struct ItemDownloadModelTests {

  private static let itemID = "item-1"

  @Test func noAPICallHappensOnConstruction() {
    let reading = FakeDownloadReading()
    let intents = FakeDownloadIntents()
    _ = ItemDownloadModel(itemID: Self.itemID, downloadReading: reading, downloadIntents: intents)

    #expect(intents.calls.isEmpty)
  }

  @Test func initializerDoesNotReadDownloadStatusSynchronously() {
    let reading = FakeDownloadReading()
    _ = ItemDownloadModel(
      itemID: Self.itemID, downloadReading: reading, downloadIntents: FakeDownloadIntents())

    #expect(reading.synchronousReadCount == 0)
  }

  @Test func observedStatusWinsOverAnOlderAsyncSeed() async {
    let reading = FakeDownloadReading()
    reading.asyncStatusGate.hold()
    let model = ItemDownloadModel(
      itemID: Self.itemID, downloadReading: reading, downloadIntents: FakeDownloadIntents())

    #expect(await waitUntil(timeout: 0.1) { reading.asyncReadStarted })

    reading.pushStatus(.completed, itemId: Self.itemID)
    reading.asyncStatusGate.release(.queued)

    #expect(await waitUntil { reading.asyncReadCompleted })
    // Only the settled value is a guarantee. Whether the stale `.queued` seed is ever visible in
    // between depends on how quickly the observation loop is scheduled, so requiring this test to
    // catch that transient would assert a race rather than the contract. Were the seed applied
    // after the observed status instead, this wait would time out on a latched `.queued`.
    #expect(await waitUntil { model.status == .completed })
    #expect(reading.asyncReadStarted)
    #expect(model.status == .completed)
  }

  @Test("the item model exposes live status for each requested format")
  func observedFormatStatusUpdatesIndependently() async {
    let (model, reading, _) = makeModel()
    let status = ItemFormatDownloadStatus(audio: .completed, ebook: .queued)

    reading.pushFormatStatus(status, itemId: Self.itemID)

    #expect(await waitUntil { model.formatStatus == status })
    #expect(model.formatStatus.audio == .completed)
    #expect(model.formatStatus.ebook == .queued)
    #expect(model.isDownloaded == false, "one incomplete format keeps the item partial")
  }

  @Test("the initial download state arrives without a synchronous read")
  func initialStatusArrivesAsynchronously() async {
    let reading = FakeDownloadReading()
    reading.stubCurrentStatus(.completed)
    let model = ItemDownloadModel(
      itemID: Self.itemID, downloadReading: reading, downloadIntents: FakeDownloadIntents())

    #expect(model.hasResolvedInitialStatus == false)
    #expect(await waitUntil { model.status == .completed })
    #expect(model.status == .completed)
    #expect(model.hasResolvedInitialStatus)
  }

  @Test("the placeholder is not marked resolved while the initial read is suspended")
  func initialStatusRemainsUnresolvedUntilTheAsyncSeedArrives() async {
    let reading = FakeDownloadReading()
    reading.asyncStatusGate.hold()
    let model = ItemDownloadModel(
      itemID: Self.itemID, downloadReading: reading, downloadIntents: FakeDownloadIntents())

    #expect(await waitUntil(timeout: 0.1) { reading.asyncReadStarted })
    #expect(model.status == .notDownloaded)
    #expect(model.hasResolvedInitialStatus == false)

    reading.asyncStatusGate.release(.completed)

    #expect(await waitUntil { model.hasResolvedInitialStatus })
    #expect(model.status == .completed)
  }

  @Test("a warm seed resolves the status at construction, without waiting for the read")
  func aWarmSeedIsAppliedSynchronously() async {
    let reading = FakeDownloadReading()
    reading.asyncStatusGate.hold()
    let model = ItemDownloadModel(
      itemID: Self.itemID, initialStatus: .completed, downloadReading: reading,
      downloadIntents: FakeDownloadIntents())

    // Nothing has been awaited: the control this feeds renders its destructive branch on the very
    // first frame instead of hiding until the database answers.
    #expect(model.status == .completed)
    #expect(model.hasResolvedInitialStatus)
    #expect(await waitUntil(timeout: 0.1) { reading.asyncReadStarted })
    #expect(model.status == .completed)
    // Answer the parked read so its watchdog does not fire later, inside another test.
    reading.asyncStatusGate.release(.completed)
  }

  @Test("the observed status still wins over a warm seed")
  func observedStatusOverridesAWarmSeed() async {
    let reading = FakeDownloadReading()
    reading.asyncStatusGate.hold()
    let model = ItemDownloadModel(
      itemID: Self.itemID, initialStatus: .completed, downloadReading: reading,
      downloadIntents: FakeDownloadIntents())
    #expect(model.status == .completed)

    reading.asyncStatusGate.release(.notDownloaded)
    reading.pushStatus(.downloading(progressFraction: 0.4), itemId: Self.itemID)

    #expect(await waitUntil { model.status == .downloading(progressFraction: 0.4) })
  }

  @Test func notDownloadedShowsExactCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }

    #expect(model.statusText == ItemDownloadCopy.notDownloaded)
    #expect(model.isDownloaded == false)
    #expect(model.isAvailableOffline == false)
  }

  @Test func waitingForWiFiShowsTheCellularOptInExplanation() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.waitingForWiFi, itemId: Self.itemID)
    await waitUntil { model.status == .waitingForWiFi }

    #expect(model.statusText == ItemDownloadCopy.waitingForWiFi)
    #expect(
      model.statusText.contains("Wi-Fi"),
      "the cellular-opt-in explanation must mention Wi-Fi")
    #expect(
      model.statusText.contains("Settings"),
      "the cellular-opt-in explanation must point at where cellular downloads are enabled")
  }

  @Test func queuedShowsExactCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.queued, itemId: Self.itemID)
    await waitUntil { model.status == .queued }

    #expect(model.statusText == ItemDownloadCopy.queued)
  }

  @Test func downloadingShowsProgressInTheCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.downloading(progressFraction: 0.42), itemId: Self.itemID)
    await waitUntil {
      if case .downloading = model.status { return true }
      return false
    }

    #expect(model.statusText == ItemDownloadCopy.downloading(progressFraction: 0.42))
    #expect(model.statusText.contains("42"))
  }

  @Test func pausedShowsExactCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.paused, itemId: Self.itemID)
    await waitUntil { model.status == .paused }

    #expect(model.statusText == ItemDownloadCopy.paused)
  }

  @Test func pausedAuthShowsExactCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.pausedAuth, itemId: Self.itemID)
    await waitUntil { model.status == .pausedAuth }

    #expect(model.statusText == ItemDownloadCopy.pausedAuth)
  }

  @Test func interruptedShowsExactCopy() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.interrupted, itemId: Self.itemID)
    await waitUntil { model.status == .interrupted }

    #expect(model.statusText == ItemDownloadCopy.interrupted)
  }

  @Test func completedShowsExactCopyAndSetsDownloadedOfflineBadges() async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.completed, itemId: Self.itemID)
    await waitUntil { model.status == .completed }

    #expect(model.statusText == ItemDownloadCopy.completed)
    #expect(model.isDownloaded)
    #expect(model.isAvailableOffline)
  }

  @Test(
    "failed shows a distinct message per category, including lowDisk and validation",
    arguments: [
      DownloadErrorCategory.transport, .auth, .validation, .storage, .lowDisk, .unknown,
    ]
  )
  func failedShowsDistinctCopyPerCategory(category: DownloadErrorCategory) async {
    let (model, reading, _) = makeModel()
    reading.pushStatus(.failed(category: category), itemId: Self.itemID)
    await waitUntil { model.status == .failed(category: category) }

    #expect(model.statusText == ItemDownloadCopy.failed(category: category))
  }

  @Test func everyFailureCategoryHasADistinctMessage() {
    let categories: [DownloadErrorCategory] = [.transport, .auth, .validation, .storage, .lowDisk, .unknown]
    let messages = Set(categories.map(ItemDownloadCopy.failed(category:)))
    #expect(messages.count == categories.count, "two categories must never share a message")
  }

  @Test func deletingShowsExactCopyAndDisablesEveryIntentUntilRemovalFinishes() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.deleting, itemId: Self.itemID)
    await waitUntil { model.status == .deleting }

    #expect(model.statusText == ItemDownloadCopy.deleting)
    #expect(model.isActionable == false)

    await model.requestDownload()
    await model.pause()
    await model.resume()
    await model.remove()

    #expect(intents.calls.isEmpty, "every intent must be a no-op while deleting")
  }

  @Test("an audiobook-category download uses the audio intent")
  func audiobookCategoryRequestDownloadUsesAudioIntent() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }

    await model.requestDownload(category: .audiobook)

    #expect(intents.calls == [.requestDownload(itemID: Self.itemID)])
  }

  @Test("an ebook-category download uses the ebook intent, never the audio intent")
  func ebookCategoryRequestDownloadUsesEbookIntent() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }

    await model.requestDownload(category: .ebook)

    #expect(intents.calls == [.requestEbookDownload(itemID: Self.itemID)])
  }

  @Test("explicit format requests expose audio, ebook, and concurrent both intents")
  func explicitFormatRequestsForwardToTheMatchingIntents() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }

    await model.requestAudioDownload()
    await model.requestEbookDownload()
    await model.requestBothDownloads()

    #expect(intents.calls.count == 4)
    #expect(intents.calls[0] == .requestDownload(itemID: Self.itemID))
    #expect(intents.calls[1] == .requestEbookDownload(itemID: Self.itemID))
    let bothCalls = Array(intents.calls.dropFirst(2))
    #expect(bothCalls.count == 2)
    #expect(bothCalls.contains(.requestDownload(itemID: Self.itemID)))
    #expect(bothCalls.contains(.requestEbookDownload(itemID: Self.itemID)))
  }

  @Test func pauseForwardsExactlyOnce() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.downloading(progressFraction: 0.1), itemId: Self.itemID)
    await waitUntil {
      if case .downloading = model.status { return true }
      return false
    }

    await model.pause()

    #expect(intents.calls == [.pauseItemDownload(itemID: Self.itemID)])
  }

  @Test func resumeForwardsExactlyOnce() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.paused, itemId: Self.itemID)
    await waitUntil { model.status == .paused }

    await model.resume()

    #expect(intents.calls == [.resumeItemDownload(itemID: Self.itemID)])
  }

  @Test func removeForwardsExactlyOnce() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.completed, itemId: Self.itemID)
    await waitUntil { model.status == .completed }

    await model.remove()

    #expect(
      intents.calls == [.purgeItemDownload(itemID: Self.itemID, source: .itemDetail)])
  }

  // MARK: - Failed intents are never silent

  @Test func aRejectedDownloadPlanSurfacesItsOwnActionableMessage() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }
    intents.stubNextCall(throwing: DownloadPlanningError.metadataValidationFailed)

    await model.requestDownload()

    #expect(
      model.actionErrorMessage
        == ItemDownloadCopy.actionFailed(.download, error: DownloadPlanningError.metadataValidationFailed))
    #expect(model.actionErrorMessage?.isEmpty == false, "a failed tap must never look like nothing happened")
  }

  /// None of the three ebook planning refusals clears by tapping Download again, so the generic
  /// per-action retry line would be advice that cannot work. Each names its own cause.
  @Test func eachEbookPlanningRefusalExplainsItselfRatherThanSayingTryAgain() async {
    struct Opaque: Error {}
    let generic = ItemDownloadCopy.actionFailed(.download, error: Opaque())
    let messages = [
      EbookDownloadPlanningError.ebookFileUnavailable,
      .unsupportedEbookFormat,
      .missingExpectedSize,
    ].map { ItemDownloadCopy.actionFailed(.download, error: $0) }

    #expect(Set(messages).count == 3, "two different causes never share a message")
    #expect(messages.contains(generic) == false)
    #expect(messages.allSatisfy { $0.isEmpty == false })
  }

  @Test func aFailedEbookPlanReachesTheModelsOwnMessage() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }
    intents.stubNextCall(throwing: EbookDownloadPlanningError.missingExpectedSize)

    await model.requestDownload()

    #expect(
      model.actionErrorMessage
        == ItemDownloadCopy.actionFailed(
          .download, error: EbookDownloadPlanningError.missingExpectedSize))
  }

  @Test func eachFailedActionExplainsThatActionSpecifically() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.completed, itemId: Self.itemID)
    await waitUntil { model.status == .completed }
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())

    await model.remove()

    #expect(model.actionErrorMessage == ItemDownloadCopy.actionFailed(.remove, error: Opaque()))
    #expect(
      ItemDownloadCopy.actionFailed(.remove, error: Opaque())
        != ItemDownloadCopy.actionFailed(.download, error: Opaque()),
      "two different actions never share a failure message")
  }

  @Test func aSucceedingActionClearsAPreviousFailure() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())
    await model.requestDownload()
    #expect(model.actionErrorMessage != nil)

    intents.stubNextCall(throwing: nil)
    await model.requestDownload()

    #expect(model.actionErrorMessage == nil)
  }

  @Test func dismissingTheFailureClearsIt() async {
    let (model, reading, intents) = makeModel()
    reading.pushStatus(.notDownloaded, itemId: Self.itemID)
    await waitUntil { model.status == .notDownloaded }
    struct Opaque: Error {}
    intents.stubNextCall(throwing: Opaque())
    await model.requestDownload()

    model.dismissActionError()

    #expect(model.actionErrorMessage == nil)
  }

  // MARK: - Helpers

  private func makeModel() -> (ItemDownloadModel, FakeDownloadReading, FakeDownloadIntents) {
    let reading = FakeDownloadReading()
    let intents = FakeDownloadIntents()
    let model = ItemDownloadModel(itemID: Self.itemID, downloadReading: reading, downloadIntents: intents)
    return (model, reading, intents)
  }
}

extension FakeDownloadReading {
  fileprivate var asyncReadStarted: Bool { statusReads.calls.contains(.asyncStarted) }
  fileprivate var asyncReadCompleted: Bool { statusReads.calls.contains(.asyncCompleted) }
  fileprivate var synchronousReadCount: Int {
    statusReads.calls.filter { $0 == .synchronous }.count
  }
}

/// The two offline-playback copy strings in `PlaybackCopy`. They belong to item-download and
/// offline-play states but stay in `PlaybackCopy` because `PlaybackModel.startFailureMessage`, not
/// `ItemDownloadModel` (whose own catalog is `ItemDownloadCopy`), is what renders them.
@Suite struct PlaybackOfflineCopyTests {
  @Test func localSourceUnavailableExplainsTheInFlightRemoval() {
    let message = PlaybackCopy.startFailureMessage(
      for: PlaybackCoordinatorError.localSourceUnavailable(itemID: "item-1"))
    #expect(message == "This download is being removed. Try again once it finishes.")
  }

  @Test func unplayableOfflineExplainsThereIsNoWayToPlayRightNow() {
    let message = PlaybackCopy.startFailureMessage(
      for: PlaybackCoordinatorError.unplayableOffline(itemID: "item-1"))
    #expect(message == "This title isn't downloaded and the server can't be reached right now.")
  }
}
