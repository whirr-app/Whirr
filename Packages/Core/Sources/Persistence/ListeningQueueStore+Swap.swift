import Foundation
import GRDB

/// A swap: an Up Next row starts and the title it displaced goes back to the front of Up Next.
extension ListeningQueueStore {
  /// `acknowledgeStarted(identity:rowID:)` and the return of `displaced` in one write, so the
  /// started row cannot go without the displaced title coming back, or the reverse.
  ///
  /// The displaced title returns whole. One already queued whole moves to the front instead of
  /// doubling; a book with queued chapter rows keeps them, since those are the listener's plan, and
  /// gains no whole-book row. A title the queue would refuse (`ListeningQueueStoreError`) is
  /// skipped while the start is still consumed. True when the displaced title is now first.
  @discardableResult
  public func acknowledgeStarted(
    identity: ListeningIdentity, rowID: Int64?, returning displaced: ListeningIdentity
  ) async throws -> Bool {
    try await database.writeAsync { db in
      let started = try Self.entries(db, accountId: accountId, identity: identity)
        .filter { $0.chapterStart == nil || $0.id == rowID }
      for row in started { try NativeListeningQueueWriter.delete(row, in: db) }
      var rows = try NativeListeningQueueWriter.records(in: db)
      let returned = try Self.returnToFront(displaced, rows: &rows, accountId: accountId, in: db)
      // A swap that changed nothing leaves the revision, and so a pending clear's Undo, alone.
      guard started.isEmpty == false || returned else { return false }
      try NativeListeningQueueWriter.persist(rows, in: db, checkpoint: mutationCheckpoint)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
      return returned
    }
  }

  private static func returnToFront(
    _ identity: ListeningIdentity, rows: inout [ListeningQueueEntryRecord], accountId: Int64?,
    in db: Database
  ) throws -> Bool {
    let resolved: (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?)
    do {
      resolved = try resolveForInsertion(db, accountId: accountId, identity: identity)
    } catch is ListeningQueueStoreError {
      return false
    }
    let titleRows = rows.indices.filter { matches(rows[$0], resolved: resolved) }
    if titleRows.isEmpty {
      rows.insert(makeEntry(accountId: accountId, resolved: resolved, position: rows.count), at: 0)
      return true
    }
    guard let whole = titleRows.first(where: { rows[$0].chapter == nil }) else { return false }
    rows.insert(rows.remove(at: whole), at: 0)
    return true
  }
}
