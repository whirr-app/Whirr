import ABSApi
import Foundation
import WatchProtocol

/// Pure reconciliation of device-local sessions with a shared progress snapshot. Every title gets
/// one position from `WatchOfflineConflictPolicy`; I/O, upload reservations and titles stay with
/// the caller, and each decision keeps its original session UUID and listening total.
public struct WatchOfflineReconciliationPlan: Sendable, Equatable {
  public struct Decision: Sendable, Equatable {
    public let sessionID: UUID
    public let position: Double
    public let reason: WatchOfflineConflictPolicy.Reason
    /// The Watch's position won against shared progress saved after this row was. The server
    /// keeps the newer of the two saves, so the row must be saved again to be accepted.
    public let needsFreshTimestamp: Bool

    init(
      sessionID: UUID, position: Double, reason: WatchOfflineConflictPolicy.Reason, needsFreshTimestamp: Bool = false
    ) {
      self.sessionID = sessionID
      self.position = position
      self.reason = reason
      self.needsFreshTimestamp = needsFreshTimestamp
    }
  }

  public let decisions: [Decision]

  init(decisions: [Decision]) { self.decisions = decisions }

  public init(
    local: [WatchOfflineProgressSession], remote: [MediaProgress], open: Set<UUID> = [], now: Date = Date()
  ) {
    // An open row is still being written by playback; it is judged once it closes.
    let local = local.filter { !open.contains($0.id) }
    let groups = Dictionary(grouping: local, by: \.selection)
    var decisions: [Decision] = []
    // Preserve first-seen title order to make the resulting value deterministic.
    var seen: Set<WatchSelection> = []
    for session in local where seen.insert(session.selection).inserted {
      let selection = session.selection
      guard let rows = groups[selection],
        case .audiobookshelf(let itemID, let episodeID) = selection
      else { continue }
      // The Watch's claim is the row listened to last; a save without listening (a paused tick,
      // an earlier reconciliation rewrite) must not make an older position look newer.
      guard
        let watch = rows.enumerated().max(by: {
          ($0.element.effectiveLastListenedAt, $0.offset) < ($1.element.effectiveLastListenedAt, $1.offset)
        })?.element
      else { continue }
      let shared = remote.first { $0.libraryItemID == itemID && $0.episodeID == episodeID }
      guard
        let resolution = WatchOfflineConflictPolicy.resolve(
          watchPosition: watch.currentPosition, watchListenedAt: watch.effectiveLastListenedAt,
          sharedPosition: shared?.currentTime, sharedUpdatedAt: shared?.lastUpdate,
          duration: watch.duration, now: now)
      else { continue }
      let chosen =
        resolution.winner == .shared ? (shared?.currentTime ?? watch.currentPosition) : watch.currentPosition
      // Rows of one title can carry different durations; a position past a row's end cannot be
      // recorded on it and would fail the whole upload batch.
      let sharedSavedAt = resolution.winner == .watch ? shared?.lastUpdate : nil
      decisions += rows.map { row in
        Decision(
          sessionID: row.id, position: row.duration.map { min(chosen, $0) } ?? chosen, reason: resolution.reason,
          needsFreshTimestamp: sharedSavedAt.map { $0 >= row.updatedAt } ?? false)
      }
    }
    self.decisions = decisions
  }
}
