import Foundation

/// `GET /api/libraries/{id}/authors` / `GET /api/libraries/{id}/series`: the two navigable-entity
/// listing routes, so an author/series search hit has somewhere to land. The single-entity routes
/// (`/api/authors/{id}`, `/api/series/{id}`) are not used here.
public struct LibraryAuthorSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String?
  public let numBooks: Int?

  public init(id: String, name: String?, numBooks: Int?) {
    self.id = id
    self.name = name
    self.numBooks = numBooks
  }
}

/// `{ "authors": [AuthorExpanded, ...] }`. Unlike `/items`/`/series`, no `total`/`limit`/`page`
/// envelope is documented for this route, so `hasMore` is a heuristic (the page came back full)
/// rather than a server-reported fact.
public struct LibraryAuthorsPage: Sendable, Equatable {
  public let authors: [LibraryAuthorSummary]
  public let hasMore: Bool

  public init(authors: [LibraryAuthorSummary], hasMore: Bool) {
    self.authors = authors
    self.hasMore = hasMore
  }
}

public struct LibrarySeriesSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String?

  public init(id: String, name: String?) {
    self.id = id
    self.name = name
  }
}

/// The lightweight author/series indexes returned by the documented library filter-data route.
/// This is the right browse source: unlike the separate entity-detail listings it is a complete,
/// non-paginated index intended for building library navigation and filter UIs.
public struct LibraryFilterData: Sendable, Equatable {
  public let authors: [LibraryAuthorSummary]
  public let series: [LibrarySeriesSummary]

  public init(authors: [LibraryAuthorSummary], series: [LibrarySeriesSummary]) {
    self.authors = authors
    self.series = series
  }
}

/// `{ results: [SeriesBooks...], total, limit, page, ... }`. Carries real pagination metadata,
/// unlike `LibraryAuthorsPage` above.
public struct LibrarySeriesPage: Sendable, Equatable {
  public let series: [LibrarySeriesSummary]
  public let total: Int
  public let limit: Int
  public let page: Int

  public init(series: [LibrarySeriesSummary], total: Int, limit: Int, page: Int) {
    self.series = series
    self.total = total
    self.limit = limit
    self.page = page
  }
}

/// No documented server-side maximum for either route (mirrors `SearchBounds`'s reasoning). Kept
/// smaller than `LibraryItemsBounds` (author/series counts are typically far below item counts)
/// while still inside rule 15's limit of roughly 50-100.
enum AuthorSeriesBounds {
  static let maximum = 100
  static let fallback = 50
}

extension ABSClient {
  /// `GET /api/libraries/{id}/filterdata`: the library's complete lightweight entity indexes.
  public func getLibraryFilterData(
    account: TokenAccount,
    library libraryID: String,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibraryFilterData {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/filterdata",
      routeTemplate: "/api/libraries/:id/filterdata"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      LibraryFilterDataDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/filterdata",
      diagnostics: diagnostics
    )
    return LibraryFilterData(
      authors: wire.authors.compactMap(Self.makeAuthorSummary),
      series: wire.series.compactMap(Self.makeSeriesSummary))
  }

  /// `GET /api/libraries/{id}/authors?limit=<n>&page=<p>`.
  public func listLibraryAuthors(
    account: TokenAccount,
    library libraryID: String,
    // Must match `AuthorSeriesBounds.fallback`, as in `listLibraryItems`.
    limit: Int = 50,
    page: Int = 0,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibraryAuthorsPage {
    let tokens = try loadTokens(for: account)
    let boundedLimit = boundedAuthorSeriesLimit(limit)

    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/authors",
      queryItems: [
        URLQueryItem(name: "limit", value: String(boundedLimit)),
        URLQueryItem(name: "page", value: String(page)),
      ],
      routeTemplate: "/api/libraries/:id/authors"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      LibraryAuthorsDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/authors",
      diagnostics: diagnostics
    )
    // Zero-cost safety net, as in LibraryEndpoints.swift/SearchEndpoint.swift: `wire.authors`
    // already excludes required-id failures via the `requiredKey` filter inside the DTO.
    let authors = wire.authors.compactMap(Self.makeAuthorSummary)
    return LibraryAuthorsPage(authors: authors, hasMore: authors.count >= boundedLimit)
  }

