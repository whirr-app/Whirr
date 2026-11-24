import Foundation
import Observation
import SyncEngine

/// What the iCloud Sync screen may ask of a running sync service. `nil` wherever the screen is
/// given no controller: it then shows local consent only and offers no action that would reach
/// CloudKit.
public protocol PodcastCloudSyncControlling: Sendable {
  func status() async -> PodcastCloudSyncStatus
  /// When a sync last reached iCloud successfully; `nil` if never.
  func lastSuccessfulSync() async -> Date?
  func syncNow() async throws
  /// The confirmed deletion. Never re-enables sync.
  func deleteCloudData() async throws
  /// The confirmed recovery from a lost zone: recreates it and resumes sync into it.
  func recoverFromZoneLoss() async throws
  /// The explicit clock repair that lets a quarantined installation stamp and send again.
  func repairClock() async throws
}

extension PodcastCloudSyncCoordinator: PodcastCloudSyncControlling {
  public func status() async -> PodcastCloudSyncStatus { currentStatus }
  public func lastSuccessfulSync() async -> Date? { lastSuccessfulFetch }
}

/// The status vocabulary for podcast data settings. Errors read as text, never colour alone, and
/// every state the listener cannot act on collapses to "needs attention".
public enum PodcastCloudSyncStatusPresentation {
  public static func text(for status: PodcastCloudSyncStatus) -> String {
    switch status {
    case .off: PodcastDataSettingsCopy.off
    case .bootstrapping: PodcastDataSettingsCopy.statusSyncing
    case .upToDate: PodcastDataSettingsCopy.statusUpToDate
    case .waiting: PodcastDataSettingsCopy.statusWaiting
    case .accountUnavailable: PodcastDataSettingsCopy.statusSignIn
    case .quotaExceeded: PodcastDataSettingsCopy.statusStorageFull
    case .zoneLost, .clockRepairRequired, .needsAttention, .interrupted:
      PodcastDataSettingsCopy.statusNeedsAttention
    }
  }

  /// What "needs attention" means for the listener: a retry that will clear it, or data this
  /// device is keeping back. `nil` for every status that already says it all.
  public static func note(for status: PodcastCloudSyncStatus) -> String? {
    switch status {
    case .interrupted: PodcastDataSettingsCopy.statusInterruptedNote
    case .zoneLost, .clockRepairRequired, .needsAttention: PodcastDataSettingsCopy.statusHeldNote
    case .off, .bootstrapping, .upToDate, .waiting, .accountUnavailable, .quotaExceeded: nil
    }
  }

  /// Up to Date is the quiet state: sync that is working shows nothing, as the system's own
  /// iCloud features do.
  public static func isWorthShowing(_ status: PodcastCloudSyncStatus) -> Bool {
    switch status {
    case .off, .upToDate: false
    case .bootstrapping, .waiting, .accountUnavailable, .quotaExceeded, .zoneLost,
      .clockRepairRequired, .needsAttention, .interrupted:
      true
    }
  }

  /// Whether an explicit sync can clear the status: an interrupted step is retried, a quota pause
  /// lifts once the listener has freed space, and a send the service refused is offered again. The
  /// engine already retries while offline, and the other states need something a retry cannot do.
  public static func offersRetry(for status: PodcastCloudSyncStatus) -> Bool {
    switch status {
    case .interrupted, .quotaExceeded, .needsAttention: true
    case .off, .bootstrapping, .upToDate, .waiting, .accountUnavailable, .zoneLost,
      .clockRepairRequired:
      false
    }
  }

  /// The explicit recovery a status waits on. Neither is ever started for the listener: a lost
  /// zone is recreated only after a confirmation, and a clock is repaired only on request.
  public enum Recovery: Equatable, Sendable {
    case recreateZone
    case repairClock
  }

  public static func recovery(for status: PodcastCloudSyncStatus) -> Recovery? {
    switch status {
    case .zoneLost: .recreateZone
    case .clockRepairRequired: .repairClock
    case .off, .bootstrapping, .upToDate, .waiting, .accountUnavailable, .quotaExceeded,
      .needsAttention, .interrupted:
      nil
    }
  }

  /// How long ago a sync last succeeded, which stays readable while the note refreshes in place.
  public static func lastSyncedNote(for date: Date) -> String {
    PodcastDataSettingsCopy.lastSynced(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
  }
}

/// Status, retry, recovery and deletion for Settings > Podcasts > iCloud Sync. Holds no cloud
/// state of its own: it asks the controller and shows the answer.
@MainActor @Observable
public final class PodcastCloudSyncControlsModel {
  public enum DeletionState: Equatable, Sendable {
    case idle
    case confirming
    case deleting
    /// Only reported after the service confirmed the zone is gone; offline never reads as done.
    case deleted
    case failed
  }

  public enum RecoveryState: Equatable, Sendable {
    case idle
    /// Recreating a lost zone resumes uploads, so it waits for the listener's confirmation.
    case confirming
    case recovering
    case failed
  }

  public private(set) var status: PodcastCloudSyncStatus?
  public private(set) var lastSuccessfulSync: Date?
  public private(set) var isSyncing = false
  public private(set) var syncFailed = false
  public private(set) var deletion: DeletionState = .idle
  public private(set) var recovery: RecoveryState = .idle

