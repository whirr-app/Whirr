import Foundation

/// Clean public value type for a `MediaProgress` row.
///
/// Carries the wire `id` forward as `serverProgressID`: a reset deletes the row by that id, and
/// its loss on a later snapshot is the reset evidence (ADR 0011). `userId` is never decoded.
/// API-CONVENTIONS rule 11 is write-side: an `id` in a progress payload corrupts the server's
/// primary key (issue #5188). `ProgressUpdate`/`ProgressBatchEntry`'s exhaustive `CodingKeys` have
/// no `id` case, so knowing the id here cannot leak it into a PATCH.
public struct MediaProgress: Sendable, Equatable {
  public let libraryItemID: String
  public let episodeID: String?
  public let mediaItemID: String?
  public let mediaItemType: String?
  public let duration: Double?
  public let progress: Double?
  public let currentTime: Double?
  public let isFinished: Bool
  public let hideFromContinueListening: Bool
  public let ebookLocation: String?
  public let ebookProgress: Double?
  public let lastUpdate: Date?
  public let startedAt: Date?
  public let finishedAt: Date?
  /// The wire `id` of this progress row, bounded like any other decoded string. `nil` when the
  /// server omitted it or it exceeded the configured bound. An oversized value is never
  /// truncated, because a truncated identity would address a different row on a later `DELETE`.
  public let serverProgressID: String?

  public init(
    libraryItemID: String,
    episodeID: String?,
    mediaItemID: String?,
    mediaItemType: String?,
    duration: Double?,
    progress: Double?,
    currentTime: Double?,
    isFinished: Bool,
    hideFromContinueListening: Bool,
    ebookLocation: String?,
    ebookProgress: Double?,
    lastUpdate: Date?,
    startedAt: Date?,
    finishedAt: Date?,
    serverProgressID: String? = nil
  ) {
    self.libraryItemID = libraryItemID
    self.episodeID = episodeID
    self.mediaItemID = mediaItemID
    self.mediaItemType = mediaItemType
    self.duration = duration
    self.progress = progress
    self.currentTime = currentTime
    self.isFinished = isFinished
    self.hideFromContinueListening = hideFromContinueListening
    self.ebookLocation = ebookLocation
    self.ebookProgress = ebookProgress
    self.lastUpdate = lastUpdate
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.serverProgressID = serverProgressID
  }

  init(dto: MediaProgressDTO, libraryItemID: String) {
    self.init(
      libraryItemID: libraryItemID,
      episodeID: dto.episodeId,
      mediaItemID: dto.mediaItemId,
      mediaItemType: dto.mediaItemType,
      duration: dto.duration,
      progress: dto.progress,
      currentTime: dto.currentTime,
      isFinished: dto.isFinished,
      hideFromContinueListening: dto.hideFromContinueListening,
      ebookLocation: dto.ebookLocation,
      ebookProgress: dto.ebookProgress,
      lastUpdate: dto.lastUpdate,
      startedAt: dto.startedAt,
      finishedAt: dto.finishedAt,
      serverProgressID: dto.id
    )
  }
}

/// The account-wide progress, Continue Series visibility and bookmark snapshot returned by one
/// `GET /api/me`.
public struct UserProgressSnapshot: Sendable, Equatable {
  public let progress: [MediaProgress]
  public let hiddenSeriesIDs: [String]
  /// `false` when any `mediaProgress` element was dropped (malformed, or missing `libraryItemId`).
  /// A reset may be inferred from a row's absence only on a complete snapshot: a partial one
  /// cannot tell "deleted" from "failed to decode".
  public let isComplete: Bool
  /// The user's audio bookmarks across every item, from the same `/api/me` response.
  public let bookmarks: [ServerAudioBookmark]
  /// `true` only when the response carried a `bookmarks` array and no element was dropped. A
  /// snapshot built anywhere other than a successful `/api/me` decode defaults to `false`, so it
  /// can never be evidence that a bookmark was deleted.
  public let bookmarksAreComplete: Bool

  public init(
    progress: [MediaProgress],
    hiddenSeriesIDs: [String],
    isComplete: Bool = true,
    bookmarks: [ServerAudioBookmark] = [],
    bookmarksAreComplete: Bool = false
  ) {
    self.progress = progress
    self.hiddenSeriesIDs = hiddenSeriesIDs
    self.isComplete = isComplete
    self.bookmarks = bookmarks
    self.bookmarksAreComplete = bookmarksAreComplete
  }
}

