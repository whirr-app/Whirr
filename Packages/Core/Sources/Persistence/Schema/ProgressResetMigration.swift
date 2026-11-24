import GRDB

/// v71: the columns cross-device reset sync needs (ADR 0011).
///
/// - `mediaProgress.serverProgressId` is the server row id this device last observed. Its loss on
///   a later complete snapshot is the reset evidence. Written only from pulls and cleared when
///   this device's own reset is acknowledged. Existing rows start `NULL`, so the first pull after
///   upgrade records it and supplies no evidence.
/// - `mediaProgress.serverProgressUpdatedAt` is that row's server `lastUpdate`. Kept apart from
///   `serverUpdatedAt` (stamped from this device's clock on an acknowledged local write) because
///   the recreated-row evidence compares it with a server `startedAt` and needs a server value.
/// - `progressConflict.serverEbookProgress` and `serverEbookLocation` (the CFI) give an ebook
///   conflict a server slot, so take-server can apply the ebook value as well as the audio one.
/// - `outboxOperation.payloadResetMedium`, `payloadResetPhase` and `payloadRestoreProgress` carry a
///   `progressReset` operation's medium, persisted send phase, and the server's audio fraction
///   captured before the delete. The other-medium position reuses `payloadCurrentTime`,
///   `payloadEbookProgress` and `payloadEbookLocation`.
enum ProgressResetMigration {
  static func migrate(_ db: Database) throws {
    try db.alter(table: "mediaProgress") { t in
      t.add(column: "serverProgressId", .text)
      t.add(column: "serverProgressUpdatedAt", .datetime)
    }
    try db.alter(table: "progressConflict") { t in
      t.add(column: "serverEbookProgress", .double)
      t.add(column: "serverEbookLocation", .text)
    }
    try db.alter(table: "outboxOperation") { t in
      t.add(column: "payloadResetMedium", .text)
      t.add(column: "payloadResetPhase", .text)
      t.add(column: "payloadRestoreProgress", .double)
    }
  }
}
