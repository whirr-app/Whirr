import Foundation
import SyncEngine
import Testing

@testable import AppModel

@MainActor
@Suite struct PodcastCloudSyncControlsTests {
  @Test func withoutARunningServiceTheScreenOffersNothingThatReachesTheCloud() async {
    let model = PodcastCloudSyncControlsModel(controller: nil)
    await model.refresh()
    #expect(model.isAvailable == false)
    #expect(model.statusText == nil)
    #expect(model.showsStatus == false)
    #expect(model.lastSyncedNote == nil)
    #expect(model.offersRetry == false)
    #expect(model.canSyncNow == false)
    model.requestDeletion()
    #expect(model.deletion == .idle)
  }

  @Test func everyStatusReadsAsTextFromTheApprovedVocabulary() {
    let cases: [(PodcastCloudSyncStatus, String)] = [
      (.upToDate, "Up to Date"),
      (.bootstrapping, "Syncing"),
      (.waiting(until: nil), "Waiting for iCloud — Whirr will keep trying"),
      (.accountUnavailable, "Sign in to iCloud to sync"),
      (.quotaExceeded, "iCloud storage is full"),
      (.needsAttention, "Sync needs attention"),
      (.interrupted, "Sync needs attention"),
      (.clockRepairRequired, "Sync needs attention"),
      (.zoneLost(.userDeletedZone), "Sync needs attention"),
      (.off, "Off"),
    ]
    for (status, text) in cases {
      #expect(PodcastCloudSyncStatusPresentation.text(for: status) == text)
    }
  }

  /// The status alone does not say whether anything is wrong with the listener's data; the note
  /// under it does.
  @Test func needsAttentionSaysWhetherARetryWillClearIt() async {
    let retrying = "Some changes haven’t synced yet. Whirr will keep trying."
    let held = "Some podcast data couldn’t be synced. It’s kept on this device."
    #expect(PodcastCloudSyncStatusPresentation.note(for: .interrupted) == retrying)
    let heldStatuses: [PodcastCloudSyncStatus] = [
      .needsAttention, .clockRepairRequired, .zoneLost(.zoneNotFound),
    ]
    for status in heldStatuses {
      #expect(PodcastCloudSyncStatusPresentation.note(for: status) == held)
    }
    let quiet: [PodcastCloudSyncStatus] = [
      .off, .bootstrapping, .upToDate, .waiting(until: nil), .accountUnavailable, .quotaExceeded,
    ]
    for status in quiet {
      #expect(PodcastCloudSyncStatusPresentation.note(for: status) == nil)
    }

    let model = PodcastCloudSyncControlsModel(controller: FakeController(status: .interrupted))
    #expect(model.statusNote == nil)
    await model.refresh()
    #expect(model.statusNote == retrying)
  }

  @Test func syncNowReportsTheStatusItLeftBehindAndAFailure() async {
    let controller = FakeController(status: .waiting(until: nil))
    let model = PodcastCloudSyncControlsModel(controller: controller)
    await model.refresh()
    #expect(model.statusText == "Waiting for iCloud — Whirr will keep trying")

    await controller.set(status: .upToDate)
    await model.syncNow()
    #expect(await controller.syncCount == 1)
    #expect(model.statusText == "Up to Date")
    #expect(model.syncFailed == false)
    #expect(model.isSyncing == false)

    await controller.set(syncError: true)
    await model.syncNow()
    #expect(model.syncFailed)
  }

  /// Sync that is working is silent: the screen shows a status only when it has something to say,
  /// and a retry only where one can clear it. The engine retries everything else by itself.
  @Test func aHealthySyncShowsNoStatusAndOnlyARetryableOneOffersTryAgain() async {
    let controller = FakeController(status: .upToDate)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    #expect(model.showsStatus == false, "nothing to show before the service is asked")
    await model.refresh()
    #expect(model.showsStatus == false)
    #expect(model.offersRetry == false)

    let cases: [(PodcastCloudSyncStatus, retry: Bool)] = [
      (.bootstrapping, false), (.waiting(until: nil), false), (.accountUnavailable, false),
      (.quotaExceeded, true), (.interrupted, true), (.needsAttention, true),
      (.clockRepairRequired, false), (.zoneLost(.zoneNotFound), false),
    ]
    for (status, retry) in cases {
      await controller.set(status: status)
      await model.refresh()
      #expect(model.showsStatus, "\(status)")
      #expect(model.offersRetry == retry, "\(status)")
    }

    await controller.set(status: .upToDate)
    await controller.set(syncError: true)
    await model.syncNow()
    #expect(model.offersRetry, "a retry that failed stays on offer")

    await model.refresh()
    #expect(model.offersRetry == false, "until the engine reports it has caught up by itself")
    #expect(model.syncFailed == false)
  }

