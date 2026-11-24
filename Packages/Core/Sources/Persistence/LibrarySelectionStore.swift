import Foundation
import GRDB

/// A library descriptor safe to pass above Persistence. `isAccessible` describes the server's
/// last-known visibility; an inaccessible row is retained so its local inclusion choice can be
/// restored if the server lists it again.
public struct SelectableLibrary: Sendable, Equatable {
  public let serverLibraryID: String
  public let name: String
  public let mediaType: String
  public let isAccessible: Bool
  public let isIncluded: Bool

  public init(
    serverLibraryID: String, name: String, mediaType: String, isAccessible: Bool, isIncluded: Bool
  ) {
    self.serverLibraryID = serverLibraryID
    self.name = name
    self.mediaType = mediaType
    self.isAccessible = isAccessible
    self.isIncluded = isIncluded
  }
}

public struct LibrarySelectionSnapshot: Sendable, Equatable {
  public let mode: LibrarySelectionMode
  public let libraries: [SelectableLibrary]

  public init(mode: LibrarySelectionMode, libraries: [SelectableLibrary]) {
    self.mode = mode
    self.libraries = libraries
  }

  /// Whether any accessible, included library is a podcast library. Backs both the shell's
  /// Podcasts tab and the Settings Podcasts row, so the two cannot drift.
  public var hasIncludedPodcastLibrary: Bool {
    libraries.contains { $0.isAccessible && $0.isIncluded && $0.mediaType == "podcast" }
  }
}

public protocol LibrarySelectionReading: Sendable {
  func currentSelection() async throws -> LibrarySelectionSnapshot
  func observeSelection() -> AsyncStream<LibrarySelectionSnapshot>
}

public protocol LibrarySelectionWriting: Sendable {
  func completeOnboarding(includedIDs: Set<String>) async throws
  func setIncluded(_ included: Bool, libraryID: String) async throws
}

public enum LibrarySelectionStoreError: Error, Equatable, Sendable {
  case notAuthenticated
  case libraryNotFound(String)
  case emptySelection
  case lastLiveLibrary
}

/// Inert selection boundary for setup/removal composition and lightweight previews. It reports no
/// durable selection rather than inventing a selectable library before an account exists.
public struct NoOpLibrarySelectionStore: LibrarySelectionReading, LibrarySelectionWriting, Sendable {
  public init() {}

  public func currentSelection() async throws -> LibrarySelectionSnapshot {
    throw LibrarySelectionStoreError.notAuthenticated
  }

  public func observeSelection() -> AsyncStream<LibrarySelectionSnapshot> {
    AsyncStream { $0.finish() }
  }

  public func completeOnboarding(includedIDs: Set<String>) async throws {
    throw LibrarySelectionStoreError.notAuthenticated
  }

  public func setIncluded(_ included: Bool, libraryID: String) async throws {
    throw LibrarySelectionStoreError.notAuthenticated
  }
}

/// The account-scoped selection boundary. The app has one durable account today, so it resolves
/// that row inside every transaction rather than retaining a stale account ID across logout.
public struct LibrarySelectionStore: LibrarySelectionReading, LibrarySelectionWriting, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func currentSelection() async throws -> LibrarySelectionSnapshot {
    try await database.readAsync { db in
      guard let account = try AccountRecord.fetchOne(db) else {
        throw LibrarySelectionStoreError.notAuthenticated
      }
      return try Self.snapshot(account: account, db: db)
    }
  }

  public func observeSelection() -> AsyncStream<LibrarySelectionSnapshot> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          guard let account = try AccountRecord.fetchOne(db) else {
            throw LibrarySelectionStoreError.notAuthenticated
          }
          return try Self.snapshot(account: account, db: db)
        }
        .removeDuplicates())
  }

  public func completeOnboarding(includedIDs: Set<String>) async throws {
    guard includedIDs.isEmpty == false else { throw LibrarySelectionStoreError.emptySelection }
    try await database.writeAsync { db in
      var account = try Self.currentAccount(db)
      let accountID = try Self.accountID(account)
      let libraries = try Self.allLibraries(accountID: accountID, db: db)
      try Self.verify(ids: includedIDs, in: libraries)

      for var library in libraries {
        library.isIncluded = includedIDs.contains(library.serverLibraryId)
        try library.update(db)
      }
      try Self.requireLiveIncluded(in: libraries, includedIDs: includedIDs)
      account.librarySelectionMode = .selected
      try account.update(db)
    }
  }

  public func setIncluded(_ included: Bool, libraryID: String) async throws {
    try await database.writeAsync { db in
      var account = try Self.currentAccount(db)
      let accountID = try Self.accountID(account)
      let libraries = try Self.allLibraries(accountID: accountID, db: db)
      guard var library = libraries.first(where: { $0.serverLibraryId == libraryID }) else {
        throw LibrarySelectionStoreError.libraryNotFound(libraryID)
      }

      guard
        included || library.softDeleted
          || libraries.contains(where: {
            $0.serverLibraryId != libraryID && $0.softDeleted == false && $0.isIncluded
          })
      else {
        throw LibrarySelectionStoreError.lastLiveLibrary
      }

      library.isIncluded = included
      try library.update(db)
      if account.librarySelectionMode == .all {
        account.librarySelectionMode = .selected
        try account.update(db)
      }
    }
  }

  private static func currentAccount(_ db: Database) throws -> AccountRecord {
    guard let account = try AccountRecord.fetchOne(db) else {
      throw LibrarySelectionStoreError.notAuthenticated
    }
    return account
  }

  private static func accountID(_ account: AccountRecord) throws -> Int64 {
    guard let accountID = account.id else { throw LibrarySelectionStoreError.notAuthenticated }
    return accountID
  }

  private static func allLibraries(accountID: Int64, db: Database) throws -> [LibraryRecord] {
    try LibraryRecord
      .filter(Column("accountId") == accountID)
      .order(Column("serverLibraryId"))
      .fetchAll(db)
  }

  private static func verify(ids: Set<String>, in libraries: [LibraryRecord]) throws {
    let known = Set(libraries.map(\.serverLibraryId))
    if let unknown = ids.subtracting(known).sorted().first {
      throw LibrarySelectionStoreError.libraryNotFound(unknown)
    }
  }

  private static func requireLiveIncluded(in libraries: [LibraryRecord], includedIDs: Set<String>) throws {
    guard
      libraries.contains(where: {
        $0.softDeleted == false && includedIDs.contains($0.serverLibraryId)
      })
    else { throw LibrarySelectionStoreError.lastLiveLibrary }
  }

  private static func snapshot(account: AccountRecord, db: Database) throws -> LibrarySelectionSnapshot {
    let libraries = try allLibraries(accountID: try accountID(account), db: db).map {
      SelectableLibrary(
        serverLibraryID: $0.serverLibraryId, name: $0.name, mediaType: $0.mediaType,
        isAccessible: $0.softDeleted == false, isIncluded: $0.isIncluded)
    }
    return LibrarySelectionSnapshot(mode: account.librarySelectionMode, libraries: libraries)
  }
}
