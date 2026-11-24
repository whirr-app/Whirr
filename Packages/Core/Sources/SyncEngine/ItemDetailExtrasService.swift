import ABSApi
import Foundation
import Persistence

/// AppModel's boundary onto `ItemDetailExtrasService` (ARCHITECTURE.md §2: `SyncEngine` alone may
/// initiate metadata fetches, so AppModel cannot import the concrete actor). A single on-demand
/// read, not a stream: chapters are returned, while the series and narrator scalars are written
/// through to the local item projection. The concrete service coalesces concurrent requests and
/// keeps a small bounded in-memory cache.
public protocol ItemDetailExtrasAccess: Sendable {
  /// `nil` on any failure to produce a value: an unauthenticated account, a transport or decode
  /// failure, or any other fetch failure. Never throws, since the caller
  /// (`ItemDetailExtrasModel`) only ever shows "unavailable" for a failure.
  func itemDetailExtras(itemId: String) async -> ItemDetailExtras?
}

/// Default `ItemDetailExtrasAccess` for callers with no concrete service composed. Always `nil`,
/// so `ItemDetailExtrasModel` immediately resolves to `.unavailable`.
public struct NoOpItemDetailExtrasAccess: ItemDetailExtrasAccess, Sendable {
  public init() {}
  public func itemDetailExtras(itemId: String) async -> ItemDetailExtras? { nil }
}