  @Test func theLastSyncIsNotedOnlyOnceTheServiceRecordsOne() async {
    let controller = FakeController(status: .waiting(until: nil))
    let model = PodcastCloudSyncControlsModel(controller: controller)
    await model.refresh()
    #expect(model.lastSyncedNote == nil)

    await controller.set(lastSuccessfulSync: Date(timeIntervalSinceNow: -2 * 3_600))
    await model.refresh()
    #expect(model.lastSyncedNote == "Last synced 2 hours ago")
  }

  @Test func deletionNeedsAConfirmationThatItsDismissalCannotUndo() async {
    let controller = FakeController(status: .upToDate)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    #expect(model.confirmDeletion() == nil)
    #expect(await controller.deleteCount == 0, "no deletion without the confirmation step")

    model.requestDeletion()
    #expect(model.deletion == .confirming)
    model.cancelDeletion()
    #expect(model.deletion == .idle)

    // A dialog reports its dismissal after the button's action: that must not read as Cancel.
    model.requestDeletion()
    let deleting = model.confirmDeletion()
    model.cancelDeletion()
    #expect(model.deletion == .deleting)
    await deleting?.value
    #expect(model.deletion == .deleted)
    #expect(await controller.deleteCount == 1)
  }

  @Test func cancelBeforeConfirmingSendsNothing() async {
    let controller = FakeController(status: .upToDate)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    model.requestDeletion()
    model.cancelDeletion()
    #expect(model.deletion == .idle)
    #expect(await controller.deleteCount == 0)
  }

  @Test func deletionIsReportedDoneOnlyWhenTheServiceTurnedSyncOff() async {
    let controller = FakeController(status: .upToDate, statusAfterDelete: .off)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    model.requestDeletion()
    await model.confirmDeletion()?.value
    #expect(model.deletion == .deleted)

    // Offline: the service returns without having seen the zone go, and stays on.
    let offline = FakeController(status: .upToDate, statusAfterDelete: .needsAttention)
    let second = PodcastCloudSyncControlsModel(controller: offline)
    second.requestDeletion()
    await second.confirmDeletion()?.value
    #expect(second.deletion == .failed)
    second.dismissDeletionResult()
    #expect(second.deletion == .idle)
  }

  @Test func aThrownDeletionIsAFailure() async {
    let controller = FakeController(status: .upToDate, deleteError: true)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    model.requestDeletion()
    await model.confirmDeletion()?.value
    #expect(model.deletion == .failed)
  }

  @Test func onlyALostZoneAndAQuarantinedClockOfferARecovery() async {
    typealias Presentation = PodcastCloudSyncStatusPresentation
    #expect(Presentation.recovery(for: .zoneLost(.zoneNotFound)) == .recreateZone)
    #expect(Presentation.recovery(for: .zoneLost(.userDeletedZone)) == .recreateZone)
    #expect(Presentation.recovery(for: .clockRepairRequired) == .repairClock)
    let none: [PodcastCloudSyncStatus] = [
      .off, .bootstrapping, .upToDate, .waiting(until: nil), .accountUnavailable, .quotaExceeded,
      .needsAttention, .interrupted,
    ]
    for status in none {
      #expect(Presentation.recovery(for: status) == nil, "\(status)")
    }

    #expect(PodcastDataSettingsCopy.recoveryTitle(for: .recreateZone) == "Set Up iCloud Sync Again")
    #expect(PodcastDataSettingsCopy.recoveryTitle(for: .repairClock) == "Try Again")

    let unavailable = PodcastCloudSyncControlsModel(controller: nil)
    #expect(unavailable.recoveryAction == nil)
    #expect(unavailable.requestRecovery() == nil)
  }

