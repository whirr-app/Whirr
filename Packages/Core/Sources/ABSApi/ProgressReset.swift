import Foundation

/// The outcome of `deleteMediaProgress`. A row already gone (an earlier `DELETE` succeeded but its
/// acknowledgement was lost, or another device deleted it first) is a successful reset, not an
/// error: the drainer's crash-recovery replay must be able to run the same `DELETE` twice.
public enum MediaProgressDeletion: Sendable, Equatable {
  case deleted
  case alreadyGone
}

extension ABSClient {
  /// `GET /api/me/progress/{libraryItemId}[/{episodeId}]`. A `404` (no row for the identity) is the
  /// outbox drainer's "nothing to reset" signal and maps to `nil`, as `fetchPlaybackSession` does
  /// for a closed session. Every other non-2xx status throws.
  ///
  /// `episodeID` has no default, as with `updateProgress`: a defaulted `nil` would downgrade an
  /// episode-scoped fetch to the show's item-level route.
  ///
  /// A `200` body omitting `libraryItemId` falls back to the requested `libraryItemID` (the drainer
  /// knows it from its outbox entry). A structurally undecodable body throws `.decoding`.
  public func fetchMediaProgress(
    account: TokenAccount,
    libraryItemID: String,
    episodeID: String?,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> MediaProgress? {
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
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: path,
      routeTemplate: routeTemplate,
      transportClass: .progressSync
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    guard response.statusCode != 404 else { return nil }
    try validateSuccess(response)

    let wire = try decoder.decode(
      MediaProgressDTO.self,
      from: response.body,
      endpoint: routeTemplate,
      diagnostics: diagnostics
    )
    let resolvedLibraryItemID = wire.libraryItemId ?? libraryItemID
    return MediaProgress(dto: wire, libraryItemID: resolvedLibraryItemID)
  }

  /// `DELETE /api/me/progress/{progressId}`. The server's `:id` here is the progress row id
  /// (`MediaProgress.serverProgressID`), never the `libraryItemId` the PATCH route takes.
  ///
  /// A `404` maps to `.alreadyGone`, so a replay after a crash or lost acknowledgement is safe.
  /// Every other non-2xx status throws.
  ///
  /// The id is server-supplied and must be one path segment: an id containing `/` would address
  /// another route, whose 404 would read as a successful delete.
  public func deleteMediaProgress(
    account: TokenAccount,
    progressID: String
  ) async throws -> MediaProgressDeletion {
    guard isUsablePathSegment(progressID) else {
      throw RequestBuilderError.invalidURL
    }
    let tokens = try loadTokens(for: account)
    let routeTemplate = "/api/me/progress/:progressId"
    let request = try requestBuilder.makeRequest(
      method: .delete,
      path: "/api/me/progress/\(progressID)",
      routeTemplate: routeTemplate,
      transportClass: .progressSync
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    guard response.statusCode != 404 else { return .alreadyGone }
    try validateSuccess(response)
    return .deleted
  }
}
