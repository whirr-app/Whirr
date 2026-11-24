import Foundation

/// "Intended fields only" progress payload. Every property is `Optional` and the synthesised
/// `Encodable` uses `encodeIfPresent`, so an unset field is absent from the JSON, not `null`:
/// `isFinished: false` (an explicit reset) must reach the server, an untouched field must not
/// overwrite what is there.
///
/// Not modelled: `lastUpdate` (a raw-SQL timestamp override the API says to avoid casual use of),
/// `finishedAt`, `markAsFinishedTimeRemaining` and `markAsFinishedPercentComplete`.
///
/// `CodingKeys` is the forbidden-`id` defence (API-CONVENTIONS rule 11, issue #5188): a fixed,
/// exhaustive enum with no `id` case. `ProgressPatchTests` pins `CodingKeys.allCases`, so adding
/// `case id` fails before any payload is encoded.
public struct ProgressUpdate: Encodable, Sendable, Equatable {
  public var currentTime: Double?
  public var progress: Double?
  public var isFinished: Bool?
  public var ebookProgress: Double?
  public var ebookLocation: String?
  public var hideFromContinueListening: Bool?
  public var duration: Double?

  public init(
    currentTime: Double? = nil,
    progress: Double? = nil,
    isFinished: Bool? = nil,
    ebookProgress: Double? = nil,
    ebookLocation: String? = nil,
    hideFromContinueListening: Bool? = nil,
    duration: Double? = nil
  ) {
    self.currentTime = currentTime
    self.progress = progress
    self.isFinished = isFinished
    self.ebookProgress = ebookProgress
    self.ebookLocation = ebookLocation
    self.hideFromContinueListening = hideFromContinueListening
    self.duration = duration
  }

  public enum CodingKeys: String, CodingKey, CaseIterable {
    case currentTime, progress, isFinished, ebookProgress, ebookLocation, hideFromContinueListening, duration
  }
}

/// One row of a `PATCH /api/me/progress/batch/update` array. Each row carries its own
/// `libraryItemId`/`episodeId` since the route has no path param. The server's primary key `id`
/// is excluded, as in `ProgressUpdate`.
///
/// `encode(to:)` requests two keyed containers from one `Encoder` (this type's `CodingKeys`, then
/// `ProgressUpdate.CodingKeys`), which `JSONEncoder` merges into one flat object.
public struct ProgressBatchEntry: Encodable, Sendable, Equatable {
  public var libraryItemID: String
  public var episodeID: String?
  public var update: ProgressUpdate

  public init(libraryItemID: String, episodeID: String? = nil, update: ProgressUpdate) {
    self.libraryItemID = libraryItemID
    self.episodeID = episodeID
    self.update = update
  }

  public enum CodingKeys: String, CodingKey, CaseIterable {
    case libraryItemId, episodeId
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(libraryItemID, forKey: .libraryItemId)
    try container.encodeIfPresent(episodeID, forKey: .episodeId)
    try update.encode(to: encoder)
  }
}

/// The server documents no maximum for `/api/me/progress/batch/update`, so this reuses the
/// paginated-list bound as a conservative ceiling, as `BatchGetBounds` does.
enum ProgressBatchBounds {
  static let maximum = 100
}

/// Input over the bound is rejected rather than truncated, since truncating would silently drop
/// rows the caller expects to be synced.
public enum ProgressPatchError: Error, Sendable, Equatable {
  case tooManyEntries(requested: Int, maximum: Int)
}

extension ABSClient {
  /// `PATCH /api/me/progress/{libraryItemId}[/{episodeId}]`: one-shot state change with no
  /// playback. No listening-time stats are recorded (that is the session flow,
  /// `startPlaybackSession`/`syncPlaybackSession`).
  ///
  /// `episodeID` has no default: a defaulted `nil` would downgrade an episode-scoped update to the
  /// show's item-level route, writing a bogus show-level progress row.
  public func updateProgress(
    account: TokenAccount,
    libraryItemID: String,
    episodeID: String?,
    update: ProgressUpdate
  ) async throws {
    let tokens = try loadTokens(for: account)
    let path: String
    let routeTemplate: String
    if let episodeID {
      path = "/api/me/progress/\(libraryItemID)/\(episodeID)"
      routeTemplate = "/api/me/progress/:id/:episodeId"
    } else {
      path = "/api/me/progress/\(libraryItemID)"
      routeTemplate = "/api/me/progress/:id"
    }
    let request = try requestBuilder.makeJSONRequest(
      method: .patch,
      path: path,
      body: update,
      routeTemplate: routeTemplate,
      transportClass: .progressSync,
      outputFormatting: [.sortedKeys]
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }

  /// `PATCH /api/me/progress/batch/update`: sends several one-shot progress updates in one call
  /// instead of N sequential `updateProgress` PATCHes. Empty input returns without a network
  /// round-trip, as `batchGetItems` does.
  public func updateProgressBatch(
    account: TokenAccount,
    entries: [ProgressBatchEntry]
  ) async throws {
    guard entries.isEmpty == false else { return }
    guard entries.count <= ProgressBatchBounds.maximum else {
      throw ProgressPatchError.tooManyEntries(requested: entries.count, maximum: ProgressBatchBounds.maximum)
    }

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .patch,
      path: "/api/me/progress/batch/update",
      body: entries,
      routeTemplate: "/api/me/progress/batch/update",
      transportClass: .progressSync
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }

}