  /// `GET /api/libraries/{id}/series?limit=<n>&page=<p>`.
  public func listLibrarySeries(
    account: TokenAccount,
    library libraryID: String,
    limit: Int = 50,
    page: Int = 0,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibrarySeriesPage {
    let tokens = try loadTokens(for: account)
    let boundedLimit = boundedAuthorSeriesLimit(limit)

    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/series",
      queryItems: [
        URLQueryItem(name: "limit", value: String(boundedLimit)),
        URLQueryItem(name: "page", value: String(page)),
      ],
      routeTemplate: "/api/libraries/:id/series"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      LibrarySeriesListDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/series",
      diagnostics: diagnostics
    )
    let series = wire.results.compactMap(Self.makeSeriesSummary)
    return LibrarySeriesPage(series: series, total: wire.total, limit: wire.limit, page: wire.page)
  }

  private static func makeAuthorSummary(from dto: LibraryAuthorDTO) -> LibraryAuthorSummary? {
    guard let id = dto.id else { return nil }
    return LibraryAuthorSummary(id: id, name: dto.name, numBooks: dto.numBooks)
  }

  private static func makeSeriesSummary(from dto: LibrarySeriesDTO) -> LibrarySeriesSummary? {
    guard let id = dto.id else { return nil }
    return LibrarySeriesSummary(id: id, name: dto.name)
  }

  private func boundedAuthorSeriesLimit(_ requested: Int) -> Int {
    guard requested > 0 else { return AuthorSeriesBounds.fallback }
    return min(requested, AuthorSeriesBounds.maximum)
  }
}

private struct LibraryFilterDataDTO: Decodable {
  let authors: [LibraryAuthorDTO]
  let series: [LibrarySeriesDTO]

  private enum CodingKeys: String, CodingKey { case authors, series }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authors = try container.decodeLossyArrayIfPresent(
      forKey: .authors, validating: { $0.id != nil }, requiredKey: "id")
    series = try container.decodeLossyArrayIfPresent(
      forKey: .series, validating: { $0.id != nil }, requiredKey: "id")
  }
}

/// `{ "authors": [AuthorExpanded, ...] }`. No envelope pagination metadata is documented for this
/// route (contrast `LibrarySeriesListDTO` below); see `LibraryAuthorsPage`.
private struct LibraryAuthorsDTO: Decodable {
  let authors: [LibraryAuthorDTO]

  private enum CodingKeys: String, CodingKey { case authors }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    authors = try container.decodeLossyArrayIfPresent(
      forKey: .authors, validating: { $0.id != nil }, requiredKey: "id")
  }
}

/// One `AuthorExpanded` element. Only `id`/`name`/`numBooks` are modelled; the rest
/// (`asin`/`description`/`imagePath`/`addedAt`/`updatedAt`) isn't needed by the navigable-entity
/// row, as with `SearchAuthorHitDTO`.
private struct LibraryAuthorDTO: Decodable {
  let id: String?
  let name: String?
  let numBooks: Int?

  private enum CodingKeys: String, CodingKey { case id, name, numBooks }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    name = try container.decodeBoundedString(forKey: .name)
    numBooks = try container.decode(LossyOptional<Int>.self, forKey: .numBooks).wrappedValue
  }
}

/// `{ results: [SeriesBooks...], total, limit, page, ... }` (research/audiobookshelf-api.md line
/// 171), the same page envelope shape as `LibraryItemsPageDTO`.
private struct LibrarySeriesListDTO: Decodable {
  let results: [LibrarySeriesDTO]
  let total: Int
  let limit: Int
  let page: Int

  private enum CodingKeys: String, CodingKey { case results, total, limit, page }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    results = try container.decodeLossyArray(
      forKey: .results,
      validating: { $0.id != nil },
      requiredKey: "id"
    )
    total = try container.decode(Int.self, forKey: .total)
    limit = try container.decode(Int.self, forKey: .limit)
    page = try container.decode(Int.self, forKey: .page)
  }
}

/// One `SeriesBooks` element. Only `id`/`name` are modelled; `books[]`/`nameIgnorePrefix*`/`type`/
/// `addedAt`/`totalDuration` aren't needed by the navigable-entity row. The entity's own items
/// come from the paginated `/items?filter=series.<id>` route (LibraryEndpoints.swift), not from
/// this listing's embedded `books[]`.
private struct LibrarySeriesDTO: Decodable {
  let id: String?
  let name: String?

  private enum CodingKeys: String, CodingKey { case id, name }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    name = try container.decodeBoundedString(forKey: .name)
  }
}
