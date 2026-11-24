import ABSApi
import Foundation
import Persistence

/// Fetches the server's collections and playlists into `LibraryCollectionStore`.
/// A standalone actor with its own `AccountDAO` and `ABSClient`, laid out like
/// `AuthorSeriesService`.
///
/// A library's rows of one kind are replaced only after a complete, non-lossy walk of every page.
/// The listing has no stable cross-page order, so a repeated id, changed `total`, dropped element
/// or deduplicated count below `total` leaves the previous snapshot in place.
public actor LibraryCollectionService {
  public enum PassOutcome: Sendable, Equatable {
    case replaced(listCount: Int)
    /// The walk finished but could not prove it saw every list; nothing was written.
    case lossy
    /// The library is no longer an included, live library; nothing was written.
    case libraryUnavailable
  }

  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let libraryDAO: LibraryDAO
  private let store: LibraryCollectionStore
  private let pageSize: Int
  private var flights: [String: Task<PassOutcome, Error>] = [:]
  /// Test seam: called when a caller joins a pass already running for its key.
  private let flightJoined: (@Sendable () -> Void)?

  public init(
    database: AppDatabase, client: ABSClient, pageSize: Int = CollectionPlaylistBounds.fallback
  ) {
    self.init(database: database, client: client, pageSize: pageSize, flightJoined: nil)
  }

  init(
    database: AppDatabase, client: ABSClient, pageSize: Int,
    flightJoined: (@Sendable () -> Void)?
  ) {
    self.flightJoined = flightJoined
    self.client = client
    self.accountDAO = AccountDAO(database: database)
    self.libraryDAO = LibraryDAO(database: database)
    self.store = LibraryCollectionStore(database: database)
    self.pageSize = min(max(pageSize, 1), CollectionPlaylistBounds.maximum)
  }

  /// Every included library: book libraries for collections and playlists, podcast libraries for
  /// playlists only, since collections hold books only. With `force == false` a library and kind
  /// that already has a snapshot is skipped, which is how opening the Collections mode fills a
  /// cold cache without refetching a warm one. A failed library keeps its rows and does not stop
  /// its siblings. The SyncEngine hand-off and pull to refresh pass `force: true`.
  public func refreshAll(force: Bool) async {
    guard let accountRecord = try? accountDAO.fetch(), let accountID = accountRecord.id,
      let account = try? tokenAccount(for: accountRecord),
      let libraries = try? libraryDAO.fetchIncluded(accountId: accountID)
    else { return }

    for library in libraries {
      for kind in Self.kinds(forMediaType: library.mediaType) {
        if force == false,
          await store.hasSnapshot(
            accountID: accountID, libraryID: library.serverLibraryId, kind: kind.persisted)
        {
          continue
        }
        _ = try? await refresh(
          accountID: accountID, account: account, libraryID: library.serverLibraryId, kind: kind)
      }
    }
  }

  /// One library and kind, single-flight per account, library and kind: an overlapping caller
  /// awaits the running pass instead of starting another.
  public func refresh(
    libraryID: String, kind: LibraryCollectionKind
  ) async throws -> PassOutcome {
    guard let accountRecord = try accountDAO.fetch(), let accountID = accountRecord.id else {
      return .libraryUnavailable
    }
    let account = try tokenAccount(for: accountRecord)
    return try await refresh(
      accountID: accountID, account: account, libraryID: libraryID, kind: kind)
  }

  static func kinds(forMediaType mediaType: String) -> [LibraryCollectionKind] {
    mediaType == "podcast" ? [.playlist] : [.collection, .playlist]
  }

  private func refresh(
    accountID: Int64, account: TokenAccount, libraryID: String, kind: LibraryCollectionKind
  ) async throws -> PassOutcome {
    let key = "\(accountID)#\(libraryID)#\(kind.rawValue)"
    if let flight = flights[key] {
      flightJoined?()
      return try await flight.value
    }
    let client = self.client
    let store = self.store
    let pageSize = self.pageSize
    let flight = Task {
      guard
        let lists = try await Self.walk(
          client: client, account: account, libraryID: libraryID, kind: kind, pageSize: pageSize)
      else { return PassOutcome.lossy }
      let replaced = try await store.replaceSnapshot(
        accountID: accountID, libraryID: libraryID, kind: kind.persisted,
        lists: lists.map(Self.snapshotList))
      return replaced ? PassOutcome.replaced(listCount: lists.count) : .libraryUnavailable
    }
    flights[key] = flight
    defer { flights[key] = nil }
    return try await flight.value
  }

  /// Walks every page in order. Returns nil when the pass cannot prove it is complete.
  static func walk(
    client: ABSClient, account: TokenAccount, libraryID: String, kind: LibraryCollectionKind,
    pageSize: Int
  ) async throws -> [LibraryCollectionSummary]? {
    var lists: [LibraryCollectionSummary] = []
    var seen: Set<String> = []
    var expectedTotal: Int?
    var lossy = false
    var pageIndex = 0
    var maximumPages = 1

    while true {
      let page =
        switch kind {
        case .collection:
          try await client.listLibraryCollections(
            account: account, library: libraryID, limit: pageSize, page: pageIndex)
        case .playlist:
          try await client.listLibraryPlaylists(
            account: account, library: libraryID, limit: pageSize, page: pageIndex)
        }
      if page.droppedCount > 0 { lossy = true }
      if let expectedTotal {
        if page.total != expectedTotal { lossy = true }
      } else {
        expectedTotal = page.total
        // A hard ceiling from the first reported total, plus one page.
        maximumPages = max(1, (page.total + pageSize - 1) / pageSize) + 1
      }
      for list in page.lists {
        if seen.insert(list.id).inserted {
          lists.append(list)
        } else {
          lossy = true
        }
      }
      if lists.count > CollectionPlaylistBounds.maximumListsPerLibrary { return nil }
      let total = expectedTotal ?? 0
      if page.lists.count < pageSize || seen.count >= total { break }
      pageIndex += 1
      if pageIndex >= maximumPages {
        lossy = true
        break
      }
    }
    if seen.count < (expectedTotal ?? 0) { lossy = true }
    return lossy ? nil : lists
  }

  private static func snapshotList(_ list: LibraryCollectionSummary) -> LibraryCollectionSnapshotList {
    LibraryCollectionSnapshotList(
      serverID: list.id, name: list.name, description: list.description,
      lastUpdate: list.lastUpdate,
      members: list.members.map {
        LibraryCollectionSnapshotMember(
          serverItemID: $0.serverItemID, serverEpisodeID: $0.serverEpisodeID,
          fallbackTitle: $0.fallbackTitle)
      })
  }
}

extension LibraryCollectionKind {
  var persisted: LibraryCollectionListKind {
    switch self {
    case .collection: .collection
    case .playlist: .playlist
    }
  }
}
