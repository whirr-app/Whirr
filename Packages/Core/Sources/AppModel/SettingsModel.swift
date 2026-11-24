import Foundation
import Observation
import Persistence
import SyncEngine

/// The process-wide work that must finish before an account lifecycle logout is invoked.
/// AppModel owns the ordering boundary; App target composition can add system surfaces such as
/// Now Playing and remote commands around `PlaybackModel`'s model-level preflight.
@MainActor
public protocol LogoutPreflighting {
  func prepareForLogout() async
}

/// The Settings screen's model: the device-side download toggles (`DownloadPreferences`) and the
/// destructive logout warning/confirmation flow, forwarded to `AccountLifecycle.logout()`.
@MainActor
@Observable
public final class SettingsModel {
  /// Where a staged/confirmed logout currently stands.
  public enum LogoutState: Sendable, Equatable {
    case idle
    /// Staged behind `SettingsCopy`'s destructive warning; `confirmLogout()` has not run yet.
    case confirming
    case inProgress
    /// A blocking, retryable failure that did not prove local removal completed. When present,
    /// the durable removal journal lets `confirmLogout()` re-attempt the idempotent sequence.
    case failed
  }

  public private(set) var allowCellularDownloads: Bool
  public private(set) var deleteDownloadsWhenFinished: Bool
  public private(set) var queueAutoDownloadPolicy: QueueAutoDownloadPolicy
  public private(set) var savedShelfAutoDownloadPolicy: SavedShelfAutoDownloadPolicy
  public private(set) var storageCeiling: StorageCeiling
  /// All live download bytes, including partial/in-flight rows. This is display-only; destructive
  /// selection decisions use `completedDownloadBytes` instead.
  public private(set) var downloadedBytes: Int64?
  public private(set) var hasLoadedDownloadedBytes = false
  /// Completed bytes governed by `StorageCeilingCoordinator`, kept separate from displayed bytes
  /// so an in-flight transfer cannot cause a false destructive warning.
  public private(set) var completedDownloadBytes: Int64?
  public private(set) var hasLoadedCompletedDownloadBytes = false
  /// The same bytes as `downloadedBytes`, split by kind for the storage bar.
  public private(set) var storageBreakdown: StorageBreakdown?
  public private(set) var availableCapacityBytes: Int64?
  public private(set) var pendingStorageCeilingConfirmation: StorageCeiling?
  public private(set) var logoutState: LogoutState = .idle

  private let downloadPreferences: any DownloadPreferences
  private let account: any AccountLifecycle
  private let logoutPreflight: (any LogoutPreflighting)?
  private let storageReading: any StorageReading
  private let deviceStorageCapacityReading: any DeviceStorageCapacityReading
  private var activeStorageScreenCount = 0
  private var capacityRefreshGeneration: UInt = 0
  private var capacityRefreshTaskGeneration: UInt?

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var deleteWhenFinishedTask: Task<Void, Never>?
  @ObservationIgnored private var queueAutoDownloadPolicyTask: Task<Void, Never>?
  @ObservationIgnored private var savedShelfAutoDownloadPolicyTask: Task<Void, Never>?
  @ObservationIgnored private var storageCeilingTask: Task<Void, Never>?
  @ObservationIgnored private var accountStorageTask: Task<Void, Never>?
  @ObservationIgnored private var completedStorageTask: Task<Void, Never>?
  @ObservationIgnored private var breakdownStorageTask: Task<Void, Never>?
  @ObservationIgnored private var capacityRefreshTask: Task<Int64?, Never>?

