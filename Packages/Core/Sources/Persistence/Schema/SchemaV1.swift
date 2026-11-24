import Foundation
import GRDB

/// The schema migrations.
///
/// `v1` to `v4` (`healItemHomeColumns`, `createPlaybackBookmark` heal, `healSchemaDrift`) are the
/// released schema and must not be edited in place. GRDB never revisits an applied migration, so
/// an edit reaches only new stores and diverges every store already on a device.
///
/// `v1` was once widened in place many times and only two changes got a heal, so real device
/// stores missed the rest (Core tests cannot catch that: each builds a fresh store). `v4`
/// converges any such store to the current shape, and `DriftedSchemaHealTests` asserts a healed
/// store's `sqlite_master` equals a fresh one's.
///
/// Rules:
///
/// 1. New work appends `v5`+. Never widen or reorder an existing migration.
/// 2. A change that must reach stores already in the field needs its own guarded heal in the new
///    migration (`v2`/`v3`/`v4` are the pattern).
/// 3. `ReleasedSchemaMigrationTests` enforces both. It migrates the committed baseline fixture and
///    compares a normalised `sqlite_master` dump against a committed expected file, so editing a
///    released migration fails until a new migration and regenerated expectation land.
///    Regenerate with
///    `REGENERATE_RELEASED_SCHEMA_FIXTURE=1 swift test --filter RegenerateReleasedSchemaFixture`,
///    and only after appending a migration. Regenerating to silence a failure is the bug.
///
/// Every account-owned table carries an `accountId` column with `references("account",
/// onDelete: .cascade)` although v1 has one account row, keeping a schema-driven removal sweep
/// possible and preventing accidental cross-account joins.
///
/// The registrations live in `SchemaV1+Era1.swift` … `SchemaV1+Era5.swift`; `migrator()` below is
/// the one ordered list. A new migration appends to Era 5. The DDL helpers live in the
/// `SchemaV1+DDL*.swift` files beside this one, grouped by table family and module-internal rather
/// than private so the era files can call them; they are not API.
enum SchemaV1 {
  /// `listeningQueueEntry`'s copy-then-drop step is a mid-migration checkpoint pair a test can
  /// fail at, mirroring `ListeningQueueMutationCheckpoint` (`ListeningQueueStore.swift`).
  /// The default no-op leaves every other caller of `migrator()` unaffected.
  enum ListeningQueueMigrationCheckpoint: Sendable, Equatable {
    case afterCopy
    case afterDrop
  }

  enum ListeningQueueMigrationError: Error, Equatable {
    /// The copy step must carry every existing `podcastQueueEntry` row across. A mismatched count
    /// means some row failed to resolve to its parent item and would silently vanish instead of
    /// migrating. Fatal, like `SchemaHealError`.
    case copyCountMismatch(expected: Int, actual: Int)
  }

  enum RSSListeningQueueMigrationCheckpoint: Sendable, Equatable {
    case afterCopy
    case afterDrop
    case afterSwap
  }

  enum RSSListeningQueueMigrationError: Error, Equatable {
    case copyCountMismatch(expected: Int, actual: Int)
  }

  enum SavedShelfMigrationError: Error, Equatable {
    case copyCountMismatch(expected: Int, actual: Int)
  }

  static func validateSavedShelfCopyCount(expected: Int, actual: Int) throws {
    guard actual == expected else {
      throw SavedShelfMigrationError.copyCountMismatch(expected: expected, actual: actual)
    }
  }

  static func migrator(
    listeningQueueMigrationCheckpoint:
      @escaping @Sendable (ListeningQueueMigrationCheckpoint)
      throws -> Void = { _ in },
    rssListeningQueueMigrationCheckpoint:
      @escaping @Sendable (RSSListeningQueueMigrationCheckpoint)
      throws -> Void = { _ in },
    nativeListeningQueueMigrationCheckpoint:
      @escaping @Sendable (NativeListeningQueueMigrationCheckpoint) throws -> Void = { _ in },
    rssSavedShelfMigrationCheckpoint:
      @escaping @Sendable (RSSSavedShelfMigrationCheckpoint) throws -> Void = { _ in }
  ) -> DatabaseMigrator {
    var migrator = DatabaseMigrator()

    registerEra1(on: &migrator, listeningQueueMigrationCheckpoint: listeningQueueMigrationCheckpoint)
    registerEra2(on: &migrator)
    registerEra3(
      on: &migrator,
      rssListeningQueueMigrationCheckpoint: rssListeningQueueMigrationCheckpoint,
      nativeListeningQueueMigrationCheckpoint: nativeListeningQueueMigrationCheckpoint,
      rssSavedShelfMigrationCheckpoint: rssSavedShelfMigrationCheckpoint)
    registerEra4(on: &migrator)
    registerEra5(on: &migrator)
    return migrator
  }
}