/// The bounded identity/profile slice of the user object returned by `GET /api/me`.
/// Only the two mutation permissions (update, delete) cross this boundary. Every other permission
/// stays below ABSApi's clean-value boundary, however many the server sends.
public struct UserProfile: Sendable, Equatable {
  public let id: String
  public let username: String?
  public let type: String?
  public let isActive: Bool?
  public let isLocked: Bool?
  public let librariesAccessible: [String]
  public let hiddenSeriesIDs: [String]
  /// Optional because older/trimmed servers and malformed profiles may omit it. Capability
  /// derivation must treat `nil` as unknown/false rather than as permission granted.
  public let permissionsUpdate: Bool?
  /// Optional because older/trimmed servers and malformed profiles may omit it. Capability
  /// derivation must treat `nil` as unknown/false rather than as permission granted.
  public let permissionsDelete: Bool?

  public init(
    id: String,
    username: String?,
    type: String?,
    isActive: Bool?,
    isLocked: Bool?,
    librariesAccessible: [String],
    hiddenSeriesIDs: [String] = [],
    permissionsUpdate: Bool? = nil,
    permissionsDelete: Bool? = nil
  ) {
    self.id = id
    self.username = username
    self.type = type
    self.isActive = isActive
    self.isLocked = isLocked
    self.librariesAccessible = librariesAccessible
    self.hiddenSeriesIDs = hiddenSeriesIDs
    self.permissionsUpdate = permissionsUpdate
    self.permissionsDelete = permissionsDelete
  }
}

extension ABSClient {
  /// `GET /api/me`: returns the full user object, of which only the progress rows and the
  /// account-wide hidden Continue Series ids matter here. Reads only. Rows missing the required
  /// `libraryItemId` are skipped (the `decodeLossyArray` required-key pattern).
  public func fetchUserMediaProgress(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [MediaProgress] {
    let snapshot = try await fetchUserProgressSnapshot(account: account, diagnostics: diagnostics)
    return snapshot.progress
  }

  /// `GET /api/me`: fetches the progress rows and the server's account-wide hidden Continue Series
  /// ids from the same response, so a refresh does not need another request.
  public func fetchUserProgressSnapshot(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> UserProgressSnapshot {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/me",
      routeTemplate: "/api/me"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      UserMediaProgressResponseDTO.self,
      from: response.body,
      endpoint: "/api/me",
      diagnostics: diagnostics
    )
    // Safety net: `wire.mediaProgresses` already excludes required-identity failures via the
    // `requiredKey` filter.
    let progress = wire.mediaProgresses.compactMap { dto -> MediaProgress? in
      guard let libraryItemID = dto.libraryItemId else { return nil }
      return MediaProgress(dto: dto, libraryItemID: libraryItemID)
    }
    return UserProgressSnapshot(
      progress: progress, hiddenSeriesIDs: wire.hiddenSeriesIDs, isComplete: wire.isComplete,
      bookmarks: wire.bookmarks.compactMap(\.bookmark),
      bookmarksAreComplete: wire.bookmarksAreComplete)
  }

  /// `GET /api/me`: the same full user route as `fetchUserMediaProgress`, narrowed to the bounded
  /// profile fields needed by setup and the account surface. The API-token overload is internal
  /// because it is the pre-persistence validation seam used by `ABSClient.login`.
  public func fetchUserProfile(account: TokenAccount) async throws -> UserProfile {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/me",
      routeTemplate: "/api/me"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)
    return try decodeUserProfile(from: response.body)
  }

  /// An explicit bearer profile request used for API-token validation and candidate endpoint
  /// probing. It never creates or uses an authenticated client, so it cannot refresh or latch a
  /// cached credential pair.
  public func fetchUserProfile(bearerToken: String) async throws -> UserProfile {
    guard bearerToken.isEmpty == false else { throw APIError.unauthorized }
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/me",
      bearerToken: bearerToken,
      routeTemplate: "/api/me"
    )
    let response = try await send(request)
    try validateSuccess(response)
    return try decodeUserProfile(from: response.body)
  }

  private func decodeUserProfile(from body: Data) throws -> UserProfile {
    let wire = try decoder.decode(UserProfileDTO.self, from: body, endpoint: "/api/me")
    return try wire.profile()
  }

}

private struct UserProfileDTO: Decodable {
  let id: String?
  let username: String?
  let type: String?
  let isActive: Bool?
  let isLocked: Bool?
  let librariesAccessible: [String]
  let hiddenSeriesIDs: [String]
  let permissionsUpdate: Bool?
  let permissionsDelete: Bool?