  public init(
    downloadPreferences: any DownloadPreferences,
    account: any AccountLifecycle,
    storageReading: any StorageReading = NoOpStorageReading(),
    deviceStorageCapacityReading: any DeviceStorageCapacityReading = NoOpDeviceStorageCapacityReading(),
    logoutPreflight: (any LogoutPreflighting)? = nil
  ) {
    self.downloadPreferences = downloadPreferences
    self.account = account
    self.logoutPreflight = logoutPreflight
    self.storageReading = storageReading
    self.deviceStorageCapacityReading = deviceStorageCapacityReading
    allowCellularDownloads = downloadPreferences.allowCellular
    deleteDownloadsWhenFinished = downloadPreferences.deleteWhenFinished
    queueAutoDownloadPolicy = downloadPreferences.queueAutoDownloadPolicy
    savedShelfAutoDownloadPolicy = downloadPreferences.savedShelfAutoDownloadPolicy
    storageCeiling = StorageCeiling(bytes: downloadPreferences.storageCeilingBytes)

    // Subscribed synchronously in `init`, not inside the `Task` below, so no change is missed.
    let stream = downloadPreferences.changes
    task = Task { [weak self] in
      for await allowed in stream {
        guard let self else { return }
        self.allowCellularDownloads = allowed
      }
    }
    let deleteWhenFinishedStream = downloadPreferences.deleteWhenFinishedChanges
    deleteWhenFinishedTask = Task { [weak self] in
      for await enabled in deleteWhenFinishedStream {
        guard let self else { return }
        self.deleteDownloadsWhenFinished = enabled
      }
    }
    let queueAutoDownloadPolicyStream = downloadPreferences.queueAutoDownloadPolicyChanges
    queueAutoDownloadPolicyTask = Task { [weak self] in
      for await policy in queueAutoDownloadPolicyStream {
        guard let self else { return }
        self.queueAutoDownloadPolicy = policy
      }
    }
    let savedShelfAutoDownloadPolicyStream = downloadPreferences.savedShelfAutoDownloadPolicyChanges
    savedShelfAutoDownloadPolicyTask = Task { [weak self] in
      for await policy in savedShelfAutoDownloadPolicyStream {
        guard let self else { return }
        self.savedShelfAutoDownloadPolicy = policy
      }
    }
    let storageCeilingStream = downloadPreferences.storageCeilingBytesChanges
    storageCeilingTask = Task { [weak self] in
      for await bytes in storageCeilingStream {
        guard let self else { return }
        self.storageCeiling = StorageCeiling(bytes: bytes)
      }
    }
  }

  deinit {
    task?.cancel()
    deleteWhenFinishedTask?.cancel()
    queueAutoDownloadPolicyTask?.cancel()
    savedShelfAutoDownloadPolicyTask?.cancel()
    storageCeilingTask?.cancel()
    accountStorageTask?.cancel()
    completedStorageTask?.cancel()
    breakdownStorageTask?.cancel()
    capacityRefreshTask?.cancel()
  }

  /// Persists the cellular-download opt-in through `DownloadPreferences`.
  /// Updates the observable state immediately so a SwiftUI `Toggle` does not snap back while the
  /// preference store is being awaited. The preference stream still reconciles changes made by
  /// other consumers.
  public func setAllowCellularDownloads(_ allowed: Bool) async {
    allowCellularDownloads = allowed
    await downloadPreferences.setAllowCellular(allowed)
  }

  public func setDeleteDownloadsWhenFinished(_ enabled: Bool) async {
    deleteDownloadsWhenFinished = enabled
    await downloadPreferences.setDeleteWhenFinished(enabled)
  }

  public func setQueueAutoDownloadPolicy(_ policy: QueueAutoDownloadPolicy) async {
    queueAutoDownloadPolicy = policy
    await downloadPreferences.setQueueAutoDownloadPolicy(policy)
  }

  public func setSavedShelfAutoDownloadPolicy(_ policy: SavedShelfAutoDownloadPolicy) async {
    savedShelfAutoDownloadPolicy = policy
    await downloadPreferences.setSavedShelfAutoDownloadPolicy(policy)
  }

  private func setStorageCeiling(_ ceiling: StorageCeiling) async {
    storageCeiling = ceiling
    await downloadPreferences.setStorageCeilingBytes(ceiling.bytes)
  }

  // MARK: - Storage context

