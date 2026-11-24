import Foundation
import GRDB

/// The wire-to-persistence adapter is owned by SyncEngine. This descriptor keeps
/// this transaction independent of ABSApi while carrying only the server-library fields that
/// reconciliation is permitted to update.
public struct LibraryReconciliationDescriptor: Sendable, Equatable {
  public let serverLibraryID: String
  public let name: String
  public let mediaType: String
  public let onlyShowLaterBooksInContinueSeries: Bool

  public init(
    serverLibraryID: String,
    name: String,
    mediaType: String,
    onlyShowLaterBooksInContinueSeries: Bool = false
  ) {
    self.serverLibraryID = serverLibraryID
    self.name = name
    self.mediaType = mediaType
    self.onlyShowLaterBooksInContinueSeries = onlyShowLaterBooksInContinueSeries
  }
}

/// The discovery result for the next stage of a refresh. It carries IDs rather than GRDB rows,
/// and is already constrained to accessible included server libraries.
public struct LibraryReconciliationResult: Sendable, Equatable {
  public let liveIncludedServerLibraryIDs: [String]

  public init(liveIncludedServerLibraryIDs: [String]) {
    self.liveIncludedServerLibraryIDs = liveIncludedServerLibraryIDs
  }
}

public enum LibraryReconciliationStoreError: Error, Equatable, Sendable {
  case accountNotFound
}

/// Applies the selection-sensitive portion of a server library-list refresh in one database
/// transaction: names/types update, returned tombstones revive, existing choices survive, and a
/// newly discovered row follows the account's compatibility/intent mode. Missing-library
/// two-pass deletion inference remains owned by SyncEngine's existing sync-run machinery.
public struct LibraryReconciliationStore: Sendable {
  private let database: AppDatabase
  private let accountID: Int64

  public init(database: AppDatabase, accountID: Int64) {
    self.database = database
    self.accountID = accountID
  }

  public func reconcile(_ descriptors: [LibraryReconciliationDescriptor]) async throws
    -> LibraryReconciliationResult
  {
    try await database.writeAsync { db in
      guard let account = try AccountRecord.fetchOne(db, key: accountID) else {
        throw LibraryReconciliationStoreError.accountNotFound
      }
      let existing =
        try LibraryRecord
        .filter(Column("accountId") == accountID)
        .fetchAll(db)
      let existingByServerID = Dictionary(uniqueKeysWithValues: existing.map { ($0.serverLibraryId, $0) })

      var includedIDs: [String] = []
      includedIDs.reserveCapacity(descriptors.count)
      for descriptor in descriptors {
        if var record = existingByServerID[descriptor.serverLibraryID] {
          record.name = descriptor.name
          record.mediaType = descriptor.mediaType
          record.onlyShowLaterBooksInContinueSeries =
            descriptor.onlyShowLaterBooksInContinueSeries
          record.softDeleted = false
          try record.update(db)
          if record.isIncluded { includedIDs.append(record.serverLibraryId) }
        } else {
          let isIncluded = account.librarySelectionMode == .all
          var record = LibraryRecord(
            accountId: accountID, serverLibraryId: descriptor.serverLibraryID,
            mediaType: descriptor.mediaType, name: descriptor.name, isIncluded: isIncluded,
            onlyShowLaterBooksInContinueSeries: descriptor.onlyShowLaterBooksInContinueSeries)
          try record.insert(db)
          if isIncluded { includedIDs.append(record.serverLibraryId) }
        }
      }
      return LibraryReconciliationResult(liveIncludedServerLibraryIDs: includedIDs)
    }
  }
}
