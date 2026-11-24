import Foundation

/// The read boundary the collections and playlists screens consume. Both streams are local
/// projections of the stored snapshots; fetching from the server is `LibraryCollectionService`'s
/// job.
public protocol LibraryCollectionReading: Sendable {
  /// Every stored list in the account's included libraries, collections first, then by name.
  func observeListings() -> AsyncStream<[LibraryCollectionListing]>

  /// One list and its held entries in order, or nil when the list is not stored.
  func observeContents(key: LibraryCollectionKey) -> AsyncStream<LibraryCollectionContents?>
}

public struct DefaultLibraryCollectionReading: LibraryCollectionReading {
  private let store: LibraryCollectionStore
  private let accountID: Int64

  public init(database: AppDatabase, accountID: Int64) {
    self.store = LibraryCollectionStore(database: database)
    self.accountID = accountID
  }

  public func observeListings() -> AsyncStream<[LibraryCollectionListing]> {
    store.observeListings(accountID: accountID)
  }

  public func observeContents(key: LibraryCollectionKey) -> AsyncStream<LibraryCollectionContents?> {
    store.observeContents(accountID: accountID, key: key)
  }
}

/// For a session with no account: nothing stored, nothing to show.
public struct NoOpLibraryCollectionReading: LibraryCollectionReading {
  public init() {}

  public func observeListings() -> AsyncStream<[LibraryCollectionListing]> {
    AsyncStream {
      $0.yield([])
      $0.finish()
    }
  }

  public func observeContents(key: LibraryCollectionKey) -> AsyncStream<LibraryCollectionContents?> {
    AsyncStream {
      $0.yield(nil)
      $0.finish()
    }
  }
}
