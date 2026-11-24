import Foundation
import Observation
import SyncEngine

/// The resolution center's screen model: every open progress conflict, skew confirmation, dead
/// letter, and paused-auth download from `ResolutionCenterAccess.fetchOpenItems()`, plus the
/// per-kind actions. `refresh()` re-fetches after every action so `items`/`openCount` stay current.
///
/// Nothing runs at construction (the enumeration spans several tables, so there is no single
/// `ValueObservation`): the caller triggers the first `refresh()`, like
/// `StorageModel.refreshLowDiskStatus()`.
@MainActor
@Observable
public final class ResolutionCenterModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded
    case error
  }

  public private(set) var state: State = .loading
  public private(set) var items: [ResolutionOpenItem] = []
  public private(set) var openCount: Int = 0
  public private(set) var actionErrorMessage: String?

  /// A skew keep-local action staged behind `ResolutionCenterCopy`'s overwrite warning. Set by
  /// `requestKeepLocalSkew`, cleared by `cancelPendingConfirmation`/`confirmKeepLocalSkew`.
  public private(set) var pendingSkewOverwriteConfirmation: (operationId: Int64, sessionId: Int64, itemTitle: String)?

  private let access: any ResolutionCenterAccess

  public init(access: any ResolutionCenterAccess) {
    self.access = access
  }

  /// True only after a successful fetch found nothing open. Before that, an empty `items` array
  /// means the screen is still loading or failed to load.
  public var isEmpty: Bool { state == .empty }

  public func refresh() async {
    let previousState = state
    state = .loading
    actionErrorMessage = nil

    do {
      let fetchedItems = try await access.fetchOpenItems()
      guard Task.isCancelled == false else {
        state = previousState
        return
      }
      items = fetchedItems
      openCount = fetchedItems.count
      state = fetchedItems.isEmpty ? .empty : .loaded
    } catch {
      guard Task.isCancelled == false else {
        state = previousState
        return
      }
      state = .error
    }
  }

  /// Clears a surfaced resolution-action failure once its alert has been dismissed. The row and
  /// its actions remain available, so dismissing the alert leaves the failed action retryable.
  public func dismissActionError() {
    actionErrorMessage = nil
  }

  // MARK: - Progress conflicts

  public func keepLocalProgress(conflictId: Int64) async {
    await perform {
      try await access.keepLocalProgress(conflictId: conflictId)
    }
  }

  public func takeServerProgress(conflictId: Int64) async {
    await perform {
      try await access.takeServerProgress(conflictId: conflictId)
    }
  }

  /// True once at least two progress conflicts are open and no bulk run is in flight. A single
  /// conflict has its own per-row take-server action.
  public var canTakeServerForAllProgressConflicts: Bool {
    isTakingServerForAllProgressConflicts == false && progressConflictCount >= 2
  }

  public private(set) var isTakingServerForAllProgressConflicts = false

  private var progressConflictCount: Int {
    items.filter {
      if case .progressConflict = $0.kind { return true }
      return false
    }.count
  }

  /// Applies take-server to every open progress conflict, one at a time. The view should confirm
  /// with the user first (it discards local progress on every listed item) and gate the call on
  /// `canTakeServerForAllProgressConflicts`; this guards against a double-fire regardless. A
  /// partial failure surfaces its count through `actionErrorMessage` without losing whatever did
  /// resolve, and `refresh()` runs afterwards like every other action.
  public func takeServerForAllProgressConflicts() async {
    guard canTakeServerForAllProgressConflicts else { return }
    isTakingServerForAllProgressConflicts = true
    defer { isTakingServerForAllProgressConflicts = false }
    do {
      let result = try await access.takeServerForAllProgressConflicts()
      // `refresh()` clears `actionErrorMessage`, so set the partial-failure message after it.
      await refresh()
      if result.failedCount > 0 {
        actionErrorMessage = ResolutionCenterCopy.takeServerForAllProgressConflictsPartialFailureMessage(
          failedCount: result.failedCount)
      }
    } catch {
      actionErrorMessage = ResolutionCenterCopy.actionFailed
    }
  }

  // MARK: - Skew confirmations

  /// Stages the keep-local action behind the overwrite warning. Does not act until
  /// `confirmKeepLocalSkew()`.
  public func requestKeepLocalSkew(operationId: Int64, sessionId: Int64, itemTitle: String) {
    pendingSkewOverwriteConfirmation = (operationId, sessionId, itemTitle)
  }

  /// Discards a staged overwrite confirmation without forwarding the keep-local action.
  public func cancelPendingConfirmation() {
    pendingSkewOverwriteConfirmation = nil
  }

  /// Forwards the staged keep-local confirmation once, timestamped at confirmation. A no-op if
  /// nothing is staged (e.g. already cancelled).
  public func confirmKeepLocalSkew() async {
    guard let pending = pendingSkewOverwriteConfirmation else { return }
    pendingSkewOverwriteConfirmation = nil
    await perform {
      try await access.keepLocalSkew(
        operationId: pending.operationId, sessionId: pending.sessionId, now: Date())
    }
  }

  /// The take-server/discard-upload alternative to keep-local. Needs no confirmation, since it
  /// discards this device's held value rather than overwriting the server's.
  public func takeServerSkew(operationId: Int64, sessionId: Int64) async {
    await perform {
      try await access.takeServerSkew(operationId: operationId, sessionId: sessionId)
    }
  }

  // MARK: - Dead letters

  public func discardDeadLetter(operationId: Int64) async {
    await perform {
      try await access.discardDeadLetter(operationId: operationId)
    }
  }

  public func refreshMetadataDeadLetter(operationId: Int64) async {
    await perform {
      try await access.refreshMetadataDeadLetter(operationId: operationId)
    }
  }

  // MARK: - Paused-auth downloads

  public func requestReAuthentication() async {
    await access.requestReAuthentication()
  }

  private func perform(_ action: () async throws -> Void) async {
    actionErrorMessage = nil
    do {
      try await action()
      guard Task.isCancelled == false else { return }
      await refresh()
    } catch {
      guard Task.isCancelled == false else { return }
      actionErrorMessage = ResolutionCenterCopy.actionFailed
    }
  }
}
