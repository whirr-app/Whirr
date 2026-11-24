import Foundation
import WatchProtocol

/// The progress-row operations `WatchLocalProgressLifecycle` drives. The ABS store and the native
/// journal keep different records, but the lifecycle's rule is the same on both: a row is open only
/// while audio plays, and a write that throws leaves the row exactly as it was so the caller can
/// carry the listening into its next write without counting it twice.
public protocol WatchProgressJournaling: Actor {
  /// Opens a row for `selection` and returns its id. `lastKnownSharedPosition` and
  /// `lastKnownSharedObservedAt` are the shared progress the row is anchored to; a native copy has
  /// none, and keeps none.
  func openRow(
    selection: WatchSelection,
    startPosition: Double?,
    duration: Double?,
    lastKnownSharedPosition: Double?,
    lastKnownSharedObservedAt: Date?
  ) throws -> UUID

  /// Writes the position, the listening since the last write, a finish and a user seek in one
  /// step. Returns whether the row now says anything the phone or server needs to hear.
  @discardableResult
  func recordRow(
    id: UUID, currentPosition: Double, listenedDelta: Double, isFinished: Bool, userSeek: Bool
  ) throws -> Bool

  /// The audio ran past the row's declared duration. A shorter value is ignored.
  func growRowDuration(id: UUID, to duration: Double) throws

  func deleteRow(id: UUID) throws
}

/// Forwards to the ABS store's own methods. `startSession` returns the whole session, but the
/// lifecycle only ever needs its id, which is what the requirement returns.
extension WatchOfflineProgressStore: WatchProgressJournaling {
  public func openRow(
    selection: WatchSelection,
    startPosition: Double?,
    duration: Double?,
    lastKnownSharedPosition: Double?,
    lastKnownSharedObservedAt: Date?
  ) throws -> UUID {
    try startSession(
      selection: selection, startPosition: startPosition, duration: duration,
      lastKnownSharedPosition: lastKnownSharedPosition,
      lastKnownSharedObservedAt: lastKnownSharedObservedAt
    ).id
  }

  @discardableResult
  public func recordRow(
    id: UUID, currentPosition: Double, listenedDelta: Double, isFinished: Bool, userSeek: Bool
  ) throws -> Bool {
    try recordProgress(
      sessionID: id, currentPosition: currentPosition, listenedDelta: listenedDelta,
      isFinished: isFinished, userSeek: userSeek
    ).hasProgressToSend
  }

  public func growRowDuration(id: UUID, to duration: Double) throws {
    try growDuration(sessionID: id, to: duration)
  }

  public func deleteRow(id: UUID) throws {
    try delete(sessionID: id)
  }
}
