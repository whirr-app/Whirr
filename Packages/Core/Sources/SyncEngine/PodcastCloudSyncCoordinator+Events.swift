import Foundation
import GRDB
import Persistence

/// Event application. Each event commits durably before `handle` returns, because the engine
/// serialises its state after delivering events, and remote apply, system fields and
/// fetch progress must be committed before a serialisation checkpoint is accepted.
extension PodcastCloudSyncCoordinator {
  public func handle(_ event: PodcastCloudSyncEvent) async {
    // An event with no session is a stale callback. The adapter already drops events from a
    // retired engine; this covers a coordinator that was disabled while one was in flight.
    guard phase != .idle, namespace != nil else { return }
    do {
      switch event {
      case .stateSerialization(let blob):
        guard let namespace else { return }
        try await transport.saveEngineState(namespace: namespace, engineState: blob)
      case .zoneSave(let succeeded):
        guard let namespace else { return }
        if succeeded {
          try await transport.markZoneEstablished(namespace: namespace)
        } else {
          await interrupt("the zone save failed")
        }
      case .zoneDeletion(let succeeded):
        zoneDeletionSucceeded = succeeded
      case .sendPassEnded:
        inFlight = [:]
      case .sentRecords(let sent):
        try await handleSent(sent)
      case .fetchedChanges(let changes):
        try await handleFetched(changes)
      case .fetchCompleted(let succeeded):
        guard succeeded else {
          zoneFetchFailed = true
          return
        }
        lastSuccessfulFetch = now()
        if phase == .bootstrapping { bootstrapFetchSucceeded = true }
        if phase == .running {
          await clearInterruption()
          await settleAttention()
        }
      case .accountChanged(let change):
        try await handleAccountChange(change)
      case .zoneLost(let loss):
        try await handleZoneLoss(loss)
      case .quotaExceeded:
        quotaPaused = true
        await setStatus(.quotaExceeded)
      }
    } catch {
      await interrupt("a \(event.logLabel) event did not commit: \(Self.describe(error))")
    }
  }
}

extension PodcastCloudSyncEvent {
  /// The event's kind, for the log. Carries none of the event's content.
  var logLabel: String {
    switch self {
    case .stateSerialization: "state serialization"
    case .zoneSave: "zone save"
    case .zoneDeletion: "zone deletion"
    case .sendPassEnded: "send pass"
    case .sentRecords: "sent records"
    case .fetchedChanges: "fetched changes"
    case .fetchCompleted: "fetch completed"
    case .accountChanged: "account change"
    case .zoneLost: "zone loss"
    case .quotaExceeded: "quota"
    }
  }
}
