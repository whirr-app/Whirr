import Foundation

/// Public value type for `GET /api/libraries/{id}/search`.
///
/// Live shape (2.35.1, full capture 2026-07-28): `authors` is a bare array of author objects (no
/// `{author:…}` wrapper), with `asin`/`description`/`imagePath` nullable and an undocumented extra
/// `libraryId`. `series` is wrapped: `{ "books": [<expanded library items>], "series": { "id",
/// "name", "nameIgnorePrefix", "description", "libraryId", "addedAt", "updatedAt" } }`.
/// `matchKey`/`matchText` do not appear on live `book`/`podcast` hits (`{ "libraryItem": … }`
/// only), so both stay optional on `SearchHit` in case another version sends them. The
/// `narrators`/`genres` buckets (and `episodes` on podcast libraries) are not decoded. `tags` is
/// decoded for lenient-decode parity but never exposed, since no tag data syncs.
public struct SearchResults: Sendable, Equatable {
  public let bookHits: [SearchHit]
  public let podcastHits: [SearchHit]
  public let authorHits: [SearchAuthorHit]
  public let seriesHits: [SearchSeriesHit]

  public init(
    bookHits: [SearchHit],
    podcastHits: [SearchHit],
    authorHits: [SearchAuthorHit] = [],
    seriesHits: [SearchSeriesHit] = []
  ) {
    self.bookHits = bookHits
    self.podcastHits = podcastHits
    self.authorHits = authorHits
    self.seriesHits = seriesHits
  }
}

/// A single search hit carrying `libraryItem`, `matchKey` and `matchText`. Reuses `ItemDetail`
/// for `libraryItem`, the same expanded item shape `BatchGet.swift` uses.
public struct SearchHit: Sendable, Equatable {
  public let libraryItem: ItemDetail
  public let matchKey: String?
  public let matchText: String?

  public init(libraryItem: ItemDetail, matchKey: String?, matchText: String?) {
    self.libraryItem = libraryItem
    self.matchKey = matchKey
    self.matchText = matchText
  }
}

/// A bare author entity from the search response's `authors` bucket (live-confirmed on 2.35.1; see
/// `SearchResults`). The full `AuthorExpanded` shape is documented for
/// `/api/libraries/{id}/authors`, but not every field is necessarily populated in a search
/// response. Only `id`/`name` are modelled, which is all the navigable-entity row needs.
public struct SearchAuthorHit: Sendable, Equatable {
  public let id: String
  public let name: String?

  public init(id: String, name: String?) {
    self.id = id
    self.name = name
  }
}

/// A series entity from the search response's `series` bucket, unwrapped from the live
/// `{ "series": {...}, "books": [...] }` shape (confirmed on 2.35.1; see `SearchResults`). Only
/// `id`/`name` are modelled, as with `SearchAuthorHit`. `bookCount` is the wrapper's `books` array
/// length, kept as a plain count rather than exposing the embedded items.
public struct SearchSeriesHit: Sendable, Equatable {
  public let id: String
  public let name: String?
  public let bookCount: Int?

  public init(id: String, name: String?, bookCount: Int? = nil) {
    self.id = id
    self.name = name
    self.bookCount = bookCount
  }
}

/// Client-side rejection of an empty `q`, before it reaches the network (API-CONVENTIONS.md
/// rule 21).
public enum SearchError: Error, Sendable, Equatable {
  case emptyQuery
}

/// The server documents no maximum for this endpoint's `limit`, so this picks a conservative
/// ceiling, as `BatchGetBounds` does. The fallback of 25 leaves room for authors and series
/// alongside books and podcasts.
enum SearchBounds {
  static let maximum = 100
  static let fallback = 25
}

extension ABSClient {
  /// `GET /api/libraries/{id}/search?q=<term>&limit=<n>`: searches local library content only,
  /// distinct from the `/api/search/*` metadata-provider lookups.
  public func searchLibrary(
    account: TokenAccount,
    library libraryID: String,
    query: String,
    // Must match `SearchBounds.fallback`: a public default argument must be at least as
    // accessible as this function, so it can't reference the internal enum directly.
    limit: Int = 25,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> SearchResults {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else { throw SearchError.emptyQuery }

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/search",
      queryItems: [
        URLQueryItem(name: "q", value: trimmedQuery),
        URLQueryItem(name: "limit", value: String(boundedLimit(limit))),
      ],
      routeTemplate: "/api/libraries/:id/search"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      SearchResultsDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/search",
      diagnostics: diagnostics
    )
    // Zero-cost safety net: the `wire` buckets already exclude required-id failures via the
    // `requiredKey` filter.
    return SearchResults(
      bookHits: wire.book.compactMap(Self.makeHit),
      podcastHits: wire.podcast.compactMap(Self.makeHit),
      authorHits: wire.authors.compactMap(Self.makeAuthorHit),
      seriesHits: wire.series.compactMap(Self.makeSeriesHit)
    )
  }

  private static func makeHit(from dto: SearchHitDTO) -> SearchHit? {
    guard let id = dto.libraryItem.id else { return nil }
    return SearchHit(
      libraryItem: ItemDetail(dto: dto.libraryItem, id: id),
      matchKey: dto.matchKey,
      matchText: dto.matchText
    )
  }

  private static func makeAuthorHit(from dto: SearchAuthorHitDTO) -> SearchAuthorHit? {
    guard let id = dto.id else { return nil }
    return SearchAuthorHit(id: id, name: dto.name)
  }

