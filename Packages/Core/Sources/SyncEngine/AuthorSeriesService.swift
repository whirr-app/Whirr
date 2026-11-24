import ABSApi
import Foundation
import Persistence

/// The production `AuthorSeriesReading` conformance: a standalone actor with its own
/// `AccountDAO`/`ABSClient`, like `ItemDetailExtrasService`/`ResolutionCenter`.
///
/// `items(kind:entityID:libraryID:limit:offset:)` does not parse `SeriesBooks.books[]`. It reuses
/// the paginated `/api/libraries/{id}/items?filter=authors|series.<id>` route
/// (`LibraryEndpoints.swift`), which carries real `total`/`limit`/`page` for both kinds.
public actor AuthorSeriesService: AuthorSeriesReading {
  private let client: ABSClient
  private let accountDAO: AccountDAO
  private let libraryDAO: LibraryDAO
  private let entityStore: AuthorSeriesEntityStore
  private var refreshFlights: [String: Task<[AuthorSeriesSnapshotEntry], Error>] = [:]
  /// Before the first library traversal there may be no FK row to persist against. Keep that
  /// narrow bootstrap case useful for this service instance; the next normal sync creates the
  /// library row and a forced refresh makes it durable.
  private var transientSnapshots: [String: [AuthorSeriesSnapshotEntry]] = [:]

  public init(database: AppDatabase, client: ABSClient) {
    self.accountDAO = AccountDAO(database: database)
    self.libraryDAO = LibraryDAO(database: database)
    self.entityStore = AuthorSeriesEntityStore(database: database)
    self.client = client
  }

  public func entities(
    kind: SearchResultKind,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    let libraryIDs = resolvedLibraryIDs(requested: libraryID)
    try await ensureSnapshots(libraryIDs: libraryIDs, force: false)
    let entities = await cachedEntities(kind: kind, libraryIDs: libraryIDs)
    // `filterdata` is complete. The legacy paging parameters remain on the shared reading boundary
    // for source compatibility with entity detail, but there is no partial rail.
    return AuthorSeriesBrowsePage(entities: entities, hasMore: false)
  }

  public func refreshEntities(
    kind: SearchResultKind,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    let libraryIDs = resolvedLibraryIDs(requested: libraryID)
    try await ensureSnapshots(libraryIDs: libraryIDs, force: true)
    return AuthorSeriesBrowsePage(
      entities: await cachedEntities(kind: kind, libraryIDs: libraryIDs), hasMore: false)
  }

  /// SyncEngine correctness event: refresh every live book library once. The per-library flights
  /// above coalesce this with an Authors/Series screen or pull-to-refresh already in progress.
  public func refreshAllSnapshots() async {
    try? await ensureSnapshots(libraryIDs: resolvedLibraryIDs(requested: nil), force: true)
  }

  public func observeEntities(
    kind: SearchResultKind, libraryID: String?
  ) async -> AsyncStream<[AuthorSeriesEntity]> {
    guard let accountRecord = try? accountDAO.fetch(), let accountID = accountRecord.id else {
      return AsyncStream { $0.finish() }
    }
    return entityStore.observeEntities(
      accountID: accountID, kind: kind,
      libraryIDs: resolvedLibraryIDs(requested: libraryID))
  }

  public func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity? {
    // Resolved from the merged listing the browse rows use: the per-library route has no id
    // filter and would find only one half of an entity spanning two libraries. The caller's
    // library goes first (a search hit resolves even before a sync has recorded it locally),
    // then the others, so the entity returns with every id.
    var libraryIDs = resolvedLibraryIDs(requested: libraryID)
    for id in resolvedLibraryIDs(requested: nil) where libraryIDs.contains(id) == false {
      libraryIDs.append(id)
    }
    try await ensureSnapshots(libraryIDs: libraryIDs, force: false)
    let entities = await cachedEntities(kind: kind, libraryIDs: libraryIDs)
    guard
      let match = entities.first(where: { entity in
        entity.identities.contains { $0.entityID == entityID }
      })
    else { return nil }
    // The identity the caller navigated by leads, so `entityID`/`libraryID` answer with the one
    // they asked about (a search hit stays in the library it was found in), and the entity's
    // other libraries follow.
    let requested = match.identities.filter { $0.entityID == entityID }
    let rest = match.identities.filter { $0.entityID != entityID }
    return AuthorSeriesEntity(
      kind: match.kind, name: match.name, identities: requested + rest, bookCount: match.bookCount)
  }

  public func entity(kind: SearchResultKind, named name: String) async throws -> AuthorSeriesEntity? {
    let libraryIDs = resolvedLibraryIDs(requested: nil)
    try await ensureSnapshots(libraryIDs: libraryIDs, force: false)
    let normalizedName = AuthorSeriesEntity.normalizedName(name)
    return await cachedEntities(kind: kind, libraryIDs: libraryIDs).first {
      AuthorSeriesEntity.normalizedName($0.name) == normalizedName
    }
  }

  public func narratorLibraryIDs() async throws -> [String] {
    resolvedLibraryIDs(requested: nil)
  }

  /// Every library's authors or series, folded into one entity per name.
  ///
  /// Audiobookshelf files authors and series per library, so a reader with ebooks and audiobooks
  /// apart has two ids for one author. A single-library listing would drop the others' entities,
  /// and a row could count books its own id cannot list. An explicit `libraryID` still asks that
  /// library alone.
  private func cachedEntities(
    kind: SearchResultKind, libraryIDs: [String]
  ) async -> [AuthorSeriesEntity] {
    guard let accountRecord = try? accountDAO.fetch(), let accountID = accountRecord.id else {
      return []
    }
    var order: [String] = []
    var merged: [String: MergedEntity] = [:]
    for libraryID in libraryIDs {
      let persisted = await entityStore.entities(
        accountID: accountID, kind: kind, libraryIDs: [libraryID])
      let entities: [AuthorSeriesEntity]
      if persisted.isEmpty, let transient = transientSnapshots[libraryID] {
        entities = transient.filter { $0.kind == kind }.map {
          AuthorSeriesEntity(
            kind: kind, entityID: $0.entityID, name: $0.name, libraryID: libraryID,
            bookCount: $0.bookCount)
        }
      } else {
        entities = persisted
      }
      for entity in entities {
        let key = AuthorSeriesEntity.normalizedName(entity.name)
        if merged[key] == nil {
          order.append(key)
          merged[key] = MergedEntity(
            name: entity.name, identities: entity.identities, bookCount: entity.bookCount)
        } else {
          merged[key]?.append(entity)
        }
      }
    }
    return order.compactMap { key in
      guard let value = merged[key] else { return nil }
      return AuthorSeriesEntity(
        kind: kind, name: value.name, identities: value.identities, bookCount: value.bookCount)
    }
  }

  private struct MergedEntity {
    var name: String
    var identities: [AuthorSeriesEntity.Identity]
    var bookCount: Int?

    mutating func append(_ entity: AuthorSeriesEntity) {
      identities.append(contentsOf: entity.identities)
      guard let count = entity.bookCount else { return }
      bookCount = (bookCount ?? 0) + count
    }
  }

  private func ensureSnapshots(libraryIDs: [String], force: Bool) async throws {
    guard let accountRecord = try? accountDAO.fetch(), let accountID = accountRecord.id,
      let account = try? tokenAccount(for: accountRecord)
    else { return }

    for libraryID in libraryIDs {
      if force == false,
        await entityStore.hasSnapshot(accountID: accountID, libraryID: libraryID)
          || transientSnapshots[libraryID] != nil
      {
        continue
      }
      do {
        try await refreshSnapshot(
          accountID: accountID, account: account, libraryID: libraryID)
      } catch {
        // A failed library retains its previous snapshot and must not blank successful siblings.
        continue
      }
    }
  }

  private func refreshSnapshot(
    accountID: Int64, account: TokenAccount, libraryID: String
  ) async throws {
    let key = "\(accountID)#\(libraryID)"
    if let flight = refreshFlights[key] {
      transientSnapshots[libraryID] = try await flight.value
      return
    }
    let client = self.client
    let store = entityStore
    let flight = Task {
      let filterData = try await client.getLibraryFilterData(account: account, library: libraryID)
      let authors = filterData.authors.map { author in
        AuthorSeriesSnapshotEntry(
          kind: .author, entityID: author.id,
          name: Self.displayName(author.name, fallback: "Unknown author"),
          bookCount: author.numBooks)
      }
      let series = filterData.series.map { series in
        AuthorSeriesSnapshotEntry(
          kind: .series, entityID: series.id,
          name: Self.displayName(series.name, fallback: "Untitled series"))
      }
      let entries = authors + series
      try await store.replaceSnapshot(
        accountID: accountID, libraryID: libraryID, entries: entries)
      return entries
    }
    refreshFlights[key] = flight
    defer { refreshFlights[key] = nil }
    transientSnapshots[libraryID] = try await flight.value
  }

  public func items(
    kind: SearchResultKind, entityID: String, libraryID: String?, limit: Int, offset: Int
  ) async throws -> SearchPage {
    guard let filterGroup = Self.itemsFilterGroup(for: kind) else {
      return SearchPage(rows: [], hasMore: false)
    }
    return try await itemPage(
      libraryID: libraryID,
      limit: limit,
      offset: offset,
      sort: Self.itemsSort(for: kind),
      filter: LibraryItemFilter(group: filterGroup, value: entityID),
      narratorName: nil)
  }

  /// Narrators have no entity id to filter by, so this route carries the name it asked for back
  /// onto every row: the minified listing does not return one, and the destination's rows would
  /// otherwise be the only place in the app that knows a narrator and cannot say so.
  public func items(
    narratorName: String, libraryID: String, limit: Int, offset: Int
  ) async throws -> SearchPage {
    try await itemPage(
      libraryID: libraryID,
      limit: limit,
      offset: offset,
      sort: nil,
      filter: LibraryItemFilter(group: "narrators", value: narratorName),
      narratorName: narratorName)
  }

  /// The one bounded listing every entity destination pages through.
  private func itemPage(
    libraryID: String?,
    limit: Int,
    offset: Int,
    sort: String?,
    filter: LibraryItemFilter,
    narratorName: String?
  ) async throws -> SearchPage {
    guard let (account, resolvedLibraryID) = try? resolvedAccount(libraryID: libraryID) else {
      return SearchPage(rows: [], hasMore: false)
    }

    // Per-identity cursors advance by the bounded limit, so an offset that is not an exact page
    // boundary is a caller error. Rejecting it here prevents integer division from re-fetching an
    // earlier server page when a malformed cursor reaches the transport boundary.
    let boundedLimit = max(limit, 1)
    guard limit > 0, offset >= 0, offset % boundedLimit == 0 else {
      return SearchPage(rows: [], hasMore: false)
    }
    let page = offset / boundedLimit

    guard
      let itemsPage = try? await client.listLibraryItems(
        account: account, library: resolvedLibraryID, page: page, limit: limit,
        sort: sort, filter: filter)
    else {
      return SearchPage(rows: [], hasMore: false)
    }

    let rows = itemsPage.items.map { item in
      SearchResultRow(
        kind: item.mediaType == "podcast" ? .podcast : .book,
        entityID: item.id,
        title: item.title ?? "",
        subtitle: item.authorName,
        // The minified route already returns both, and the row type already carries both: a screen
        // that dropped them could only render a title over the author name it was reached by.
        mediaCategory: ItemMediaCategory.derive(
          mediaKind: item.mediaType ?? "", numAudioFiles: item.numAudioFiles,
          ebookFormat: item.ebookFormat),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: item.ebookFormat),
        seriesName: item.seriesName,
        durationSeconds: item.durationSeconds,
        narratorName: narratorName,
        libraryID: item.libraryID ?? resolvedLibraryID,
        serverUpdatedAt: item.updatedAt)
    }
    let hasMore = (itemsPage.page + 1) * itemsPage.limit < itemsPage.total
    return SearchPage(rows: rows, hasMore: hasMore)
  }

  /// A series reads in sequence order or it does not read at all, and `sequence` is a valid sort
  /// only while filtering by series, which this route does. The request keeps each identity's
  /// server pages in the right broad order; AppModel owns the complete-window ordering after
  /// identities and pages are merged.
  private static func itemsSort(for kind: SearchResultKind) -> String? {
    kind == .series ? "sequence" : nil
  }

  private static func itemsFilterGroup(for kind: SearchResultKind) -> String? {
    switch kind {
    case .author: "authors"
    case .series: "series"
    case .book, .podcast, .episode: nil
    }
  }

  private static func displayName(_ name: String?, fallback: String) -> String {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty == false
    else { return fallback }
    return name
  }

  private func resolvedTokenAccount() throws -> TokenAccount? {
    guard let accountRecord = try accountDAO.fetch() else { return nil }
    return try accountRecord.credentialTokenAccount
  }

  /// The libraries an entity listing covers: the one asked for, or (the browse root's case) every
  /// synced library that can hold authors and series. Podcast libraries are skipped: their filter
  /// data has no author or series index, so asking is a wasted request per refresh.
  private func resolvedLibraryIDs(requested: String?) -> [String] {
    if let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
      requested.isEmpty == false
    {
      return [requested]
    }
    guard let accountRecord = try? accountDAO.fetch(), let accountId = accountRecord.id,
      let libraries = try? libraryDAO.fetchIncluded(accountId: accountId)
    else { return [] }
    let bookLibraryIDs = libraries.filter { $0.mediaType != "podcast" }.map(\.serverLibraryId)
    return bookLibraryIDs
  }

  private func resolvedAccount(libraryID: String?) throws -> (account: TokenAccount, libraryID: String)? {
    guard let accountRecord = try accountDAO.fetch() else { return nil }
    let requestedLibraryID = libraryID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let includedLibraryID: String?
    if let accountID = accountRecord.id {
      includedLibraryID = try libraryDAO.fetchIncluded(accountId: accountID).first?.serverLibraryId
    } else {
      includedLibraryID = nil
    }
    guard
      let resolvedLibraryID = requestedLibraryID.flatMap({ $0.isEmpty ? nil : $0 })
        ?? includedLibraryID
    else { return nil }
    let account = try tokenAccount(for: accountRecord)
    return (account, resolvedLibraryID)
  }
}

private enum AuthorSeriesServiceBounds {
  /// The entity-lookup fetch's page size.
  static let entityLookupLimit = 100
}
