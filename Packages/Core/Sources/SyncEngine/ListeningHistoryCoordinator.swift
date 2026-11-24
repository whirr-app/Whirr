import ABSApi
import Foundation
import Persistence

/// One past listening session for an item, as `ItemHistoryModel` (AppModel) renders it. A domain
/// type, never the ABSApi wire shape (wire DTOs stop in SyncEngine, per ARCHITECTURE.md).
public struct ListeningHistoryEntry: Sendable, Equatable {
  public let sessionId: String
  public let startedAt: Date
  public let startPosition: Double
  public let endPosition: Double
  public let listenedSeconds: Double

  public init(
    sessionId: String,
    startedAt: Date,
    startPosition: Double,
    endPosition: Double,
    listenedSeconds: Double
  ) {
    self.sessionId = sessionId
    self.startedAt = startedAt
    self.startPosition = startPosition
    self.endPosition = endPosition
    self.listenedSeconds = listenedSeconds
  }
}

/// The seam `ItemHistoryModel` (AppModel) depends on. It lives here, not in `Persistence`,
/// because `ListeningHistoryEntry` is a `SyncEngine`-owned domain type (the lowest module
/// AppModel may see, as with `AccountLifecycle` in `SyncEngineBoundaries.swift`).
public protocol ListeningHistoryProviding: Sendable {
  /// Cached entries for `itemId` (the server item id), newest session first. Never touches the
  /// network, so it is safe before any refresh has completed or while offline.
  func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry]

  /// Fetches fresh history for `itemId` from the server, filters/maps/upserts each page into the
  /// local cache, and reports whether the walk succeeded. `onPagePersisted` is called once after
  /// each page's matching entries are durably upserted, allowing callers to publish partial
  /// results. A `false` result means the walk did not complete; pages already upserted remain in
  /// the cache. This method never throws and never calls the callback after returning.
  @discardableResult
  func refreshListeningHistory(
    itemId: String, onPagePersisted: @escaping @Sendable () async -> Void
  ) async -> Bool
}

extension ListeningHistoryProviding {
  @discardableResult
  public func refreshListeningHistory(itemId: String) async -> Bool {
    await refreshListeningHistory(itemId: itemId, onPagePersisted: {})
  }
}

/// Default `ListeningHistoryProviding` for callers with no concrete coordinator composed:
/// always empty and unrefreshed.
public struct NoOpListeningHistoryProviding: ListeningHistoryProviding, Sendable {
  public init() {}
  public func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry] { [] }

  @discardableResult
  public func refreshListeningHistory(
    itemId: String, onPagePersisted: @escaping @Sendable () async -> Void
  ) async -> Bool { false }
}