  /// Registers one visible Downloads screen. Multiple screens share one set of observations, and
  /// the final matching stop cancels them; this survives child-appear/parent-disappear ordering.
  public func startObservingStorage() {
    activeStorageScreenCount += 1
    guard accountStorageTask == nil, completedStorageTask == nil, breakdownStorageTask == nil
    else { return }

    let accountStream = storageReading.observeAccountStorageTotals()
    accountStorageTask = Task { [weak self] in
      for await totals in accountStream {
        guard Task.isCancelled == false, let self else { return }
        self.downloadedBytes = totals.totalBytes
        self.hasLoadedDownloadedBytes = true
      }
    }

    let completedStream = storageReading.observeCompletedDownloadTotals()
    completedStorageTask = Task { [weak self] in
      for await bytes in completedStream {
        guard Task.isCancelled == false, let self else { return }
        self.completedDownloadBytes = bytes
        self.hasLoadedCompletedDownloadBytes = true
      }
    }

    let breakdownStream = storageReading.observeStorageBreakdown()
    breakdownStorageTask = Task { [weak self] in
      for await breakdown in breakdownStream {
        guard Task.isCancelled == false, let self else { return }
        self.storageBreakdown = breakdown
      }
    }
  }

  /// Unregisters one visible Downloads screen. Last values and loaded flags are kept so returning
  /// to the screen does not flash back to a loading state.
  public func stopObservingStorage() {
    guard activeStorageScreenCount > 0 else { return }
    activeStorageScreenCount -= 1
    guard activeStorageScreenCount == 0 else { return }
    capacityRefreshGeneration &+= 1
    capacityRefreshTask?.cancel()
    capacityRefreshTask = nil
    capacityRefreshTaskGeneration = nil
    accountStorageTask?.cancel()
    accountStorageTask = nil
    completedStorageTask?.cancel()
    completedStorageTask = nil
    breakdownStorageTask?.cancel()
    breakdownStorageTask = nil
  }

  /// Refreshes the one-shot capacity figure. Overlapping callers await the same in-flight task,
  /// preventing the parent and pushed child screens from duplicating a foreground read.
  public func refreshAvailableCapacity() async {
    let refresh: Task<Int64?, Never>
    let generation: UInt
    if let capacityRefreshTask {
      refresh = capacityRefreshTask
      generation = capacityRefreshTaskGeneration ?? capacityRefreshGeneration
    } else {
      let reading = deviceStorageCapacityReading
      let newRefresh = Task { await reading.availableCapacityBytes() }
      capacityRefreshGeneration &+= 1
      capacityRefreshTask = newRefresh
      capacityRefreshTaskGeneration = capacityRefreshGeneration
      refresh = newRefresh
      generation = capacityRefreshGeneration
    }

    let result = await refresh.value
    guard generation == capacityRefreshGeneration else { return }
    availableCapacityBytes = result
    if capacityRefreshTaskGeneration == generation {
      capacityRefreshTask = nil
      capacityRefreshTaskGeneration = nil
    }
  }

  public var downloadedBytesDescription: String {
    guard hasLoadedDownloadedBytes else { return SettingsCopy.unavailableValue }
    return SettingsCopy.downloadedBytes(downloadedBytes)
  }

  public var availableCapacityDescription: String {
    SettingsCopy.availableCapacity(availableCapacityBytes)
  }

  public var compactAvailableCapacityDescription: String? {
    guard let availableCapacityBytes else { return nil }
    return SettingsCopy.compactAvailableCapacity(availableCapacityBytes)
  }

  public var storageUsageDescription: String {
    guard hasLoadedDownloadedBytes, let downloadedBytes else {
      return SettingsCopy.calculatingStorage
    }
    return SettingsCopy.storageUsage(usedBytes: downloadedBytes, ceiling: storageCeiling)
  }

  /// The storage bar, once the breakdown has loaded and there is something downloaded.
  public var storageBar: StorageBarPresentation? {
    guard let storageBreakdown else { return nil }
    return StorageBarPresentation(breakdown: storageBreakdown, ceilingBytes: storageCeiling.bytes)
  }