  private enum CodingKeys: String, CodingKey {
    case id, username, type, isActive, isLocked, librariesAccessible,
      seriesHideFromContinueListening, permissions
  }
  private enum PermissionsCodingKeys: String, CodingKey { case update, delete }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeBoundedString(forKey: .id, policy: .reject)
    username = try container.decodeBoundedString(forKey: .username)
    type = try container.decodeBoundedString(forKey: .type)
    isActive = try container.decode(LossyOptional<Bool>.self, forKey: .isActive).wrappedValue
    isLocked = try container.decode(LossyOptional<Bool>.self, forKey: .isLocked).wrappedValue
    if let permissions = try? container.nestedContainer(
      keyedBy: PermissionsCodingKeys.self, forKey: .permissions
    ) {
      permissionsUpdate = try permissions.decode(LossyOptional<Bool>.self, forKey: .update).wrappedValue
      permissionsDelete = try permissions.decode(LossyOptional<Bool>.self, forKey: .delete).wrappedValue
    } else {
      permissionsUpdate = nil
      permissionsDelete = nil
    }

    let accessible: [BoundedStringArrayElementDTO] = try container.decodeLossyArrayIfPresent(
      forKey: .librariesAccessible,
      validating: { $0.value?.isEmpty == false },
      requiredKey: "librariesAccessible"
    )
    librariesAccessible = accessible.compactMap(\.value)
    let hidden: [BoundedStringArrayElementDTO] =
      (try? container.decodeLossyArrayIfPresent(
        forKey: .seriesHideFromContinueListening,
        validating: { $0.value?.isEmpty == false },
        requiredKey: "seriesHideFromContinueListening"
      )) ?? []
    hiddenSeriesIDs = hidden.compactMap(\.value)
  }

  func profile() throws -> UserProfile {
    guard let id, id.isEmpty == false else { throw APIError.decoding }
    return UserProfile(
      id: id,
      username: username,
      type: type,
      isActive: isActive,
      isLocked: isLocked,
      librariesAccessible: librariesAccessible,
      hiddenSeriesIDs: hiddenSeriesIDs,
      permissionsUpdate: permissionsUpdate,
      permissionsDelete: permissionsDelete
    )
  }
}

/// A scalar array element with the same configured string bound as the other list fields. A
/// malformed element is discarded by `decodeLossyArrayIfPresent`; an oversized identity is also
/// discarded rather than truncated into a different library id.
private struct BoundedStringArrayElementDTO: Decodable {
  let value: String?

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let raw = try? container.decode(String.self) else {
      value = nil
      return
    }
    let limit = BoundedDecoderContext.maximumListStringBytes(from: decoder)
    guard raw.utf8.count <= limit else {
      value = nil
      return
    }
    value = raw
  }
}

private struct UserMediaProgressResponseDTO: Decodable {
  let mediaProgresses: [MediaProgressDTO]
  let hiddenSeriesIDs: [String]
  /// `true` unless `decodeLossyArrayCountingDropped` dropped at least one `mediaProgress` element,
  /// whether for failing to decode structurally or for missing the required `libraryItemId`
  /// identity below. See `UserProgressSnapshot.isComplete`.
  let isComplete: Bool
  let bookmarks: [AudioBookmarkDTO]
  /// `true` only when `bookmarks` was present as an array and nothing in it was dropped. An absent
  /// or malformed key reads as an empty, incomplete list: it is not evidence of deletion.
  let bookmarksAreComplete: Bool

  /// A real `GET /api/me` carries the array under `mediaProgress` (singular); an absent key makes
  /// `superDecoder(forKey:)` throw `keyNotFound`, which `BoundedDecoder` maps to
  /// `APIError.decoding`. The plural is also accepted, as fixtures and harnesses send it. A
  /// response with neither is not a user object and throws, as `fetchItemDetail` does for a
  /// missing id (ARCHITECTURE.md §7).
  private enum CodingKeys: String, CodingKey {
    case mediaProgress, mediaProgresses, seriesHideFromContinueListening, bookmarks
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let key: CodingKeys = container.contains(.mediaProgress) ? .mediaProgress : .mediaProgresses
    let decodedProgress = try container.decodeLossyArrayCountingDropped(
      forKey: key,
      validating: { (dto: MediaProgressDTO) in dto.libraryItemId != nil },
      requiredKey: "libraryItemId"
    )
    mediaProgresses = decodedProgress.elements
    isComplete = decodedProgress.droppedCount == 0
    let hidden: [BoundedStringArrayElementDTO] =
      (try? container.decodeLossyArrayIfPresent(
        forKey: .seriesHideFromContinueListening,
        validating: { $0.value?.isEmpty == false },
        requiredKey: "seriesHideFromContinueListening"
      )) ?? []
    hiddenSeriesIDs = hidden.compactMap(\.value)
    if container.contains(.bookmarks),
      let decodedBookmarks = try? container.decodeLossyArrayCountingDropped(
        forKey: .bookmarks,
        validating: { (dto: AudioBookmarkDTO) in dto.isUsable },
        requiredKey: "bookmarks"
      )
    {
      bookmarks = decodedBookmarks.elements
      bookmarksAreComplete = decodedBookmarks.droppedCount == 0
    } else {
      bookmarks = []
      bookmarksAreComplete = false
    }
  }
}