/// The production `ListeningHistoryProviding` conformance. Fetches closed session history only;
/// audiobooks use the per-item route, podcasts and unsupported servers the account-wide route
/// with client-side filtering.
///
/// A plain `actor`, not part of `SyncEngine`, whose stored properties are `private` to its file
/// (`OutboxDrainer` and `AccountServerTimeObserver` are separate for the same reason). Composed
/// beside `SyncEngine` at the app-wiring layer.
public actor ListeningHistoryCoordinator: ListeningHistoryProviding {
  /// Hard pagination cap for the podcast/fallback account-wide walk. Audiobook refreshes use the
  /// server-side per-item route and normally finish after one page.
  static let maximumPages = 10
  private static let itemsPerPage = 50
  private var perItemRouteSupported = true

  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let itemDAO: ItemDAO
  private let historyDAO: ListeningHistoryDAO

  public init(client: ABSClient, database: AppDatabase) {
    self.client = client
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    historyDAO = ListeningHistoryDAO(database: database)
  }

  public func cachedListeningHistory(itemId: String) async -> [ListeningHistoryEntry] {
    guard let identity = try? resolveLocalIdentity(itemId: itemId) else { return [] }
    let records = (try? historyDAO.fetchAll(accountId: identity.accountId, itemId: identity.itemRowId)) ?? []
    return records.map(Self.map(record:))
  }

  @discardableResult
  public func refreshListeningHistory(
    itemId: String, onPagePersisted: @escaping @Sendable () async -> Void
  ) async -> Bool {
    guard let identity = try? resolveLocalIdentity(itemId: itemId) else { return false }
    guard let account = try? tokenAccount(for: identity.accountRecord) else { return false }

    let category = ItemMediaCategory.derive(
      mediaKind: identity.item.mediaKind,
      numAudioFiles: identity.item.numAudioFiles,
      ebookFormat: identity.item.ebookFormat)
    // Only a book: with no episode id the per-item route scopes to the podcast's own media id,
    // which no episode session carries, so a podcast would get an empty `200` indistinguishable
    // from "no history". Podcasts use the account-wide walk.
    var usePerItemRoute = category == .audiobook && perItemRouteSupported

    // One page loop for both routes: the per-item route usually ends after one request; the
    // account-wide route (podcasts, and any server that 404s the per-item one) walks the whole
    // history, filtering each page to `itemId`. It stops on a short page (the observed end signal;
    // the `total`/`itemsPerPage` echo fields are not relied on), an empty page, or `maximumPages`.
    // Each page is persisted and published before the next fetch, so a mid-way failure keeps
    // everything already written.
    var page = 0
    var pagesFetched = 0

    while pagesFetched < Self.maximumPages {
      let fetched: ListeningSessionHistoryPage
      do {
        if usePerItemRoute {
          fetched = try await client.fetchItemListeningSessionHistory(
            account: account, itemID: itemId, page: page, itemsPerPage: Self.itemsPerPage)
        } else {
          fetched = try await client.fetchListeningSessionHistory(
            account: account, page: page, itemsPerPage: Self.itemsPerPage)
        }
      } catch {
        if usePerItemRoute, page == 0, error as? APIError == .notFound {
          perItemRouteSupported = false
          usePerItemRoute = false
          page = 0
          pagesFetched = 0
          continue
        }
        return false
      }
      pagesFetched += 1

      do {
        for entry in fetched.entries where entry.libraryItemID == itemId {
          guard let startedAt = entry.startedAt else { continue }
          let record = ListeningHistoryEntryRecord(
            accountId: identity.accountId,
            itemId: identity.itemRowId,
            sessionId: entry.id,
            startedAt: startedAt,
            startPosition: entry.startTime ?? 0,
            endPosition: entry.currentTime ?? entry.startTime ?? 0,
            listenedSeconds: entry.timeListening ?? 0
          )
          _ = try historyDAO.upsert(record)
        }
      } catch {
        return false
      }
      await onPagePersisted()

      guard fetched.entries.count == Self.itemsPerPage else { break }
      page += 1
    }
    return true
  }

  private func resolveLocalIdentity(
    itemId: String
  ) throws -> (accountId: Int64, accountRecord: AccountRecord, itemRowId: Int64, item: ItemRecord) {
    guard let accountRecord = try accountDAO.fetch(), let accountId = accountRecord.id else {
      throw ListeningHistoryCoordinatorError.notAuthenticated
    }
    guard let item = try itemDAO.fetchOne(accountId: accountId, serverItemId: itemId), let itemRowId = item.id else {
      throw ListeningHistoryCoordinatorError.itemNotFound
    }
    return (accountId, accountRecord, itemRowId, item)
  }

  private static func map(record: ListeningHistoryEntryRecord) -> ListeningHistoryEntry {
    ListeningHistoryEntry(
      sessionId: record.sessionId,
      startedAt: record.startedAt,
      startPosition: record.startPosition,
      endPosition: record.endPosition,
      listenedSeconds: record.listenedSeconds
    )
  }
}

enum ListeningHistoryCoordinatorError: Error, Sendable, Equatable {
  case notAuthenticated
  case itemNotFound
}
