import Foundation

/// A complete offline/local playback session, posted as one whole object. Unlike the live `/sync`
/// delta, `timeListening` is the total time listened during that local session, not an increment.
///
/// `id` is a stable UUID the caller supplies (SyncEngine generates and persists it); this layer
/// round-trips it unchanged through the request body and `LocalSessionSyncOutcome`. Never issue
/// two overlapping local-sync requests for one session id (server issue #2662); the caller
/// serialises, not this type.
public struct LocalPlaybackSession: Sendable, Equatable {
  public let id: String
  public let libraryItemID: String
  public let episodeID: String?
  public let mediaType: String?
  public let duration: Double?
  /// The book-timeline position this local session began at. The server computes this only on the
  /// online `/play` path; for a local session it takes whatever the payload carries, so omitting
  /// it leaves the persisted `startTime` null. `GET /api/me/listening-sessions` reports that back
  /// and the History tab renders it as "Started at 00:00".
  public let startTime: Double?
  public let currentTime: Double
  public let timeListening: Double
  public let startedAt: Date
  public let updatedAt: Date

  public init(
    id: String,
    libraryItemID: String,
    episodeID: String? = nil,
    mediaType: String? = nil,
    duration: Double? = nil,
    startTime: Double? = nil,
    currentTime: Double,
    timeListening: Double,
    startedAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.libraryItemID = libraryItemID
    self.episodeID = episodeID
    self.mediaType = mediaType
    self.duration = duration
    self.startTime = startTime
    self.currentTime = currentTime
    self.timeListening = timeListening
    self.startedAt = startedAt
    self.updatedAt = updatedAt
  }
}

extension LocalPlaybackSession: Encodable {
  private enum CodingKeys: String, CodingKey {
    case id, libraryItemId, episodeId, mediaType, duration, startTime, currentTime, timeListening, startedAt,
      updatedAt
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(libraryItemID, forKey: .libraryItemId)
    try container.encodeIfPresent(episodeID, forKey: .episodeId)
    try container.encodeIfPresent(mediaType, forKey: .mediaType)
    try container.encodeIfPresent(duration, forKey: .duration)
    // Omitted rather than sent as `0` when there is no start position: a zero would look like a
    // genuine start at the beginning of the book.
    try container.encodeIfPresent(startTime, forKey: .startTime)
    try container.encode(currentTime, forKey: .currentTime)
    try container.encode(timeListening, forKey: .timeListening)
    // Epoch-ms wire format, like every other Audiobookshelf timestamp in this module.
    try container.encode(startedAt.timeIntervalSince1970 * 1000, forKey: .startedAt)
    try container.encode(updatedAt.timeIntervalSince1970 * 1000, forKey: .updatedAt)
  }
}

/// The outcome of `POST /api/session/local-all` (one result per input session). A session id lands
/// in `acknowledged` only if it appears in the results array exactly once with an explicit
/// `success: true`. An empty results array, a missing id, a duplicated id, or a row whose
/// `success` is absent, null or the wrong type all leave that id in `unacknowledged`. A durable
/// outbox deletes only what is acknowledged.
public struct LocalSessionSyncOutcome: Sendable, Equatable {
  public let acknowledged: Set<String>
  public let unacknowledged: Set<String>

  public init(acknowledged: Set<String>, unacknowledged: Set<String>) {
    self.acknowledged = acknowledged
    self.unacknowledged = unacknowledged
  }
}

/// The server documents no maximum for `/api/session/local-all`. Local sessions are full session
/// objects, heavier than the ids `BatchGetBounds`/`ProgressBatchBounds` bound, and smaller, more
/// frequent batches are safer (server issue #2662), so this is half the id-only bound.
enum LocalSessionSyncBounds {
  static let maximum = 50
}

/// Input over the bound is rejected rather than silently truncated, as in
/// `BatchGetError`/`ProgressPatchError`.
public enum LocalSessionSyncError: Error, Sendable, Equatable {
  case tooManySessions(requested: Int, maximum: Int)
}

