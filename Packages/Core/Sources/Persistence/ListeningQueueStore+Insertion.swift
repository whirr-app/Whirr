import Foundation
import GRDB

/// Adding to Up Next. A book is queued whole or as chapters, never both, and a
/// replacement keeps the book's download decline.
extension ListeningQueueStore {
  /// A book is queued whole or as chapters, never both. A whole book replaces its
  /// chapter rows; a chapter replaces a whole-book row; another chapter is a row of its own.
  @discardableResult
  public func append(
    identity: ListeningIdentity, chapter: ListeningQueueChapter?
  ) async throws -> ListeningQueueAppendOutcome {
    try chapter?.validate(for: identity)
    return try await database.writeAsync { db in
      let resolved = try Self.resolveForInsertion(db, accountId: accountId, identity: identity)
      let declinedAt = try Self.downloadDeclinedAt(db, accountId: accountId, identity: identity)
      var rows = try NativeListeningQueueWriter.records(in: db)
      let titleRows = rows.indices.filter { Self.matches(rows[$0], resolved: resolved) }
      let outcome: ListeningQueueAppendOutcome
      if titleRows.contains(where: { Self.hasExtent(rows[$0], chapter) }) {
        // Appending what is already queued is an idempotent no-op; it does not move the row.
        return .alreadyQueued
      } else if titleRows.isEmpty || (chapter != nil && titleRows.allSatisfy { rows[$0].chapter != nil }) {
        rows.append(
          Self.makeEntry(
            accountId: accountId, resolved: resolved, position: rows.count, chapter: chapter))
        outcome = .appended
      } else {
        // The other extent of the book gives way where its first row sat.
        rows[titleRows[0]].chapter = chapter
        try Self.deleteRows(at: Array(titleRows.dropFirst()), from: &rows, in: db)
        outcome = .replaced
      }
      try NativeListeningQueueWriter.persist(rows, in: db, checkpoint: mutationCheckpoint)
      try Self.inheritDecline(db, accountId: accountId, identity: identity, declinedAt: declinedAt)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
      return outcome
    }
  }

  /// A queued chapter moves to the front; a new chapter goes to the front beside the book's other
  /// chapter rows. A whole book replaces its chapter rows, and a chapter a whole-book row, at the
  /// front.
  public func insertNext(identity: ListeningIdentity, chapter: ListeningQueueChapter?) async throws {
    try chapter?.validate(for: identity)
    try await database.writeAsync { db in
      let resolved = try Self.resolveForInsertion(db, accountId: accountId, identity: identity)
      let declinedAt = try Self.downloadDeclinedAt(db, accountId: accountId, identity: identity)
      var rows = try NativeListeningQueueWriter.records(in: db)
      let titleRows = rows.indices.filter { Self.matches(rows[$0], resolved: resolved) }
      let inserted: ListeningQueueEntryRecord
      if let same = titleRows.first(where: { Self.hasExtent(rows[$0], chapter) }) {
        inserted = rows.remove(at: same)
      } else if titleRows.isEmpty || (chapter != nil && titleRows.allSatisfy { rows[$0].chapter != nil }) {
        inserted = Self.makeEntry(
          accountId: accountId, resolved: resolved, position: rows.count, chapter: chapter)
      } else {
        try Self.deleteRows(at: Array(titleRows.dropFirst()), from: &rows, in: db)
        var replaced = rows.remove(at: titleRows[0])
        replaced.chapter = chapter
        inserted = replaced
      }
      rows.insert(inserted, at: 0)
      try NativeListeningQueueWriter.persist(rows, in: db, checkpoint: mutationCheckpoint)
      try Self.inheritDecline(db, accountId: accountId, identity: identity, declinedAt: declinedAt)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  @discardableResult
  public func insertNext(identities: [ListeningIdentity]) async throws -> [ListeningIdentity] {
    try await database.writeAsync { db in
      var rows = try NativeListeningQueueWriter.records(in: db)
      var front: [ListeningQueueEntryRecord] = []
      var skipped: [ListeningIdentity] = []
      for identity in identities {
        let resolved: (itemId: Int64?, episodeId: Int64?, rssEpisodeId: Int64?)
        do {
          resolved = try Self.resolveForInsertion(db, accountId: accountId, identity: identity)
        } catch is ListeningQueueStoreError {
          skipped.append(identity)
          continue
        }
        if front.contains(where: { Self.matches($0, resolved: resolved) }) { continue }
        let titleRows = rows.indices.filter { Self.matches(rows[$0], resolved: resolved) }
        if let first = titleRows.first {
          // A batch queues whole titles, so a book's chapter rows become its whole book.
          try Self.deleteRows(at: Array(titleRows.dropFirst()), from: &rows, in: db)
          var moved = rows.remove(at: first)
          moved.chapter = nil
          front.append(moved)
        } else {
          front.append(
            Self.makeEntry(
              accountId: accountId, resolved: resolved, position: rows.count + front.count))
        }
      }
      guard front.isEmpty == false else { return skipped }
      try NativeListeningQueueWriter.persist(front + rows, in: db, checkpoint: mutationCheckpoint)
      _ = try NativeListeningQueueWriter.bumpRevision(in: db)
      return skipped
    }
  }

  // MARK: - Shared by insertion

  /// The row already queues this extent: both whole, or the same chapter.
  static func hasExtent(
    _ row: ListeningQueueEntryRecord, _ chapter: ListeningQueueChapter?
  ) -> Bool {
    switch (row.chapter, chapter) {
    case (nil, nil): true
    case (let queued?, let requested?): queued.isSameChapter(as: requested)
    default: false
    }
  }

  /// `persist` only saves the rows it is given, so a replaced row is deleted explicitly.
  static func deleteRows(
    at indices: [Int], from rows: inout [ListeningQueueEntryRecord], in db: Database
  ) throws {
    for index in indices.sorted(by: >) {
      try NativeListeningQueueWriter.delete(rows.remove(at: index), in: db)
    }
  }

  /// A decline is per title but stored on each row, so every row of a declined book carries it,
  /// including one just inserted. `declinedAt` is read before the write.
  static func inheritDecline(
    _ db: Database, accountId: Int64?, identity: ListeningIdentity, declinedAt: Date?
  ) throws {
    guard let declinedAt else { return }
    try setDownloadDeclined(db, accountId: accountId, target: DeclineTarget(identity), at: declinedAt)
  }
}