/// The production `ItemDetailExtrasAccess` conformance. A standalone SyncEngine-owned actor with
/// its own `AccountDAO`/`ABSClient`, not an extension on the `SyncEngine` actor.
public actor ItemDetailExtrasService: ItemDetailExtrasAccess {
  private struct LoadedExtras: Sendable {
    let value: ItemDetailExtras
    let persistable: PersistableExpandedItem?
    let accountID: Int64?
    /// A stale or unstamped stored copy answered because the fetch failed. Not cached, so the
    /// next request tries the network again.
    var isFallback = false
  }

  private struct CacheEntry {
    let value: ItemDetailExtras
    var recency: UInt64
  }

  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let itemDAO: ItemDAO
  private let itemChapterStore: ItemChapterStore
  private let persistor: ExpandedItemPersistor
  private let cacheLimit: Int
  private var cache: [String: CacheEntry] = [:]
  private var inFlight: [String: Task<LoadedExtras?, Never>] = [:]
  private var recency: UInt64 = 0

  public init(database: AppDatabase, client: ABSClient, cacheLimit: Int = 24) {
    self.accountDAO = AccountDAO(database: database)
    self.itemDAO = ItemDAO(database: database)
    self.itemChapterStore = ItemChapterStore(database: database)
    self.persistor = ExpandedItemPersistor(database: database)
    self.client = client
    self.cacheLimit = max(1, cacheLimit)
  }

  public func itemDetailExtras(itemId: String) async -> ItemDetailExtras? {
    guard let identity = PodcastSourceIdentity(itemId: itemId), case .abs = identity.source else {
      return nil
    }
    if var entry = cache[itemId] {
      entry.recency = nextRecency()
      cache[itemId] = entry
      return entry.value
    }
    if let task = inFlight[itemId] {
      return await task.value?.value
    }

    return await load(itemId: itemId, accountRecord: nil)
  }

  /// Split from the cache/coalescing entry point so the "account row with no resolvable `id`"
  /// path is testable: `account.id` is an `INTEGER PRIMARY KEY`, so a row from
  /// `AccountDAO.fetch()` always has one, and handing the record in is the only way to exercise
  /// the write-through skip.
  func itemDetailExtras(itemId: String, accountRecord: AccountRecord) async -> ItemDetailExtras? {
    await load(itemId: itemId, accountRecord: accountRecord)
  }

  /// One implementation for both entry points; a supplied `accountRecord` replaces only the lookup.
  ///
  /// The lookup lives inside the task because `inFlight` is registered synchronously after the
  /// task is created; awaiting the account row first would suspend before registration and let
  /// two simultaneous callers both fetch.
  private func load(itemId: String, accountRecord: AccountRecord?) async -> ItemDetailExtras? {
    let accountDAO = self.accountDAO
    let itemDAO = self.itemDAO
    let itemChapterStore = self.itemChapterStore
    let client = self.client
    let task = Task<LoadedExtras?, Never> {
      let resolved: AccountRecord?
      if let accountRecord {
        resolved = accountRecord
      } else {
        resolved = try? await accountDAO.fetchAsync()
      }
      guard let accountRecord = resolved else { return nil }

      // The stored copy: the expanded fetch's write-through, or the chapters a download persisted
      // from its own expanded request without stamping `expandedMetadataFetchedAt`.
      var stored: LoadedExtras?
      if let accountID = accountRecord.id,
        let item = try? await itemDAO.fetchOneAsync(accountId: accountID, serverItemId: itemId)
      {
        let storedChapters: [StoredItemChapter]
        if let itemID = item.id {
          storedChapters =
            (try? await itemChapterStore.fetchAsync(
              accountId: accountID, itemId: itemID)) ?? []
        } else {
          storedChapters = []
        }
        if item.expandedMetadataFetchedAt != nil || storedChapters.isEmpty == false {
          stored = LoadedExtras(
            value: ItemDetailExtras(
              seriesName: item.seriesName,
              narrator: item.narratorName,
              chapters: storedChapters.map {
                ItemChapterInfo(title: $0.title, start: $0.start, end: $0.end)
              },
              description: item.itemDescription),
            persistable: nil,
            accountID: accountID)
        }
        // The stored answer is authoritative until the server's own record moves past the fetch
        // that produced it. A library scan that picks up a replaced file bumps `updatedAt`, the
        // only signal that the expanded copy (including the ebook file identity downloads are
        // planned from) no longer describes the file the server holds.
        if let stored, item.expandedMetadataFetchedAt != nil,
          ItemRecord.expandedMetadataIsStale(
            fetchedAt: item.expandedMetadataFetchedAt,
            serverUpdatedAt: item.serverUpdatedAt) == false
        {
          return stored
        }
      }

      // A failed fetch falls back to the stored copy rather than nothing: on a cold launch the
      // fetch can fail before the session's credentials are fresh, and the model never retries,
      // so the player would show no chapters for a book whose chapters are on disk.
      stored?.isFallback = true
      guard let account = try? tokenAccount(for: accountRecord) else { return stored }
      guard let detail = try? await client.fetchItemDetail(account: account, itemID: itemId) else {
        return stored
      }
      return Self.loadedExtras(from: detail, accountID: accountRecord.id)
    }
    inFlight[itemId] = task
    guard let loaded = await task.value else {
      inFlight[itemId] = nil
      return nil
    }
    inFlight[itemId] = nil
    return await complete(loaded, itemId: itemId)
  }

  private func complete(_ loaded: LoadedExtras, itemId: String) async -> ItemDetailExtras {
    guard loaded.isFallback == false else { return loaded.value }
    cache[itemId] = CacheEntry(value: loaded.value, recency: nextRecency())
    evictIfNeeded()

    // Chapters are read-only server data and need no local account row to be readable, so an
    // unresolvable `id` skips only the write-through. It must not suppress the value and push the
    // detail screen into its "Chapters Unavailable" state.
    if let accountID = loaded.accountID, let persistable = loaded.persistable {
      await persistor.persist(
        persistable, accountId: accountID, serverItemId: itemId, fetchedAt: Date())
    }
    return loaded.value
  }

  private nonisolated static func loadedExtras(
    from detail: ItemDetail, accountID: Int64?
  ) -> LoadedExtras {
    let persistable = ExpandedItemPersistor.persistable(from: detail)
    let value: ItemDetailExtras
    switch detail.media {
    case nil, .podcast:
      value = ItemDetailExtras(seriesName: nil, narrator: nil, chapters: [])
    case .book(let book):
      value = ItemDetailExtras(
        seriesName: book.seriesName,
        narrator: book.narratorName,
        chapters: ItemDetailExtras.makeChapters(from: book.chapters, duration: book.duration),
        description: book.description)
    }
    return LoadedExtras(value: value, persistable: persistable, accountID: accountID)
  }

  private func nextRecency() -> UInt64 {
    recency &+= 1
    return recency
  }

  private func evictIfNeeded() {
    while cache.count > cacheLimit,
      let oldest = cache.min(by: { $0.value.recency < $1.value.recency })?.key
    {
      cache[oldest] = nil
    }
  }
}