extension ABSClient {
  /// `POST /api/session/local-all` (API-CONVENTIONS rule 10): reconciles multiple offline-recorded
  /// sessions in one bounded call, never individual calls. Empty input returns an empty outcome
  /// without a network round-trip, like `batchGetItems`/`updateProgressBatch`.
  public func syncLocalSessions(
    account: TokenAccount,
    sessions: [LocalPlaybackSession],
    deviceInfo: [String: String?]? = nil,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LocalSessionSyncOutcome {
    guard sessions.isEmpty == false else {
      return LocalSessionSyncOutcome(acknowledged: [], unacknowledged: [])
    }
    guard sessions.count <= LocalSessionSyncBounds.maximum else {
      throw LocalSessionSyncError.tooManySessions(
        requested: sessions.count,
        maximum: LocalSessionSyncBounds.maximum
      )
    }

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/api/session/local-all",
      body: LocalSessionSyncAllPayload(sessions: sessions, deviceInfo: deviceInfo),
      routeTemplate: "/api/session/local-all",
      transportClass: .progressSync
    )
    let response: HTTPResponse
    do {
      response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    } catch let error as APIError where error == .payloadTooLarge {
      // The transport rejected an oversized 2xx response before a decoder could inspect it.
      throw APIError.ambiguousLocalSessionResponse
    }
    try validateSuccess(response)

    let wire: LocalSessionSyncResponseDTO
    do {
      wire = try decoder.decode(
        LocalSessionSyncResponseDTO.self,
        from: response.body,
        endpoint: "/api/session/local-all",
        diagnostics: diagnostics
      )
    } catch {
      // A top-level response we cannot interpret says nothing about any submitted session. Keep
      // the whole batch queued so a later pass can retry it; HTTP 413 was already handled above.
      throw APIError.ambiguousLocalSessionResponse
    }

    // Group decoded result rows by id (rows without an id are already excluded by
    // `decodeLossyArray`'s `requiredKey` filter). A session is acknowledged only if it has exactly
    // one matching row whose `success` is explicitly `true`. Empty, missing, duplicate and
    // unmarked cases all fall out of that one rule.
    let rowsByID = Dictionary(grouping: wire.results, by: \.id)
    var acknowledged: Set<String> = []
    var unacknowledged: Set<String> = []
    for session in sessions {
      let rows = rowsByID[session.id] ?? []
      if rows.count == 1, rows[0].success == true {
        acknowledged.insert(session.id)
      } else {
        unacknowledged.insert(session.id)
      }
    }
    return LocalSessionSyncOutcome(acknowledged: acknowledged, unacknowledged: unacknowledged)
  }
}

private struct LocalSessionSyncAllPayload: Encodable, Sendable {
  let sessions: [LocalPlaybackSession]
  let deviceInfo: [String: String?]?
}

private struct LocalSessionSyncResponseDTO: Decodable {
  let results: [LocalSessionSyncResultDTO]

  private enum CodingKeys: String, CodingKey { case results }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // A row that fails to parse is dropped rather than throwing, which would lose the whole batch
    // outcome. A dropped row is simply unacknowledged.
    results = try container.decodeLossyArray(
      forKey: .results,
      validating: { $0.id != nil },
      requiredKey: "id"
    )
  }
}

/// One row of `POST /api/session/local-all`'s response. `success` is a lossy-optional `Bool?`, not
/// a defaulted `Bool`, so a missing, null or wrong-type marker stays distinguishable from an
/// explicit `false`. Both leave the session unacknowledged.
struct LocalSessionSyncResultDTO: Decodable {
  let id: String?
  let success: Bool?

  private enum CodingKeys: String, CodingKey { case id, success, error, progressSynced }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    success = try container.decode(LossyOptional<Bool>.self, forKey: .success).wrappedValue
  }
}