  /// J7: the zone is recreated, and this device's podcasts uploaded, only after a confirmation.
  @Test func aLostZoneIsRecreatedOnlyAfterConfirmation() async {
    let controller = FakeController(status: .zoneLost(.userDeletedZone))
    let model = PodcastCloudSyncControlsModel(controller: controller)
    await model.refresh()
    #expect(model.recoveryAction == .recreateZone)
    #expect(model.confirmRecovery() == nil, "nothing to confirm before the request")

    #expect(model.requestRecovery() == nil)
    #expect(model.recovery == .confirming)
    model.cancelRecovery()
    #expect(model.recovery == .idle)
    #expect(await controller.zoneRecoveryCount == 0, "Cancel uploads nothing")
    #expect(model.recoveryAction == .recreateZone, "and keeps the recovery on offer")

    // A dialog reports its dismissal after the button's action: that must not read as Cancel.
    model.requestRecovery()
    let recovering = model.confirmRecovery()
    model.cancelRecovery()
    #expect(model.recovery == .recovering)
    #expect(model.canRecover == false)
    await recovering?.value
    #expect(await controller.zoneRecoveryCount == 1)
    #expect(model.recovery == .idle)
    #expect(model.status == .upToDate)
    #expect(model.recoveryAction == nil)
  }

  @Test func aClockRepairStartsOnRequestAndClearsTheStatus() async {
    let controller = FakeController(status: .clockRepairRequired)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    await model.refresh()
    #expect(model.recoveryAction == .repairClock)

    await model.requestRecovery()?.value

    #expect(await controller.clockRepairCount == 1)
    #expect(await controller.zoneRecoveryCount == 0)
    #expect(model.recovery == .idle)
    #expect(model.status == .upToDate)
  }

  @Test func aRecoveryThatThrowsOrChangesNothingIsAFailureAndStaysOnOffer() async {
    let controller = FakeController(status: .clockRepairRequired)
    await controller.set(recoveryError: true)
    let model = PodcastCloudSyncControlsModel(controller: controller)
    await model.refresh()

    await model.requestRecovery()?.value
    #expect(model.recovery == .failed)
    #expect(model.canRecover, "the listener can ask again")

    // The clock is still wrong, so the repair returned and the next admission quarantined again.
    await controller.set(recoveryError: false)
    await controller.set(statusAfterRecovery: .clockRepairRequired)
    await model.requestRecovery()?.value
    #expect(await controller.clockRepairCount == 2)
    #expect(model.recovery == .failed)

    await controller.set(status: .upToDate)
    await model.refresh()
    #expect(model.recovery == .idle, "a failure note does not outlast the state it was about")
  }
}

private actor FakeController: PodcastCloudSyncControlling {
  struct Failure: Error {}

  private var current: PodcastCloudSyncStatus
  private let statusAfterDelete: PodcastCloudSyncStatus
  private var syncError = false
  private var lastSync: Date?
  private let deleteError: Bool
  private(set) var syncCount = 0
  private(set) var deleteCount = 0

  init(
    status: PodcastCloudSyncStatus, statusAfterDelete: PodcastCloudSyncStatus = .off,
    deleteError: Bool = false
  ) {
    current = status
    self.statusAfterDelete = statusAfterDelete
    self.deleteError = deleteError
  }

  func set(status: PodcastCloudSyncStatus) { current = status }
  func set(syncError: Bool) { self.syncError = syncError }
  func set(lastSuccessfulSync: Date?) { lastSync = lastSuccessfulSync }

  func status() async -> PodcastCloudSyncStatus { current }
  func lastSuccessfulSync() async -> Date? { lastSync }

  func syncNow() async throws {
    syncCount += 1
    if syncError { throw Failure() }
  }

  func deleteCloudData() async throws {
    deleteCount += 1
    if deleteError { throw Failure() }
    current = statusAfterDelete
  }

  private var recoveryError = false
  private var statusAfterRecovery: PodcastCloudSyncStatus = .upToDate
  private(set) var zoneRecoveryCount = 0
  private(set) var clockRepairCount = 0

  func set(recoveryError: Bool) { self.recoveryError = recoveryError }
  func set(statusAfterRecovery: PodcastCloudSyncStatus) { self.statusAfterRecovery = statusAfterRecovery }

  func recoverFromZoneLoss() async throws {
    zoneRecoveryCount += 1
    if recoveryError { throw Failure() }
    current = statusAfterRecovery
  }

  func repairClock() async throws {
    clockRepairCount += 1
    if recoveryError { throw Failure() }
    current = statusAfterRecovery
  }
}
