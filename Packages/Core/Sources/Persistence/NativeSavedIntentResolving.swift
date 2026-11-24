import Foundation
import GRDB

/// The Saved-shelf consequence of one accepted native episode-state write, resolved inside the
/// caller's transaction.
///
/// Resolved in Swift, not a SQLite trigger: the removal is a user mutation that must reach the
/// outbox stamped with the mutation that caused it, and a trigger cannot reach the logical clock
/// or the saved register. The same transaction keeps the local write, the shelf removal and the
/// pending cloud operation atomic: a crash may repeat an idempotent send but never commit state
/// the outbox cannot see.
///
/// Conformers must not open a transaction; they are already inside one.
public protocol NativeSavedIntentResolving: Sendable {
  func resolveNativeSavedIntent(
    in db: Database,
    acceptedState: RSSEpisodeStateRecord,
    previousState: RSSEpisodeStateRecord?
  ) throws
}

/// The removal predicate, owned in one place so copies cannot drift.
///
/// Subtler than "progress happened": a finish can leave position alone, so position changes and
/// the finish transition both remove the entry, each conditioned on a change. A repeated identical
/// write must not remove it: a listener who re-saved a finished episode has said something newer.
public enum NativeSavedIntent {
  /// Whether `acceptedState` removes the episode from the Saved shelf.
  ///
  /// Equivalent to this trigger predicate:
  ///
  ///     AFTER INSERT  WHEN COALESCE(NEW.position, 0) > 0 OR NEW.finished = 1
  ///     AFTER UPDATE OF position, finished
  ///       WHEN (COALESCE(NEW.position, 0) > 0 AND NEW.position IS NOT OLD.position)
  ///         OR (NEW.finished = 1 AND OLD.finished = 0)
  ///
  /// Compares values, not statement shape: GRDB's `update` names every column, so a dismissal-only
  /// write is never a candidate.
  public static func removalQualifies(
    acceptedState: RSSEpisodeStateRecord, previousState: RSSEpisodeStateRecord?
  ) -> Bool {
    guard let previousState else {
      return acceptedState.position > 0 || acceptedState.finished
    }
    let advanced = acceptedState.position > 0 && acceptedState.position != previousState.position
    let finishedNow = acceptedState.finished && previousState.finished == false
    return advanced || finishedNow
  }
}

/// Saved-shelf resolution for a device with no cloud sync: remove the entry, record nothing.
///
/// The cloud-aware resolver lives above `Persistence`, because the saved register and its
/// mutation stamps are `SyncEngine` values.
public struct LocalNativeSavedIntentResolver: NativeSavedIntentResolving {
  public init() {}

  public func resolveNativeSavedIntent(
    in db: Database,
    acceptedState: RSSEpisodeStateRecord,
    previousState: RSSEpisodeStateRecord?
  ) throws {
    guard
      NativeSavedIntent.removalQualifies(
        acceptedState: acceptedState, previousState: previousState)
    else { return }
    try db.execute(
      sql: "DELETE FROM rssSavedShelfEntry WHERE rssEpisodeId = ?",
      arguments: [acceptedState.episodeId])
  }
}
