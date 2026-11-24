import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

/// `SettingsModel` owns the cellular-download toggle and the destructive logout
/// warning/confirmation flow, forwarding to `DownloadPreferences`/`AccountLifecycle.logout()`.
@MainActor
@Suite struct SettingsModelTests {

  // MARK: - Cellular toggle

  @Test func startsFromDownloadPreferencesCurrentValue() {
    let preferences = FakeDownloadPreferences(allowCellular: true)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.allowCellularDownloads)
  }

  @Test func settingTheToggleSetsItPersistsThroughDownloadPreferences() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await model.setAllowCellularDownloads(true)

    #expect(preferences.allowCellular)
    #expect(model.allowCellularDownloads)
  }

  @Test func toggleReflectsExternalDownloadPreferencesChanges() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await preferences.setAllowCellular(true)
    await waitUntil { model.allowCellularDownloads }

    #expect(model.allowCellularDownloads)
  }

  @Test func cellularCopyExplainsWhatTheToggleDoes() {
    #expect(SettingsCopy.cellularDownloadsToggleTitle.localizedCaseInsensitiveContains("mobile"))
  }

  // MARK: - Delete when finished toggle

  @Test func startsFromDeleteWhenFinishedPreferenceCurrentValue() {
    let preferences = FakeDownloadPreferences(deleteWhenFinished: true)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.deleteDownloadsWhenFinished)
  }

  @Test func settingDeleteWhenFinishedPersistsThroughDownloadPreferences() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await model.setDeleteDownloadsWhenFinished(true)

    #expect(preferences.deleteWhenFinished)
    #expect(model.deleteDownloadsWhenFinished)
  }

  @Test func deleteWhenFinishedReflectsExternalPreferenceChanges() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await preferences.setDeleteWhenFinished(true)
    await waitUntil { model.deleteDownloadsWhenFinished }

    #expect(model.deleteDownloadsWhenFinished)
  }

  // MARK: - Queue auto-download policy

  @Test func startsFromQueueAutoDownloadPolicyCurrentValue() {
    let preferences = FakeDownloadPreferences(queueAutoDownloadPolicy: .wifiOnly)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.queueAutoDownloadPolicy == .wifiOnly)
  }

  @Test func settingQueueAutoDownloadPolicyPersistsThroughDownloadPreferences() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await model.setQueueAutoDownloadPolicy(.always)

    #expect(preferences.queueAutoDownloadPolicy == .always)
    #expect(model.queueAutoDownloadPolicy == .always)
  }

  @Test func queueAutoDownloadPolicyReflectsExternalPreferenceChanges() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await preferences.setQueueAutoDownloadPolicy(.wifiOnly)
    await waitUntil { model.queueAutoDownloadPolicy == .wifiOnly }

    #expect(model.queueAutoDownloadPolicy == .wifiOnly)
  }

  // MARK: - Saved for Later auto-download policy

  @Test func startsFromSavedShelfAutoDownloadPolicyCurrentValue() {
    let preferences = FakeDownloadPreferences(savedShelfAutoDownloadPolicy: .always)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.savedShelfAutoDownloadPolicy == .always)
  }

  @Test func settingSavedShelfAutoDownloadPolicyPersistsThroughDownloadPreferences() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await model.setSavedShelfAutoDownloadPolicy(.wifiOnly)

    #expect(preferences.savedShelfAutoDownloadPolicy == .wifiOnly)
    #expect(model.savedShelfAutoDownloadPolicy == .wifiOnly)
  }

  @Test func savedShelfAutoDownloadPolicyReflectsExternalPreferenceChanges() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await preferences.setSavedShelfAutoDownloadPolicy(.always)
    await waitUntil { model.savedShelfAutoDownloadPolicy == .always }

    #expect(model.savedShelfAutoDownloadPolicy == .always)
  }

  /// The two pickers sit in one section, so they answer with the same three words; only the
  /// question differs.
  @Test func savedShelfAutoDownloadCopyMatchesTheQueuePickersVocabulary() {
    for policy in SavedShelfAutoDownloadPolicy.allCases {
      let queueEquivalent = QueueAutoDownloadPolicy(rawValue: policy.rawValue)
      #expect(queueEquivalent != nil)
      #expect(
        SettingsCopy.savedShelfAutoDownloadLabel(policy)
          == SettingsCopy.queueAutoDownloadLabel(queueEquivalent ?? .never))
    }
  }

  /// The two preferences are independent: enabling one must not silently enable the other.
  @Test func theTwoAutoDownloadPoliciesDoNotShareStorage() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await model.setSavedShelfAutoDownloadPolicy(.always)

    #expect(model.queueAutoDownloadPolicy == .never)
    #expect(preferences.queueAutoDownloadPolicy == .never)
  }

  // MARK: - Storage ceiling

  @Test func startsFromFiniteStorageCeilingPreferenceCurrentValue() {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: StorageCeiling.gigabytes(8).bytes)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.storageCeiling == .gigabytes(8))
  }

  @Test func startsFromUnlimitedStorageCeilingPreferenceCurrentValue() {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.storageCeiling == .unlimited)
  }

  @Test func noOpDeviceCapacityReaderReturnsUnavailable() async {
    #expect(await NoOpDeviceStorageCapacityReading().availableCapacityBytes() == nil)
  }

  @Test func storageObservationsDeliverInitialValuesAndSubsequentUpdates() async {
    let reading = FakeStorageReading(
      accountTotals: StorageTotals(totalBytes: 6_000), completedDownloadBytes: 5_000)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading)

    model.startObservingStorage()
    await waitUntil {
      model.downloadedBytes == 6_000 && model.completedDownloadBytes == 5_000
    }

    #expect(model.hasLoadedDownloadedBytes)
    #expect(model.hasLoadedCompletedDownloadBytes)

    reading.pushAccountTotals(StorageTotals(totalBytes: 8_000))
    reading.pushCompletedDownloadTotals(7_000)
    await waitUntil {
      model.downloadedBytes == 8_000 && model.completedDownloadBytes == 7_000
    }
  }

  @Test func startingStorageObservationTwiceOpensOneSubscription() {
    let reading = FakeStorageReading()
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading)

    model.startObservingStorage()
    model.startObservingStorage()

    #expect(reading.accountObservationCount == 1)
    #expect(reading.completedObservationCount == 1)
    #expect(reading.breakdownObservationCount == 1)
  }

  @Test func stoppingStorageObservationCancelsAndRetainsLastValues() async {
    let reading = FakeStorageReading(
      accountTotals: StorageTotals(totalBytes: 6_000), completedDownloadBytes: 5_000)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading)
    model.startObservingStorage()
    await waitUntil {
      model.downloadedBytes == 6_000 && model.completedDownloadBytes == 5_000
    }

    model.stopObservingStorage()
    await waitUntil {
      reading.activeAccountObservationCount == 0
        && reading.activeCompletedObservationCount == 0
        && reading.activeBreakdownObservationCount == 0
    }
    reading.pushAccountTotals(StorageTotals(totalBytes: 9_000))
    reading.pushCompletedDownloadTotals(8_000)
    await awaitQuiescence(
      "stopped storage observations to settle",
      of: {
        "downloaded=\(String(describing: model.downloadedBytes)), completed=\(String(describing: model.completedDownloadBytes))"
      })

    #expect(model.downloadedBytes == 6_000)
    #expect(model.completedDownloadBytes == 5_000)
    #expect(model.hasLoadedDownloadedBytes)
    #expect(model.hasLoadedCompletedDownloadBytes)
  }

  @Test func childStartBeforeParentStopKeepsStorageObservationRunning() async {
    let reading = FakeStorageReading()
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading)
    model.startObservingStorage()

    model.startObservingStorage()
    model.stopObservingStorage()
    reading.pushAccountTotals(StorageTotals(totalBytes: 7_000))

    await waitUntil { model.downloadedBytes == 7_000 }
    #expect(reading.accountObservationCount == 1)
    #expect(reading.completedObservationCount == 1)
    #expect(reading.activeAccountObservationCount == 1)
    #expect(reading.activeCompletedObservationCount == 1)
    #expect(reading.breakdownObservationCount == 1)
    #expect(reading.activeBreakdownObservationCount == 1)
  }

  @Test func deinitCancelsRunningStorageObservations() async {
    let reading = FakeStorageReading()
    var model: SettingsModel? = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading)
    model?.startObservingStorage()

    model = nil

    await waitUntil {
      reading.activeAccountObservationCount == 0 && reading.activeCompletedObservationCount == 0
        && reading.activeBreakdownObservationCount == 0
    }
  }

  @Test func capacityRefreshStoresAValueAndUnavailableResult() async {
    let capacity = FakeDeviceStorageCapacityReading(values: [42_000, nil])
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      deviceStorageCapacityReading: capacity)

    await model.refreshAvailableCapacity()
    #expect(model.availableCapacityBytes == 42_000)

    await model.refreshAvailableCapacity()
    #expect(model.availableCapacityBytes == nil)
    #expect(capacity.callCount == 2)
  }

  @Test func failedCapacityRefreshClearsSuccessAndCanRetry() async {
    let capacity = FakeDeviceStorageCapacityReading(values: [42_000, nil, 21_000])
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      deviceStorageCapacityReading: capacity)

    await model.refreshAvailableCapacity()
    await model.refreshAvailableCapacity()
    #expect(model.availableCapacityBytes == nil)

    await model.refreshAvailableCapacity()
    #expect(model.availableCapacityBytes == 21_000)
    #expect(capacity.callCount == 3)
  }

  @Test func overlappingCapacityRefreshesPerformOneRead() async {
    let capacity = FakeDeviceStorageCapacityReading(values: [42_000], suspendsReads: true)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      deviceStorageCapacityReading: capacity)

    let first = Task { await model.refreshAvailableCapacity() }
    await waitUntil { capacity.callCount == 1 }
    let second = Task { await model.refreshAvailableCapacity() }
    await awaitQuiescence("overlapping capacity refreshes to settle", of: { "\(capacity.callCount)" })

    #expect(capacity.callCount == 1)
    capacity.resumeReads()
    await first.value
    await second.value

    #expect(model.availableCapacityBytes == 42_000)
    #expect(capacity.callCount == 1)
  }

  @Test func stoppingLastStorageObserverInvalidatesInFlightCapacityRead() async {
    let capacity = FakeDeviceStorageCapacityReading(values: [42_000, 84_000])
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      deviceStorageCapacityReading: capacity)
    model.startObservingStorage()
    await model.refreshAvailableCapacity()
    #expect(model.availableCapacityBytes == 42_000)

    capacity.holdReads()
    let refresh = Task { await model.refreshAvailableCapacity() }
    #expect(await waitUntil { capacity.isReadSuspended })

    model.stopObservingStorage()
    capacity.resumeReads()
    await refresh.value

    #expect(model.availableCapacityBytes == 42_000)
  }

  @Test func twoActiveStorageObserversKeepCapacityReadAlive() async {
    let capacity = FakeDeviceStorageCapacityReading(values: [42_000], suspendsReads: true)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      deviceStorageCapacityReading: capacity)
    model.startObservingStorage()
    model.startObservingStorage()

    let refresh = Task { await model.refreshAvailableCapacity() }
    #expect(await waitUntil { capacity.isReadSuspended })

    model.stopObservingStorage()
    capacity.resumeReads()
    await refresh.value

    #expect(model.availableCapacityBytes == 42_000)
    #expect(capacity.callCount == 1)
  }

  @Test func higherCapAndUnlimitedSelectionsPersistImmediately() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(8).bytes)
    let reading = FakeStorageReading(completedDownloadBytes: 7_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedCompletedDownloadBytes }

    await model.requestStorageCeiling(.gigabytes(16))?.value
    #expect(model.storageCeiling == .gigabytes(16))
    #expect(model.pendingStorageCeilingConfirmation == nil)

    await model.requestStorageCeiling(.unlimited)?.value
    #expect(model.storageCeiling == .unlimited)
    #expect(preferences.storageCeilingSetCallCount == 2)
  }

  @Test func selectingTheCurrentStorageCeilingIsANoOp() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(8).bytes)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    let write = model.requestStorageCeiling(.gigabytes(8))

    #expect(write == nil)
    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(preferences.storageCeilingSetCallCount == 0)
  }

  @Test func lowerCapRequiresConfirmationBelowLoadedCompletedBytes() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let reading = FakeStorageReading(completedDownloadBytes: 9_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedCompletedDownloadBytes }

    let write = model.requestStorageCeiling(.gigabytes(8))

    #expect(write == nil)
    #expect(model.pendingStorageCeilingConfirmation == .gigabytes(8))
    #expect(model.storageCeiling == .gigabytes(16))
    #expect(preferences.storageCeilingSetCallCount == 0)
  }

  @Test func lowerCapAtOrAboveLoadedCompletedBytesDoesNotConfirm() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let reading = FakeStorageReading(completedDownloadBytes: 8_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedCompletedDownloadBytes }

    await model.requestStorageCeiling(.gigabytes(8))?.value

    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(model.storageCeiling == .gigabytes(8))
    #expect(preferences.storageCeilingSetCallCount == 1)
  }

  @Test func inFlightBytesDoNotCauseAFalseDestructiveConfirmation() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let reading = FakeStorageReading(
      accountTotals: StorageTotals(totalBytes: 12_000_000_000),
      completedDownloadBytes: 7_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil {
      model.hasLoadedDownloadedBytes && model.hasLoadedCompletedDownloadBytes
    }

    await model.requestStorageCeiling(.gigabytes(8))?.value

    #expect(model.downloadedBytes == 12_000_000_000)
    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(model.storageCeiling == .gigabytes(8))
  }

  @Test func missingCompletedBytesConfirmsADecreaseEvenAfterAccountTotalLoads() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let reading = FakeStorageReading(
      accountTotals: StorageTotals(totalBytes: 2_000_000_000), completedDownloadBytes: nil)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedDownloadedBytes }

    model.requestStorageCeiling(.gigabytes(8))

    #expect(model.hasLoadedCompletedDownloadBytes == false)
    #expect(model.pendingStorageCeilingConfirmation == .gigabytes(8))
    #expect(preferences.storageCeilingSetCallCount == 0)
  }

  @Test func cancellingStorageCeilingChangeWritesNothing() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())
    model.requestStorageCeiling(.gigabytes(8))

    model.cancelStorageCeilingChange()
    let confirmation = model.confirmStorageCeiling()

    #expect(confirmation == nil)
    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(model.storageCeiling == .gigabytes(16))
    #expect(preferences.storageCeilingSetCallCount == 0)
  }

  @Test func confirmingStorageCeilingConsumesTargetSynchronouslyAndWritesOnce() async {
    let preferences = FakeDownloadPreferences(
      storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())
    model.requestStorageCeiling(.gigabytes(8))

    let confirmation = model.confirmStorageCeiling()

    #expect(model.pendingStorageCeilingConfirmation == nil)
    await confirmation?.value
    #expect(model.storageCeiling == .gigabytes(8))
    #expect(preferences.storageCeilingSetCallCount == 1)

    let secondConfirmation = model.confirmStorageCeiling()
    #expect(secondConfirmation == nil)
    #expect(preferences.storageCeilingSetCallCount == 1)
  }

  @Test func storageCeilingReflectsExternalPreferenceChanges() async {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    await preferences.setStorageCeilingBytes(StorageCeiling.gigabytes(32).bytes)
    await waitUntil { model.storageCeiling == .gigabytes(32) }

    #expect(model.storageCeiling == .gigabytes(32))
    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(preferences.storageCeilingSetCallCount == 1)
  }

  @Test func storagePresentationCalculationsCoverFiniteUnlimitedAndUnavailableStates() async {
    let reading = FakeStorageReading(
      accountTotals: StorageTotals(totalBytes: 18_000_000_000), completedDownloadBytes: 1)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(
        storageCeilingBytes: StorageCeiling.gigabytes(16).bytes),
      account: FakeAccountLifecycle(), storageReading: reading)

    #expect(model.storageUsageDescription == SettingsCopy.calculatingStorage)
    #expect(model.storageBar == nil)
    #expect(model.downloadedBytesDescription == SettingsCopy.unavailableValue)
    #expect(model.availableCapacityDescription == SettingsCopy.unavailableValue)
    #expect(model.compactAvailableCapacityDescription == nil)

    model.startObservingStorage()
    await waitUntil { model.hasLoadedDownloadedBytes }

    #expect(
      model.storageUsageDescription
        == SettingsCopy.storageUsage(
          usedBytes: 18_000_000_000, ceiling: .gigabytes(16)))

    await model.requestStorageCeiling(.unlimited)?.value
    #expect(
      model.storageUsageDescription
        == SettingsCopy.storageUsage(usedBytes: 18_000_000_000, ceiling: .unlimited))
  }

  // MARK: - Granular ceiling

  @Test func aStoredCeilingOffTheLadderReadsBackAsItself() {
    let stored: Int64 = 11_000_000_000
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(storageCeilingBytes: stored),
      account: FakeAccountLifecycle())

    #expect(model.storageCeiling.bytes == stored)
    #expect(model.storageCeiling.isUnlimited == false)
    #expect(SettingsCopy.storageCeilingLabel(model.storageCeiling) == "11 GB")
    #expect(model.storageCeilingStops.contains(model.storageCeiling))
  }

  @Test func aStoredZeroCeilingIsNotShownAsUnlimited() {
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(storageCeilingBytes: 0),
      account: FakeAccountLifecycle())

    #expect(model.storageCeiling.bytes == 0)
    #expect(model.storageCeiling != .unlimited)
  }

  @Test func raisingACeilingStillBelowCompletedBytesNeitherConfirmsNorWarns() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: StorageCeiling.gigabytes(4).bytes)
    let reading = FakeStorageReading(completedDownloadBytes: 9_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedCompletedDownloadBytes }

    #expect(model.storageCeilingReduction(for: .gigabytes(6)) == .none)
    await model.requestStorageCeiling(.gigabytes(6))?.value

    #expect(model.pendingStorageCeilingConfirmation == nil)
    #expect(model.storageCeiling == .gigabytes(6))
  }

  @Test func unlimitedToFiniteBeforeCompletedBytesLoadConfirmsWithAnUnknownReduction() {
    let preferences = FakeDownloadPreferences()
    let model = SettingsModel(downloadPreferences: preferences, account: FakeAccountLifecycle())

    #expect(model.storageCeilingReduction(for: .gigabytes(10)) == .unknown)
    model.requestStorageCeiling(.gigabytes(10))

    #expect(model.pendingStorageCeilingConfirmation == .gigabytes(10))
    #expect(preferences.storageCeilingSetCallCount == 0)
  }

  @Test func reductionPreviewAgreesWithTheConfirmationPredicate() async {
    let preferences = FakeDownloadPreferences(storageCeilingBytes: StorageCeiling.gigabytes(16).bytes)
    let reading = FakeStorageReading(completedDownloadBytes: 9_000_000_000)
    let model = SettingsModel(
      downloadPreferences: preferences, account: FakeAccountLifecycle(), storageReading: reading)
    model.startObservingStorage()
    await waitUntil { model.hasLoadedCompletedDownloadBytes }

    // Below completed bytes: confirms, and says how much goes.
    #expect(model.storageCeilingReduction(for: .gigabytes(7)) == .bytes(2_000_000_000))
    // A decrease that still holds everything, the current value, a raise and unlimited: nothing.
    #expect(model.storageCeilingReduction(for: .gigabytes(10)) == .none)
    #expect(model.storageCeilingReduction(for: .gigabytes(16)) == .none)
    #expect(model.storageCeilingReduction(for: .gigabytes(32)) == .none)
    #expect(model.storageCeilingReduction(for: .unlimited) == .none)

    #expect(
      SettingsCopy.storageCeilingReductionPreview(.bytes(2_000_000_000))
        == "Removes about 2 GB of completed downloads.")
    #expect(SettingsCopy.storageCeilingReductionPreview(.none) == nil)
    #expect(SettingsCopy.storageCeilingReductionPreview(.unknown) == "May remove completed downloads.")
  }

  @Test func stopsReachTheDeviceAndAlwaysEndUnlimited() async {
    let reading = FakeStorageReading(accountTotals: StorageTotals(totalBytes: 6_000_000_000))
    let capacity = FakeDeviceStorageCapacityReading(values: [20_000_000_000])
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: reading, deviceStorageCapacityReading: capacity)

    // Capacity unknown: the fallback ladder.
    #expect(model.storageCeilingStops.last == .unlimited)
    #expect(model.storageCeilingStops.dropLast().last == .gigabytes(256))

    model.startObservingStorage()
    await waitUntil { model.hasLoadedDownloadedBytes }
    await model.refreshAvailableCapacity()

    // 6 GB downloaded + 20 GB free = 26 GB of reach; the first stop at or above it is 32 GB.
    #expect(model.storageCeilingStops.dropLast().last == .gigabytes(32))
    #expect(model.storageCeilingStops.first == .gigabytes(1))
  }

  // MARK: - Storage bar

  @Test func storageBarFollowsTheBreakdownAndTheCeiling() async {
    let breakdown = StorageBreakdown(
      audiobookBytes: 4_000_000_000, podcastBytes: 2_000_000_000, documentBytes: 0)
    let reading = FakeStorageReading(breakdown: breakdown)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(
        storageCeilingBytes: StorageCeiling.gigabytes(12).bytes),
      account: FakeAccountLifecycle(), storageReading: reading)
    #expect(model.storageBar == nil)

    model.startObservingStorage()
    await waitUntil { model.storageBreakdown == breakdown }

    // Under the limit: shares of the limit, with the rest of the track left empty. A kind with
    // no bytes has no segment.
    let under = model.storageBar
    #expect(under?.segments.map(\.category) == [.audiobooks, .podcasts])
    #expect(under?.segments.map(\.fraction) == [4.0 / 12.0, 2.0 / 12.0])
    #expect(under?.segments.map(\.bytes) == [4_000_000_000, 2_000_000_000])

    // No limit: composition only, filling the track.
    await model.requestStorageCeiling(.unlimited)?.value
    #expect(model.storageBar?.segments.map(\.fraction) == [4.0 / 6.0, 2.0 / 6.0])

    reading.pushStorageBreakdown(StorageBreakdown())
    await waitUntil { model.storageBreakdown == StorageBreakdown() }
    #expect(model.storageBar == nil)
  }

  @Test func anOverLimitBarIsFullRatherThanClamped() {
    let breakdown = StorageBreakdown(
      audiobookBytes: 12_000_000_000, podcastBytes: 4_000_000_000, documentBytes: 2_000_000_000)

    let bar = StorageBarPresentation(breakdown: breakdown, ceilingBytes: 16_000_000_000)

    #expect(bar?.segments.map(\.category) == [.audiobooks, .podcasts, .documents])
    #expect(bar?.segments.map(\.fraction) == [12.0 / 18.0, 4.0 / 18.0, 2.0 / 18.0])
    #expect(bar?.segments.reduce(0) { $0 + $1.fraction } == 1)
  }

  @Test func theSummaryBarMeasuresAgainstTheDeviceWhenThereIsNoLimit() async {
    let breakdown = StorageBreakdown(
      audiobookBytes: 4_000_000_000, podcastBytes: 2_000_000_000, documentBytes: 0)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: FakeAccountLifecycle(),
      storageReading: FakeStorageReading(breakdown: breakdown),
      deviceStorageCapacityReading: FakeDeviceStorageCapacityReading(values: [18_000_000_000]))

    model.startObservingStorage()
    await waitUntil { model.storageBreakdown == breakdown }

    // Capacity not read yet: nothing to measure against, so composition only.
    #expect(model.storageSummaryBar == model.storageBar)

    // No limit: shares of what the device could hold for Whirr, downloaded plus free.
    await model.refreshAvailableCapacity()
    #expect(model.storageSummaryBar?.segments.map(\.fraction) == [4.0 / 24.0, 2.0 / 24.0])
    // The Storage Limit screen's bar has a legend, and stays composition.
    #expect(model.storageBar?.segments.map(\.fraction) == [4.0 / 6.0, 2.0 / 6.0])

    // A limit wins over the device.
    await model.requestStorageCeiling(.gigabytes(12))?.value
    #expect(model.storageSummaryBar?.segments.map(\.fraction) == [4.0 / 12.0, 2.0 / 12.0])
  }

  @Test func storageCopyInventoryUsesOneFormatterAndHonestPolicyLanguage() {
    let used: Int64 = 6_200_000_000
    let available: Int64 = 42_000_000_000
    let limit = StorageCeiling.gigabytes(16)

    #expect(SettingsCopy.storageUsage(usedBytes: used, ceiling: limit) == "6.2 GB of 16 GB")
    #expect(SettingsCopy.storageUsage(usedBytes: used, ceiling: .unlimited) == "6.2 GB downloaded")
    #expect(SettingsCopy.compactAvailableCapacity(available) == "42 GB available")
    #expect(SettingsCopy.downloadedBytes(used) == "6.2 GB")
    #expect(SettingsCopy.availableCapacity(available) == "42 GB")
    #expect(SettingsCopy.availableCapacity(nil) == "—")
    #expect(SettingsCopy.useStorageLimitAction(limit) == "Use 16 GB")
    #expect(SettingsCopy.storageCeilingLabel(.gigabytes(1000)) == "1 TB")
    #expect(
      StorageCategory.allCases.map(SettingsCopy.storageCategoryTitle) == [
        "Audiobooks", "Podcasts", "Ebooks and PDFs",
      ])

    let policy = SettingsCopy.storageCeilingExplanation
    #expect(policy == "Only completed downloads are removed.")
    #expect(SettingsCopy.reduceStorageLimitMessage.localizedCaseInsensitiveContains("may remove"))
    #expect(SettingsCopy.reduceStorageLimitMessage.localizedCaseInsensitiveContains("playing"))
    #expect(SettingsCopy.reduceStorageLimitMessage.localizedCaseInsensitiveContains("queued"))
    #expect(SettingsCopy.reduceStorageLimitMessage.localizedCaseInsensitiveContains("in-progress"))
    #expect(SettingsCopy.reduceStorageLimitMessage.localizedCaseInsensitiveContains("will free") == false)
  }

  // MARK: - Logout warning copy (destructive: enumerates downloads + unsynced offline listening)

  @Test func logoutWarningCopyEnumeratesDownloadsAndUnsyncedOfflineListening() {
    #expect(SettingsCopy.logoutMessage.localizedCaseInsensitiveContains("download"))
    #expect(SettingsCopy.logoutMessage.localizedCaseInsensitiveContains("offline"))
    #expect(SettingsCopy.logoutMessage.localizedCaseInsensitiveContains("sync"))
  }

  @Test func requestingLogoutStagesConfirmationWithoutLoggingOut() {
    let account = FakeAccountLifecycle()
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)

    model.requestLogout()

    #expect(model.logoutState == .confirming)
    #expect(account.logoutCallCount == 0)
  }

  /// Re-staging `.confirming` over `.confirming` is no visible transition and no re-entry point.
  /// Staging is only a move out of `.idle`.
  @Test func stagingLogoutOverANonIdleStateIsIgnored() async {
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: AccountRemovalError.deletionFailed)
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()
    await model.confirmLogout()
    #expect(model.logoutState == .failed)

    model.requestLogout()

    #expect(
      model.logoutState == .failed,
      "re-staging must not discard the retry `confirmLogout()` accepts from `.failed`")
  }

  @Test func cancellingLogoutLeavesEverythingIntact() async {
    let account = FakeAccountLifecycle()
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()

    model.cancelLogout()

    #expect(model.logoutState == .idle)
    await model.confirmLogout()
    #expect(account.logoutCallCount == 0, "a cancelled confirmation must never log out")
  }

  // MARK: - Logout routes through the removal workflow

  @Test func confirmingLogoutRoutesThroughAccountLifecycleLogoutExactlyOnce() async {
    let account = FakeAccountLifecycle()
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()

    let didLogOut = await model.confirmLogout()

    #expect(account.logoutCallCount == 1)
    #expect(model.logoutState == .idle)
    #expect(didLogOut)
  }

  @Test func confirmLogoutRunsThePreflightBeforeAccountLifecycleLogout() async {
    let order = LogoutOrderRecorder()
    let account = FakeAccountLifecycle()
    account.setLogoutHook { order.append("logout") }
    let preflight = RecordingLogoutPreflight(order: order)
    let model = SettingsModel(
      downloadPreferences: FakeDownloadPreferences(), account: account,
      logoutPreflight: preflight)
    model.requestLogout()

    let didLogOut = await model.confirmLogout()

    #expect(didLogOut)
    #expect(order.events == ["preflight", "logout"])
  }

  @Test func confirmLogoutIsANoOpWithoutAStagedOrFailedConfirmation() async {
    let account = FakeAccountLifecycle()
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)

    await model.confirmLogout()

    #expect(account.logoutCallCount == 0)
  }

  // MARK: - Blocking-retry state (AccountRemovalError.deletionFailed)

  @Test func aFailedAccountRemovalSurfacesTheBlockingRetryState() async {
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: AccountRemovalError.deletionFailed)
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()

    await model.confirmLogout()

    #expect(model.logoutState == .failed)
  }

  @Test func theFailedStateCanBeRetriedAndSucceeds() async {
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: AccountRemovalError.deletionFailed)
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()
    await model.confirmLogout()
    #expect(model.logoutState == .failed)

    account.stubLogout(throwing: nil)
    await model.confirmLogout()

    #expect(model.logoutState == .idle)
    #expect(account.logoutCallCount == 2, "retrying must call logout() again, not skip it")
  }

  @Test func aCredentialClearFailureKeepsLogoutInTheFailedRetryState() async {
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: AccountRemovalError.credentialClearFailed)
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()

    let didLogOut = await model.confirmLogout()

    #expect(didLogOut == false)
    #expect(model.logoutState == .failed)
  }

  @Test func anUntypedPreRemovalFailureStaysBlockingAndRetryable() async {
    struct PlainServerError: Error {}
    let account = FakeAccountLifecycle()
    account.stubLogout(throwing: PlainServerError())
    let model = SettingsModel(downloadPreferences: FakeDownloadPreferences(), account: account)
    model.requestLogout()

    let didLogOut = await model.confirmLogout()

    #expect(didLogOut == false)
    #expect(model.logoutState == .failed)
  }
}

private final class LogoutOrderRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [String] = []

  var events: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storedEvents
  }

  func append(_ event: String) {
    lock.lock()
    storedEvents.append(event)
    lock.unlock()
  }
}

@MainActor
private final class RecordingLogoutPreflight: LogoutPreflighting {
  private let order: LogoutOrderRecorder

  init(order: LogoutOrderRecorder) {
    self.order = order
  }

  func prepareForLogout() async {
    order.append("preflight")
  }
}