  private static func makeSeriesHit(from dto: SearchSeriesHitDTO) -> SearchSeriesHit? {
    guard let id = dto.id else { return nil }
    return SearchSeriesHit(id: id, name: dto.name, bookCount: dto.bookCount)
  }

  private func boundedLimit(_ requested: Int) -> Int {
    guard requested > 0 else { return SearchBounds.fallback }
    return min(requested, SearchBounds.maximum)
  }
}

extension KeyedDecodingContainer {
  /// Missing and null arrays are optional server fields. A present non-array must still fail the
  /// enclosing endpoint's decode; `decodeLossyArray` keeps its per-element lossiness unchanged.
  func decodeLossyArrayIfPresent<Element: Decodable>(
    forKey key: Key,
    validating: (Element) -> Bool = { _ in true },
    requiredKey: String? = nil
  ) throws -> [Element] {
    guard contains(key), try decodeNil(forKey: key) == false else { return [] }
    return try decodeLossyArray(
      forKey: key, validating: validating, requiredKey: requiredKey)
  }
}

/// The search-response wire shape. Book libraries return a `book` key and podcast libraries
/// `podcast`, so either may be legitimately absent and falls back to `[]`. `authors`/`series`/
/// `tags` tolerate absent keys and `null` the same way; present wrong-typed buckets fail decoding.
private struct SearchResultsDTO: Decodable {
  let book: [SearchHitDTO]
  let podcast: [SearchHitDTO]
  let authors: [SearchAuthorHitDTO]
  let series: [SearchSeriesHitDTO]
  // Decoded for lenient-decode parity but not surfaced on `SearchResults`: tags aren't shown.
  let tags: [String]

  private enum CodingKeys: String, CodingKey { case book, podcast, authors, series, tags }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    book = try container.decodeLossyArrayIfPresent(
      forKey: .book, validating: { $0.libraryItem.id != nil }, requiredKey: "id")
    podcast = try container.decodeLossyArrayIfPresent(
      forKey: .podcast, validating: { $0.libraryItem.id != nil }, requiredKey: "id")
    authors = try container.decodeLossyArrayIfPresent(
      forKey: .authors, validating: { $0.id != nil }, requiredKey: "id")
    series = try container.decodeLossyArrayIfPresent(
      forKey: .series, validating: { $0.id != nil }, requiredKey: "id")
    tags = try container.decodeLossyArrayIfPresent(forKey: .tags)
  }
}

/// A single hit's wire shape. `libraryItem` is decoded directly (not `try?`): a structurally
/// malformed embedded item (non-object element) throws and is caught by `LossyArray`'s
/// structural-failure handling. A valid item whose `id` is missing, wrong-typed or oversized
/// decodes to `nil` and is caught by the `validating`/`requiredKey` post-filter.
private struct SearchHitDTO: Decodable {
  let libraryItem: ItemDetailDTO
  let matchKey: String?
  let matchText: String?

  private enum CodingKeys: String, CodingKey { case libraryItem, matchKey, matchText }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    libraryItem = try container.decode(ItemDetailDTO.self, forKey: .libraryItem)
    matchKey = try container.decodeBoundedString(forKey: .matchKey)
    matchText = try container.decodeBoundedString(forKey: .matchText)
  }
}

/// Wire shape for one `authors` bucket element: a bare `AuthorExpanded`-shaped object
/// (live-confirmed on 2.35.1; see `SearchResults`). `id` is a bounded identity: `.reject` + `try?`
/// makes an oversized value `nil` rather than a truncated key, and the `requiredKey` post-filter
/// then drops that hit (not the bucket). A wrong-typed `id` also decodes to `nil`.
private struct SearchAuthorHitDTO: Decodable {
  let id: String?
  let name: String?

  private enum CodingKeys: String, CodingKey { case id, name }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    name = try container.decodeBoundedString(forKey: .name)
  }
}

/// Wire shape for one `series` bucket element, which is wrapped (live-confirmed on 2.35.1; see
/// `SearchResults`): `{ "series": { "id", "name", "nameIgnorePrefix", ... }, "books": [...] }`.
/// `id`/`name` come from the nested `series` object; a missing, null, wrong-typed or oversized
/// one decodes both to `nil`, which the `requiredKey: "id"` post-filter drops (one hit, not the
/// bucket). `name` falls back to `series.nameIgnorePrefix`. `bookCount` is `books.count`, with
/// elements only checked as JSON objects (`BookPlaceholder`) since only the count is used.
private struct SearchSeriesHitDTO: Decodable {
  let id: String?
  let name: String?
  let bookCount: Int?

  private enum CodingKeys: String, CodingKey { case series, books }
  private enum SeriesCodingKeys: String, CodingKey { case id, name, nameIgnorePrefix }
  private struct BookPlaceholder: Decodable {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let seriesContainer = try? container.nestedContainer(
      keyedBy: SeriesCodingKeys.self, forKey: .series
    ) {
      id = try? seriesContainer.decodeBoundedString(forKey: .id, policy: .reject)
      name =
        try seriesContainer.decodeBoundedString(forKey: .name)
        ?? seriesContainer.decodeBoundedString(forKey: .nameIgnorePrefix)
    } else {
      id = nil
      name = nil
    }
    bookCount = ((try? container.decodeIfPresent([BookPlaceholder].self, forKey: .books)) ?? nil)?.count
  }
}