  /// The bar for the Downloads card, which has no legend to say a full track is only composition.
  /// With no limit it measures downloads against what the device could hold for Whirr, downloaded
  /// plus free, so a nearly empty device does not show a full meter. Until capacity is read it
  /// falls back to `storageBar`.
  public var storageSummaryBar: StorageBarPresentation? {
    guard let storageBreakdown else { return nil }
    return StorageBarPresentation(
      breakdown: storageBreakdown, ceilingBytes: storageCeiling.bytes,
      capacityBytes: availableCapacityBytes.map { $0 + storageBreakdown.totalBytes })
  }

  /// The limits the slider offers on this device. The top of the ladder is what the device could
  /// hold for Whirr: what is downloaded plus what is free. Capacity is a one-shot read, so the
  /// ladder does not move while a transfer runs.
  public var storageCeilingStops: [StorageCeiling] {
    let maximumBytes = availableCapacityBytes.map { $0 + (downloadedBytes ?? 0) }
    return StorageCeilingStops.stops(maximumBytes: maximumBytes, including: storageCeiling)
  }

  /// What the slider should warn of while it rests on `ceiling`. Uses the same predicate as
  /// `requestStorageCeiling`, so the warning appears when releasing there would raise the
  /// confirmation.
  public func storageCeilingReduction(for ceiling: StorageCeiling) -> StorageCeilingReduction {
    guard ceiling != storageCeiling, shouldConfirmStorageCeiling(ceiling) else { return .none }
    guard hasLoadedCompletedDownloadBytes, let completedDownloadBytes,
      let requestedBytes = ceiling.bytes
    else { return .unknown }
    return .bytes(max(0, completedDownloadBytes - requestedBytes))
  }

  /// Applies a safe selection immediately or stages a potentially destructive reduction.
  /// Returns the write task, as `StorageModel.confirmPurge()` does, so tests can await persistence.
  @discardableResult
  public func requestStorageCeiling(_ ceiling: StorageCeiling) -> Task<Void, Never>? {
    guard ceiling != storageCeiling else { return nil }
    guard shouldConfirmStorageCeiling(ceiling) else {
      return Task { await self.setStorageCeiling(ceiling) }
    }
    pendingStorageCeilingConfirmation = ceiling
    return nil
  }

  public func cancelStorageCeilingChange() {
    pendingStorageCeilingConfirmation = nil
  }

  /// Consumes the staged target synchronously before the returned preference write can suspend, so
  /// an alert's dismissal binding cannot cancel the choice its destructive button just confirmed.
  @discardableResult
  public func confirmStorageCeiling() -> Task<Void, Never>? {
    guard let ceiling = pendingStorageCeilingConfirmation else { return nil }
    pendingStorageCeilingConfirmation = nil
    return Task { await self.setStorageCeiling(ceiling) }
  }

  private func shouldConfirmStorageCeiling(_ ceiling: StorageCeiling) -> Bool {
    guard let requestedBytes = ceiling.bytes else { return false }

    if let currentBytes = storageCeiling.bytes, requestedBytes >= currentBytes {
      return false
    }
    guard hasLoadedCompletedDownloadBytes, let completedDownloadBytes else { return true }
    return requestedBytes < completedDownloadBytes
  }

  // MARK: - Logout

  /// Stages the destructive logout warning. Does not log out until `confirmLogout()`.
  ///
  /// Only `.idle` stages. Re-staging over `.inProgress` would let a second tap cancel a removal
  /// already running, and over `.failed` it would discard the retry `confirmLogout()` accepts.
  public func requestLogout() {
    guard logoutState == .idle else { return }
    logoutState = .confirming
  }

  /// Discards a staged confirmation without ever calling `logout()`.
  public func cancelLogout() {
    logoutState = .idle
  }

  /// Forwards to `AccountLifecycle.logout()`. A no-op unless a warning is staged or a previous
  /// attempt is blocked and retryable (`.failed`).
  /// Returns whether local account removal completed, including when only the server-side logout
  /// confirmation failed after local cleanup.
  @discardableResult
  public func confirmLogout() async -> Bool {
    guard logoutState == .confirming || logoutState == .failed else { return false }
    logoutState = .inProgress
    do {
      await logoutPreflight?.prepareForLogout()
      try await account.logout()
      logoutState = .idle
      return true
    } catch {
      logoutState = .failed
      return false
    }
  }
}
