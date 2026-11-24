import Foundation
import Persistence

/// Whether a complete `/api/me` snapshot shows that the server row this device last observed for
/// one identity was deleted: the only way another device's reset reaches this one (ADR 0011).
///
/// Every comparison is between values the same server assigned, so no client clock is read. A
/// zero written to the observed row (glitch, third-party client, session sync) keeps its id and is
/// never evidence. Anything short of proof is no evidence; the zero guard then decides.
enum ProgressResetEvidence {
  /// - Parameters:
  ///   - storedProgressID: the row id this device's last applied pull recorded.
  ///   - storedServerUpdatedAt: that observation's server `lastUpdate`, i.e. the row's
  ///     `serverProgressUpdatedAt`, never `serverUpdatedAt`, which a local acknowledgement can
  ///     stamp from this device's clock.
  ///   - observedRowIDs: the id of every row this snapshot holds for the identity, duplicates
  ///     included; `nil` for a row whose id did not decode.
  ///     Empty means the identity is absent.
  ///   - winnerStartedAt: `startedAt` of the row the pull resolves against.
  static func isEvidenced(
    storedProgressID: String?,
    storedServerUpdatedAt: Date?,
    observedRowIDs: [String?],
    winnerStartedAt: Date?,
    snapshotIsComplete: Bool
  ) -> Bool {
    // A partial snapshot cannot tell a deleted row from one that failed to decode.
    guard snapshotIsComplete, let storedProgressID else { return false }
    if observedRowIDs.isEmpty { return true }
    // Recreated: the observed row is gone from every duplicate, and the winning row was created
    // after the observation. Either condition alone misfires (duplicate rows; a backdated
    // `lastUpdate`), so both must hold.
    guard observedRowIDs.allSatisfy({ $0 != nil }),
      observedRowIDs.contains(storedProgressID) == false,
      let startedAt = winnerStartedAt, let storedServerUpdatedAt
    else { return false }
    return startedAt > storedServerUpdatedAt
  }

  /// The episode paths decide inside a Persistence transaction, from what it read there.
  static func isEvidenced(_ context: PodcastProgressMergeContext) -> Bool {
    guard let current = context.currentProgress, let serverRow = context.incomingServerRow else {
      return false
    }
    return isEvidenced(
      storedProgressID: current.serverProgressId,
      storedServerUpdatedAt: current.serverProgressUpdatedAt,
      observedRowIDs: serverRow.rowIDs,
      winnerStartedAt: serverRow.startedAt,
      snapshotIsComplete: serverRow.snapshotIsComplete)
  }
}
