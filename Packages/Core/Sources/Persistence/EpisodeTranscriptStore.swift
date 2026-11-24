import Foundation
import GRDB

/// Persistence for `episodeTranscript` and its files on the transcript root. It does not compare
/// fingerprints or revisions: deciding whether a row is current belongs to the coordinator.
///
/// A transcript is user content: never log it, its file names or its words.
public struct EpisodeTranscriptStore: Sendable {
  let database: AppDatabase
  let files: AdSkipTranscriptFileStore

  /// `files` must be on the transcript root, never ad skip's: each root's sweep deletes every
  /// file its own table does not name.
  public init(database: AppDatabase, files: AdSkipTranscriptFileStore) {
    self.database = database
    self.files = files
  }

  public func record(for identity: AdSkipEpisodeIdentity) async throws -> EpisodeTranscriptRecord? {
    try await database.readAsync { db in try Self.fetch(identity, in: db) }
  }

  /// Every row, oldest first, for reconciling against the local downloads.
  public func allRecords() async throws -> [EpisodeTranscriptRecord] {
    try await database.readAsync { db in
      try EpisodeTranscriptRecord.order(Column("id")).fetchAll(db)
    }
  }

  /// The row and its words. A row whose file cannot be read (after a restore the database comes
  /// back but excluded-from-backup files do not) is deleted, with its file, and reads as nil: the
  /// episode is untranscribed, not failed.
  public func transcript(for identity: AdSkipEpisodeIdentity) async throws
    -> EpisodeTranscriptEntry?
  {
    guard let record = try await record(for: identity),
      let fileName = record.transcriptFileName
    else { return nil }
    do {
      return EpisodeTranscriptEntry(record: record, transcript: try files.read(fileName: fileName))
    } catch is AdSkipTranscriptFileStoreError {
      try await database.writeAsync { db in
        // Only if the row still names that file: a save may have swapped it meanwhile.
        _ =
          try EpisodeTranscriptRecord
          .filter(Column("id") == record.id && Column("transcriptFileName") == fileName)
          .deleteAll(db)
      }
      files.delete(fileNames: [fileName])
      return nil
    }
  }

  /// Writes `transcript` to a new file, points the row at it (in place, so the id is stable) and
  /// then deletes the file it named before. If the database write fails the new file is deleted.
  @discardableResult
  public func saveProgress(
    _ transcript: StoredTranscript, for identity: AdSkipEpisodeIdentity,
    fingerprint: EpisodeTranscriptFingerprint, transcriberRevision: String, isComplete: Bool,
    at date: Date
  ) async throws -> EpisodeTranscriptRecord {
    let fileName = try files.write(transcript)
    let record = EpisodeTranscriptRecord(
      identity: identity, fingerprint: fingerprint, transcriberRevision: transcriberRevision,
      state: isComplete ? .complete : .partial, transcriptFileName: fileName, updatedAt: date)
    do {
      return try await upsert(record)
    } catch {
      files.delete(fileNames: [fileName])
      throw error
    }
  }

  /// Keeps a row saying transcription failed for this file, and deletes any transcript it had.
  @discardableResult
  public func markFailed(
    _ identity: AdSkipEpisodeIdentity, fingerprint: EpisodeTranscriptFingerprint,
    transcriberRevision: String, at date: Date
  ) async throws -> EpisodeTranscriptRecord {
    try await upsert(
      EpisodeTranscriptRecord(
        identity: identity, fingerprint: fingerprint, transcriberRevision: transcriberRevision,
        state: .failed, transcriptFileName: nil, updatedAt: date))
  }

  /// Deletes the rows, then their files.
  public func deleteEpisodes(_ identities: [AdSkipEpisodeIdentity]) async throws {
    let fileNames = try await database.writeAsync { db in
      var fileNames: [String] = []
      for identity in identities {
        if let record = try Self.fetch(identity, in: db) {
          fileNames.append(contentsOf: record.transcriptFileName.map { [$0] } ?? [])
          _ = try record.delete(db)
        }
      }
      return fileNames
    }
    files.delete(fileNames: fileNames)
  }

  /// Removes files on the transcript root that no row names and that were modified before
  /// `cutoff`, which must be far enough back to cover a write still waiting on its save.
  /// Returns the number removed.
  public func sweepFiles(modifiedBefore cutoff: Date) async throws -> Int {
    let referenced = try await database.readAsync { db in
      try Set(
        String.fetchAll(
          db,
          sql: "SELECT transcriptFileName FROM episodeTranscript WHERE transcriptFileName IS NOT NULL"
        ))
    }
    return try files.sweep(keeping: referenced, modifiedBefore: cutoff)
  }

  /// Saves `record` in place of any row for its identity, then deletes the file that row named
  /// if it was a different one.
  private func upsert(_ record: EpisodeTranscriptRecord) async throws -> EpisodeTranscriptRecord {
    let (stored, replacedFile) = try await database.writeAsync { db in
      var stored = record
      let previous = try Self.fetch(record.identity, in: db)
      if let previous {
        stored.id = previous.id
        try stored.update(db)
      } else {
        stored.id = nil
        try stored.insert(db)
      }
      let replaced = previous?.transcriptFileName.flatMap {
        $0 == stored.transcriptFileName ? nil : $0
      }
      return (stored, replaced)
    }
    if let replacedFile { files.delete(fileNames: [replacedFile]) }
    return stored
  }

  private static func fetch(
    _ identity: AdSkipEpisodeIdentity, in db: Database
  ) throws -> EpisodeTranscriptRecord? {
    // `IFNULL` matches the unique index, which is what lets RSS rows (no account) collide.
    try EpisodeTranscriptRecord.fetchOne(
      db,
      sql: """
        SELECT * FROM episodeTranscript
        WHERE source = ? AND IFNULL(accountId, 0) = ? AND itemID = ? AND episodeID = ?
        """,
      arguments: [identity.source, identity.accountId ?? 0, identity.itemID, identity.episodeID])
  }
}