/// The `MediaProgress` wire shape. Internal (not `private`) because the dedicated
/// `fetchUserMediaProgress` endpoint uses it too, with the same lenient/bounded decoding rules.
///
/// `libraryItemId` is the required identity (rows missing it are skipped upstream). `id` is a
/// bounded string: the row's server primary key and the reset's `DELETE` target and evidence. It
/// must never round-trip into a PATCH body (`ProgressUpdate`/`ProgressBatchEntry`'s exhaustive
/// `CodingKeys`). `userId` is never decoded; every other field is lossy-optional. Ranged numerics
/// (`progress`/`ebookProgress` in 0...1, `duration`/`currentTime` non-negative) become `nil` when
/// impossible rather than clamped, so a garbled value never looks plausible.
struct MediaProgressDTO: Decodable {
  let id: String?
  let libraryItemId: String?
  let episodeId: String?
  let mediaItemId: String?
  let mediaItemType: String?
  let duration: Double?
  let progress: Double?
  let currentTime: Double?
  let isFinished: Bool
  let hideFromContinueListening: Bool
  let ebookLocation: String?
  let ebookProgress: Double?
  let lastUpdate: Date?
  let startedAt: Date?
  let finishedAt: Date?

  private enum CodingKeys: String, CodingKey {
    case id, libraryItemId, episodeId, mediaItemId, mediaItemType, duration, progress, currentTime,
      isFinished, hideFromContinueListening, ebookLocation, ebookProgress, lastUpdate, startedAt,
      finishedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `.reject` + `try?`, not `.truncate`: a truncated identity would address a different row on
    // a later `DELETE` or match the wrong progress row, so an oversized identity decodes as `nil`
    // (unlike `ebookLocation` below). `libraryItemId` then falls out through the endpoint's
    // `requiredKey` filter.
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    libraryItemId = try? container.decodeBoundedString(forKey: .libraryItemId, policy: .reject)
    // Unlike `libraryItemId`, a nil episode/media id is meaningful: it marks item-level progress
    // and participates in duplicate-row matching. A present but rejected value must therefore
    // drop the element, not turn episode progress into item progress.
    episodeId = try container.decodeOptionalIdentity(forKey: .episodeId)
    mediaItemId = try container.decodeOptionalIdentity(forKey: .mediaItemId)
    mediaItemType = try container.decodeIfPresent(String.self, forKey: .mediaItemType)
    duration = Self.sanitizeNonNegative(
      try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    )
    progress = Self.sanitizeUnitInterval(
      try container.decode(LossyOptional<Double>.self, forKey: .progress).wrappedValue
    )
    currentTime = Self.sanitizeNonNegative(
      try container.decode(LossyOptional<Double>.self, forKey: .currentTime).wrappedValue
    )
    isFinished = try container.decode(LossyOptional<Bool>.self, forKey: .isFinished).wrappedValue ?? false
    hideFromContinueListening =
      try container.decode(LossyOptional<Bool>.self, forKey: .hideFromContinueListening).wrappedValue ?? false
    ebookLocation = try container.decodeBoundedString(forKey: .ebookLocation)
    ebookProgress = Self.sanitizeUnitInterval(
      try container.decode(LossyOptional<Double>.self, forKey: .ebookProgress).wrappedValue
    )
    lastUpdate = try container.decodeEpochMillisDate(forKey: .lastUpdate)
    startedAt = try container.decodeEpochMillisDate(forKey: .startedAt)
    finishedAt = try container.decodeEpochMillisDate(forKey: .finishedAt)
  }

  private static func sanitizeNonNegative(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  private static func sanitizeUnitInterval(_ value: Double?) -> Double? {
    guard let value, value.isFinite, (0...1).contains(value) else { return nil }
    return value
  }
}
