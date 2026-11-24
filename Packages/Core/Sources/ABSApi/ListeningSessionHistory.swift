import Foundation

/// One entry from either listening-session history endpoint (API-CONVENTIONS.md rule 6a). Only
/// this path populates listening-time statistics. Live-confirmed to be closed-session history
/// only: the active session never appears, and zero-progress
/// spike sessions aren't persisted.
///
/// `GET /api/me/listening-sessions` has no per-item filter, so `SyncEngine` fetches the whole
/// history and filters by `libraryItemID`. `GET /api/me/item/listening-sessions/{libraryItemId}`
/// returns the same shape for one item, but only usefully for a book: with no episode id it scopes
/// to a podcast's own media id, which no episode session carries.
///
/// Distinct from `PlaybackSession` despite the same server shape: only the fields a per-item
/// history list needs are decoded.
public struct ListeningSessionHistoryEntry: Sendable, Equatable {
  public let id: String
  public let libraryItemID: String?
  public let episodeID: String?
  /// Playback position (seconds) when this session started.
  public let startTime: Double?
  /// Playback position (seconds) when this session was last updated/closed.
  public let currentTime: Double?
  /// Total seconds actually listened during this session (server-accumulated via repeated
  /// `/sync` deltas, rule 8). Not derivable from `startTime`/`currentTime`, since a session can
  /// pause or seek within itself.
  public let timeListening: Double?
  public let startedAt: Date?
  public let updatedAt: Date?

  public init(
    id: String,
    libraryItemID: String?,
    episodeID: String?,
    startTime: Double?,
    currentTime: Double?,
    timeListening: Double?,
    startedAt: Date?,
    updatedAt: Date?
  ) {
    self.id = id
    self.libraryItemID = libraryItemID
    self.episodeID = episodeID
    self.startTime = startTime
    self.currentTime = currentTime
    self.timeListening = timeListening
    self.startedAt = startedAt
    self.updatedAt = updatedAt
  }
}

/// One fetched page of `GET /api/me/listening-sessions`. `total` is the only pagination field
/// observed live. `page`/`itemsPerPage` echo the request and
/// are not live-confirmed, so callers should rely on their own requested values rather than the
/// server echoing them back.
public struct ListeningSessionHistoryPage: Sendable, Equatable {
  public let entries: [ListeningSessionHistoryEntry]
  public let total: Int
  public let page: Int
  public let itemsPerPage: Int

  public init(entries: [ListeningSessionHistoryEntry], total: Int, page: Int, itemsPerPage: Int) {
    self.entries = entries
    self.total = total
    self.page = page
    self.itemsPerPage = itemsPerPage
  }
}

/// Client-side page-size policy for `/api/me/listening-sessions`: never request an unbounded page
/// (API-CONVENTIONS.md rule 15). No server-side maximum is documented for this endpoint.
enum ListeningSessionHistoryBounds {
  static let maximum = 100
  static let fallback = 50
}

extension ABSClient {
  /// `GET /api/me/listening-sessions` (API-CONVENTIONS.md rule 6a). A page-fetch primitive with
  /// no traversal loop: the caller (`SyncEngine`) drives repeated calls and decides when to stop
  /// (per-item filtering and the pagination cap live there). `page` is 0-based.
  public func fetchListeningSessionHistory(
    account: TokenAccount,
    page: Int = 0,
    // Must match `ListeningSessionHistoryBounds.fallback`: a public default argument must be at
    // least as accessible as this function, so it can't reference the internal enum directly.
    itemsPerPage: Int = 50,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> ListeningSessionHistoryPage {
    let tokens = try loadTokens(for: account)
    let boundedItemsPerPage = min(max(itemsPerPage, 1), ListeningSessionHistoryBounds.maximum)
    let queryItems = [
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "itemsPerPage", value: String(boundedItemsPerPage)),
    ]
    let routeTemplate = "/api/me/listening-sessions"
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/me/listening-sessions",
      queryItems: queryItems,
      routeTemplate: routeTemplate
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      ListeningSessionHistoryPageDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    let entries = wire.sessions.compactMap { dto -> ListeningSessionHistoryEntry? in
      guard let id = dto.id else { return nil }
      return ListeningSessionHistoryEntry(
        id: id,
        libraryItemID: dto.libraryItemId,
        episodeID: dto.episodeId,
        startTime: dto.startTime,
        currentTime: dto.currentTime,
        timeListening: dto.timeListening,
        startedAt: dto.startedAt,
        updatedAt: dto.updatedAt
      )
    }
    return ListeningSessionHistoryPage(
      entries: entries, total: wire.total, page: page, itemsPerPage: boundedItemsPerPage)
  }