  @ObservationIgnored private let controller: (any PodcastCloudSyncControlling)?

  public init(controller: (any PodcastCloudSyncControlling)?) {
    self.controller = controller
  }

  /// Whether the screen has a running service to talk to. Without one it shows no status row and
  /// no actions, rather than a status it cannot know.
  public var isAvailable: Bool { controller != nil }

  public var statusText: String? { status.map(PodcastCloudSyncStatusPresentation.text(for:)) }

  public var statusNote: String? { status.flatMap(PodcastCloudSyncStatusPresentation.note(for:)) }

  /// `nil` until the controller has been asked, so nothing is shown that the service did not say.
  public var showsStatus: Bool { status.map(PodcastCloudSyncStatusPresentation.isWorthShowing) ?? false }

  /// Try Again stays on offer after a retry that failed, whatever the status then reads.
  public var offersRetry: Bool {
    guard isAvailable else { return false }
    return syncFailed || status.map(PodcastCloudSyncStatusPresentation.offersRetry(for:)) ?? false
  }

  /// `nil` until a sync has succeeded: a status with no history needs no "never".
  public var lastSyncedNote: String? {
    lastSuccessfulSync.map(PodcastCloudSyncStatusPresentation.lastSyncedNote(for:))
  }

  public var canSyncNow: Bool { controller != nil && isSyncing == false && deletion != .deleting }

  public func refresh() async {
    guard let controller else { return }
    await read(controller)
    // A sync the engine completed on its own supersedes a failed retry. Only a poll clears it:
    // a retry that threw must report its failure even if the status reads up to date.
    if status == .upToDate { syncFailed = false }
    if recovery == .failed, recoveryAction == nil { recovery = .idle }
  }

  public func syncNow() async {
    guard let controller, canSyncNow else { return }
    isSyncing = true
    syncFailed = false
    do {
      try await controller.syncNow()
    } catch {
      syncFailed = true
    }
    await read(controller)
    isSyncing = false
  }

  /// The recovery the current status waits on, if the screen has a service to ask for it.
  public var recoveryAction: PodcastCloudSyncStatusPresentation.Recovery? {
    guard isAvailable else { return nil }
    return status.flatMap(PodcastCloudSyncStatusPresentation.recovery(for:))
  }

  public var canRecover: Bool {
    recoveryAction != nil && recovery != .recovering && isSyncing == false && deletion != .deleting
  }

  /// Starts a clock repair at once; a lost zone asks for confirmation first, because recreating it
  /// resumes uploads to iCloud.
  @discardableResult
  public func requestRecovery() -> Task<Void, Never>? {
    guard let controller, canRecover, let action = recoveryAction else { return nil }
    switch action {
    case .recreateZone:
      recovery = .confirming
      return nil
    case .repairClock:
      return recover(action, using: controller)
    }
  }

  /// Cancel leaves sync suspended, uploads nothing, and keeps the recovery on offer.
  public func cancelRecovery() {
    if recovery == .confirming { recovery = .idle }
  }

  /// The state is `.recovering` before this returns, so a dialog dismissal reported after the
  /// button's action cannot turn the choice into Cancel.
  @discardableResult
  public func confirmRecovery() -> Task<Void, Never>? {
    guard let controller, recovery == .confirming else { return nil }
    return recover(.recreateZone, using: controller)
  }

  private func recover(
    _ action: PodcastCloudSyncStatusPresentation.Recovery, using controller: any PodcastCloudSyncControlling
  ) -> Task<Void, Never> {
    recovery = .recovering
    return Task {
      var failed = false
      do {
        switch action {
        case .recreateZone: try await controller.recoverFromZoneLoss()
        case .repairClock: try await controller.repairClock()
        }
      } catch {
        failed = true
      }
      await self.read(controller)
      // A recovery that returned but left the status where it was did not recover anything.
      self.recovery = failed || self.recoveryAction == action ? .failed : .idle
    }
  }

  private func read(_ controller: any PodcastCloudSyncControlling) async {
    status = await controller.status()
    lastSuccessfulSync = await controller.lastSuccessfulSync()
  }

  public func requestDeletion() {
    guard controller != nil, deletion != .deleting else { return }
    deletion = .confirming
  }

  public func cancelDeletion() {
    if deletion == .confirming { deletion = .idle }
  }

  /// Starts the confirmed deletion. The state is `.deleting` before this returns, so a dialog
  /// whose dismissal is reported after its button's action cannot turn the choice into Cancel.
  @discardableResult
  public func confirmDeletion() -> Task<Void, Never>? {
    guard let controller, deletion == .confirming else { return nil }
    deletion = .deleting
    return Task { await self.delete(using: controller) }
  }

  private func delete(using controller: any PodcastCloudSyncControlling) async {
    do {
      try await controller.deleteCloudData()
      let after = await controller.status()
      status = after
      lastSuccessfulSync = await controller.lastSuccessfulSync()
      // The coordinator turns sync off only once the zone deletion is confirmed; anything else
      // means the deletion did not complete.
      deletion = after == .off ? .deleted : .failed
    } catch {
      await read(controller)
      deletion = .failed
    }
  }

  public func dismissDeletionResult() {
    if deletion == .deleted || deletion == .failed { deletion = .idle }
  }
}
