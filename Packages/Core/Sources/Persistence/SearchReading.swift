import Foundation

/// One page of search rows plus whether more exist beyond it. Shared by the `SearchReading`
/// query methods and `AuthorSeriesReading`'s item listing, so `hasMore` paging is expressed once.
public struct SearchPage: Sendable, Equatable {
  public let rows: [SearchResultRow]
  public let hasMore: Bool

  public init(rows: [SearchResultRow], hasMore: Bool) {
    self.rows = rows
    self.hasMore = hasMore
  }
}

/// Read side of local search. Mirrors `LibraryReading`/`HomeReading`'s boundary rule: screens
/// observe a projection, never a GRDB type.
public protocol SearchReading: Sendable {
  /// Books/podcasts ranked by match quality, cross-library when `libraryIDs` is `nil`,
  /// restricted to the given set otherwise. `limit`/`offset` apply after filtering and ranking.
  func searchItems(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage

  /// Of `ids`, the server item ids whose local `item` row satisfies `filters`' download and
  /// playback dimensions. Uses the same `ItemFilterPredicate` SQL as `searchItems`, so server-
  /// resolved and locally-found rows agree.
  ///
  /// Item scope only: `SyncEngine`'s fan-out cannot produce a `.episode` match and the item
  /// playback predicate excludes podcast shows. An id with no local row is not admitted.
  func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String>

  /// Podcast episodes, local-only: the client's library search never returns them. Same paging
  /// contract as `searchItems`.
  ///
  /// A client property, not the server's: `/api/libraries/{id}/search` (2.35.1) carries a
  /// top-level `episodes` bucket on podcast libraries that `ABSApi.SearchResultsDTO` does not
  /// decode (see `SearchEndpoint.swift`), so nothing above `SyncEngine`'s fan-out may assume a
  /// `.episode` match. Decoding it would need an episode id on `SearchMatch` first.
  func searchEpisodes(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage

  /// Books/podcasts whose words are each within a small edit distance of a query token. The
  /// close-match fallback, asked only after strict search found nothing. One unpaged page,
  /// nearest spelling first: there is no `offset`, and `hasMore` is always `false`.
  func closeMatchItems(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int
  ) async throws -> SearchPage

  /// Episodes, matched by title and subtitle only, under the same contract as `closeMatchItems`.
  func closeMatchEpisodes(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int
  ) async throws -> SearchPage
}

/// Incremental-composition defaults: a conformance that does not implement the fallback finds no
/// close matches rather than fabricating any. A test exercising the fallback must stub these and
/// assert they were called, or it can pass while testing nothing.
extension SearchReading {
  public func closeMatchItems(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }

  public func closeMatchEpisodes(
    query: String, libraryIDs: [String]?, filters: BrowseFilters, limit: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }
}

/// Incremental-composition default: no database and no fabricated search results, mirroring
/// `NoOpHomeReading`/`NoOpPodcastReading`.
public struct NoOpSearchReading: SearchReading, Sendable {
  public init() {}

  public func searchItems(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }

  public func admittedItemIDs(_ ids: [String], filters: BrowseFilters) async throws -> Set<String> {
    Set(ids)
  }

  public func searchEpisodes(
    query: String,
    libraryIDs: [String]?,
    filters: BrowseFilters,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }
}

/// One entry in the per-account recent-search list.
public struct RecentSearchQuery: Sendable, Equatable, Identifiable {
  public var id: String { normalizedQuery }
  /// The `SearchQueryNormalizer.normalize` form, used for de-duplication ("Gaiman" and "gaiman "
  /// are the same entry). Never displayed.
  public let normalizedQuery: String
  /// The query as the user typed it, shown in the recents list.
  public let displayQuery: String
  public let lastUsedAt: Date

  public init(normalizedQuery: String, displayQuery: String, lastUsedAt: Date) {
    self.normalizedQuery = normalizedQuery
    self.displayQuery = displayQuery
    self.lastUsedAt = lastUsedAt
  }
}

/// Per-account recent-search storage, cascade-deleted with the account. Capped at 10 entries,
/// oldest evicted first; re-recording an existing (normalized) query moves it to the front
/// instead of duplicating it. Both are the implementation's job, not this protocol's.
public protocol RecentSearchStoring: Sendable {
  func record(query: String) async throws
  /// Most-recently-used first, re-emitted on every record/clear.
  func observeRecent() -> AsyncStream<[RecentSearchQuery]>
  func clear(query: String) async throws
  func clearAll() async throws
}

/// Incremental-composition default: nothing recorded, nothing remembered.
public struct NoOpRecentSearchStoring: RecentSearchStoring, Sendable {
  public init() {}
  public func record(query: String) async throws {}
  public func observeRecent() -> AsyncStream<[RecentSearchQuery]> {
    AsyncStream { $0.finish() }
  }
  public func clear(query: String) async throws {}
  public func clearAll() async throws {}
}

/// An author or series as a navigable entity rather than plain text. `entityID`/`kind` identify
/// which of `/api/libraries/{id}/authors|series` it came from.
public struct AuthorSeriesEntity: Sendable, Equatable, Identifiable {
  /// One library's record of this entity. Audiobookshelf files authors and series per library,
  /// so a reader who keeps ebooks and audiobooks in separate libraries has two ids for one
  /// author, and neither library's id can list the other's books.
  public struct Identity: Sendable, Equatable, Hashable {
    public let entityID: String
    public let libraryID: String

    public init(entityID: String, libraryID: String) {
      self.entityID = entityID
      self.libraryID = libraryID
    }
  }

  public var id: String { "\(kind.rawValue)#\(entityID)" }
  public let kind: SearchResultKind
  public let name: String
  /// Every library that knows this entity, in the order the libraries were read. Never empty.
  public let identities: [Identity]
  /// Available for authors where Audiobookshelf supplies `numBooks`; the series listing route has
  /// no equivalent lightweight count. Summed across `identities`, since the same author in two
  /// libraries is one shelf to a reader.
  public let bookCount: Int?

  /// The identity a single-library caller means: the first library that reported this entity.
  public var entityID: String { identities[0].entityID }
  public var libraryID: String { identities[0].libraryID }

  public init(
    kind: SearchResultKind,
    entityID: String,
    name: String,
    libraryID: String,
    bookCount: Int? = nil
  ) {
    self.init(
      kind: kind, name: name,
      identities: [Identity(entityID: entityID, libraryID: libraryID)], bookCount: bookCount)
  }

  public init(
    kind: SearchResultKind,
    name: String,
    identities: [Identity],
    bookCount: Int? = nil
  ) {
    precondition(identities.isEmpty == false, "an entity is identified by at least one library")
    self.kind = kind
    self.name = name
    self.identities = identities
    self.bookCount = bookCount
  }

  /// The form two spellings of one name share: the key the same author in two libraries is
  /// merged under, and the key the local item join files a book by.
  ///
  /// Case, diacritics and width fold, and everything that is not a letter or digit is dropped, so
  /// `J. N. Chaney`, `J.N. Chaney` and `JN Chaney` are one author. Audiobookshelf files an author
  /// per name string, so differently spelled initials would otherwise list as two authors, each
  /// with only its own books.
  public static func normalizedName(_ name: String) -> String {
    let folded =
      name
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .lowercased()
    let stripped = String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    // A punctuation-only name would key on the empty string and file every such entity under
    // one row, so it keeps its own folded form.
    guard stripped.isEmpty else { return stripped }
    return folded.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// One bounded page of authors or series for the Library browse root. A server page, not a
/// database projection: the author/series routes are the source of truth for these entities and
/// already back their detail destinations.
public struct AuthorSeriesBrowsePage: Sendable, Equatable {
  public let entities: [AuthorSeriesEntity]
  public let hasMore: Bool

  public init(entities: [AuthorSeriesEntity], hasMore: Bool) {
    self.entities = entities
    self.hasMore = hasMore
  }
}

/// Boundary onto an author's or series's own item list: a live, paginated server fetch, not a
/// local projection, so (unlike `SearchReading`) it is `async throws` rather than an
/// `AsyncStream`.
public protocol AuthorSeriesReading: Sendable {
  /// A bounded page for the Authors or Series browse mode. `libraryID == nil` selects the
  /// account's default library, as the entity and item-list calls do.
  func entities(
    kind: SearchResultKind,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> AuthorSeriesBrowsePage
  /// Explicit freshness intent. Normal entity reads may answer entirely from the durable
  /// snapshot; pull-to-refresh uses this operation to replace it first.
  func refreshEntities(
    kind: SearchResultKind,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> AuthorSeriesBrowsePage
  func observeEntities(
    kind: SearchResultKind, libraryID: String?
  ) async -> AsyncStream<[AuthorSeriesEntity]>
  func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity?
  /// Resolves a semantic name route to the server identities that currently represent it.
  func entity(kind: SearchResultKind, named name: String) async throws -> AuthorSeriesEntity?
  /// A bounded page of the entity's items (`limit` is required and bounded).
  func items(
    kind: SearchResultKind,
    entityID: String,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage
  /// Narrators are indexed by display name rather than the author/series entity-id catalogue.
  func narratorLibraryIDs() async throws -> [String]
  func items(
    narratorName: String,
    libraryID: String,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage
}

/// Compatibility for destinations restored from older deep links, which did not persist the
/// source library. Production search routes pass `libraryID` explicitly.
extension AuthorSeriesReading {
  public func observeEntities(
    kind: SearchResultKind, libraryID: String?
  ) async -> AsyncStream<[AuthorSeriesEntity]> {
    AsyncStream { $0.finish() }
  }

  public func refreshEntities(
    kind: SearchResultKind, libraryID: String?, limit: Int, offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    try await entities(kind: kind, libraryID: libraryID, limit: limit, offset: offset)
  }

  /// Default for detail-only conformances. Production supplies a real page; incremental adopters
  /// show an empty list instead of fabricating entities.
  public func entities(
    kind: SearchResultKind, libraryID: String?, limit: Int, offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    AuthorSeriesBrowsePage(entities: [], hasMore: false)
  }

  public func entity(kind: SearchResultKind, entityID: String) async throws -> AuthorSeriesEntity? {
    try await entity(kind: kind, entityID: entityID, libraryID: nil)
  }

  public func entity(kind: SearchResultKind, named name: String) async throws -> AuthorSeriesEntity? {
    let page = try await entities(kind: kind, libraryID: nil, limit: 100, offset: 0)
    let normalizedName = AuthorSeriesEntity.normalizedName(name)
    return page.entities.first {
      AuthorSeriesEntity.normalizedName($0.name) == normalizedName
    }
  }

  public func narratorLibraryIDs() async throws -> [String] { [] }

  public func items(
    narratorName: String, libraryID: String, limit: Int, offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }

  public func items(
    kind: SearchResultKind, entityID: String, limit: Int, offset: Int
  ) async throws -> SearchPage {
    try await items(
      kind: kind, entityID: entityID, libraryID: nil, limit: limit, offset: offset)
  }
}

/// Incremental-composition default: no network and no fabricated authors/series.
public struct NoOpAuthorSeriesReading: AuthorSeriesReading, Sendable {
  public init() {}
  public func entities(
    kind: SearchResultKind, libraryID: String?, limit: Int, offset: Int
  ) async throws -> AuthorSeriesBrowsePage {
    AuthorSeriesBrowsePage(entities: [], hasMore: false)
  }
  public func entity(
    kind: SearchResultKind, entityID: String, libraryID: String?
  ) async throws -> AuthorSeriesEntity? {
    nil
  }
  public func items(
    kind: SearchResultKind,
    entityID: String,
    libraryID: String?,
    limit: Int,
    offset: Int
  ) async throws -> SearchPage {
    SearchPage(rows: [], hasMore: false)
  }
}