  /// `GET /api/me/item/listening-sessions/{libraryItemId}[/{episodeId}]`. A page-fetch primitive
  /// only; traversal remains the caller's responsibility, using the same bounds and short-page
  /// stop signal as the account-wide history endpoint.
  public func fetchItemListeningSessionHistory(
    account: TokenAccount,
    itemID: String,
    episodeID: String? = nil,
    page: Int = 0,
    itemsPerPage: Int = 50,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> ListeningSessionHistoryPage {
    let tokens = try loadTokens(for: account)
    let boundedItemsPerPage = min(max(itemsPerPage, 1), ListeningSessionHistoryBounds.maximum)
    let queryItems = [
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "itemsPerPage", value: String(boundedItemsPerPage)),
    ]
    let path: String
    let routeTemplate: String
    if let episodeID {
      path = "/api/me/item/listening-sessions/\(itemID)/\(episodeID)"
      routeTemplate = "/api/me/item/listening-sessions/:libraryItemId/:episodeId"
    } else {
      path = "/api/me/item/listening-sessions/\(itemID)"
      routeTemplate = "/api/me/item/listening-sessions/:libraryItemId"
    }
    let request = try requestBuilder.makeRequest(
      method: .get, path: path, queryItems: queryItems, routeTemplate: routeTemplate)
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      ListeningSessionHistoryPageDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    let entries = wire.sessions.compactMap { dto -> ListeningSessionHistoryEntry? in
      guard let id = dto.id else { return nil }
      return ListeningSessionHistoryEntry(
        id: id,
        libraryItemID: dto.libraryItemId,
        episodeID: dto.episodeId,
        startTime: dto.startTime,
        currentTime: dto.currentTime,
        timeListening: dto.timeListening,
        startedAt: dto.startedAt,
        updatedAt: dto.updatedAt
      )
    }
    return ListeningSessionHistoryPage(
      entries: entries, total: wire.total, page: page, itemsPerPage: boundedItemsPerPage)
  }
}

/// The `GET /api/me/listening-sessions` envelope. Only `total` was live-observed; the rest,
/// `{ sessions: [...], total, page, itemsPerPage }`, is assumed from the other wrapped-list
/// endpoints. A missing/null `sessions` degrades to `[]`, a wrong-typed array fails the page,
/// malformed elements are skipped, and a bad `total` degrades to `0` (rule 21). `SyncEngine` stops
/// paging on an empty page only when it decoded successfully.
private struct ListeningSessionHistoryPageDTO: Decodable {
  let sessions: [ListeningSessionHistoryEntryDTO]
  let total: Int

  private enum CodingKeys: String, CodingKey { case sessions, total }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessions = try container.decodeLossyArrayIfPresent(
      forKey: .sessions, validating: { $0.id != nil }, requiredKey: "id")
    total = try container.decode(LossyOptional<Int>.self, forKey: .total).wrappedValue ?? 0
  }
}

/// One `sessions[]` element of `GET /api/me/listening-sessions`: the server's
/// `PlaybackSession.toJSONForClient()` object, narrowed to the fields a history entry needs.
struct ListeningSessionHistoryEntryDTO: Decodable {
  let id: String?
  let libraryItemId: String?
  let episodeId: String?
  let startTime: Double?
  let currentTime: Double?
  let timeListening: Double?
  let startedAt: Date?
  let updatedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id, libraryItemId, episodeId, startTime, currentTime, timeListening, startedAt, updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `.reject` + `try?`: the session id is the persisted upsert identity, so an oversized value
    // must drop the element (via the `requiredKey` filter) rather than become a truncated key.
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    // The item match key selects which item's history this row belongs to. An oversized/wrong-typed
    // value decodes as nil, which cannot equal any non-nil item id, so `ListeningHistoryCoordinator`
    // skips the row rather than persisting it under another item: nil already is the drop effect.
    libraryItemId = try? container.decodeBoundedString(forKey: .libraryItemId, policy: .reject)
    episodeId = try container.decodeIfPresent(String.self, forKey: .episodeId)
    startTime = try container.decode(LossyOptional<Double>.self, forKey: .startTime).wrappedValue
    currentTime = try container.decode(LossyOptional<Double>.self, forKey: .currentTime).wrappedValue
    timeListening = try container.decode(LossyOptional<Double>.self, forKey: .timeListening).wrappedValue
    // Epoch-ms wire format, like every other Audiobookshelf timestamp.
    startedAt = try container.decodeEpochMillisDate(forKey: .startedAt)
    updatedAt = try container.decodeEpochMillisDate(forKey: .updatedAt)
  }
}
