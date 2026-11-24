import ABSApi
import Foundation
import Persistence

/// The small, post-authentication `/api/libraries` operation used before the runtime graph exists.
/// It reuses `LibraryReconciliationStore`: setup must never gain a second library
/// upsert path merely because catalogue sync is not running yet.
public protocol LibrarySelectionDiscovering: Sendable {
  func discoverAccessibleLibraries() async throws -> [SelectableLibrary]
}

public enum LibrarySelectionDiscoveryError: Error, Equatable, Sendable {
  case notAuthenticated
  case malformedAccount
}

public struct NoOpLibrarySelectionDiscovery: LibrarySelectionDiscovering, Sendable {
  public init() {}

  public func discoverAccessibleLibraries() async throws -> [SelectableLibrary] {
    throw LibrarySelectionDiscoveryError.notAuthenticated
  }
}

/// A setup-safe discovery service. Constructing it starts no worker and performs no request until
/// `discoverAccessibleLibraries()` is called after credentials have committed.
public struct LibrarySelectionDiscoveryService: LibrarySelectionDiscovering, Sendable {
  public typealias ClientFactory = @Sendable (AccountRecord) throws -> ABSClient

  private let accountDAO: AccountDAO
  private let selectionReading: any LibrarySelectionReading
  private let database: AppDatabase
  private let makeClient: ClientFactory

  public init(
    database: AppDatabase,
    selectionReading: any LibrarySelectionReading,
    clientFactory: @escaping ClientFactory
  ) {
    self.database = database
    accountDAO = AccountDAO(database: database)
    self.selectionReading = selectionReading
    makeClient = clientFactory
  }

  public func discoverAccessibleLibraries() async throws -> [SelectableLibrary] {
    guard let account = try await accountDAO.fetchAsync(), let accountID = account.id else {
      throw LibrarySelectionDiscoveryError.notAuthenticated
    }
    let tokenAccount: TokenAccount
    do {
      tokenAccount = try account.credentialTokenAccount
    } catch {
      throw LibrarySelectionDiscoveryError.malformedAccount
    }

    let libraries = try await makeClient(account).listLibraries(account: tokenAccount)
    _ = try await LibraryReconciliationStore(database: database, accountID: accountID).reconcile(
      libraries.map {
        LibraryReconciliationDescriptor(
          serverLibraryID: $0.id, name: $0.name, mediaType: $0.mediaType ?? "book",
          onlyShowLaterBooksInContinueSeries: $0.onlyShowLaterBooksInContinueSeries)
      })
    return try await selectionReading.currentSelection().libraries.filter(\.isAccessible)
  }
}
