import Foundation

/// One Audiobookshelf audio bookmark as `GET /api/me` reports it (`User.bookmarks`,
/// `AudioBookmarkObject` in the server source). The server stores no id: a bookmark is identified
/// by `(libraryItemID, time)`, and the rename and delete routes find it by comparing `time` as a
/// number. `time` is therefore carried exactly as decoded and must be sent back unchanged.
public struct ServerAudioBookmark: Sendable, Equatable {
  public let libraryItemID: String
  public let time: Double
  public let title: String
  public let createdAt: Date?

  public init(libraryItemID: String, time: Double, title: String, createdAt: Date?) {
    self.libraryItemID = libraryItemID
    self.time = time
    self.title = title
    self.createdAt = createdAt
  }
}

/// The outcome of `renameAudioBookmark`. The server answers 404 both when the item is gone and when
/// no bookmark matches; either way there is nothing left to rename.
public enum AudioBookmarkRename: Sendable, Equatable {
  case renamed
  case notFound
}

/// The outcome of `deleteAudioBookmark`. A bookmark already gone (a replay after a lost
/// acknowledgement, or another client deleting it first) is a successful delete.
public enum AudioBookmarkDeletion: Sendable, Equatable {
  case deleted
  case alreadyGone
}

/// The `bookmarks` element of `GET /api/me`. An element is usable only with a bounded
/// `libraryItemId`, a finite non-negative numeric `time` and a string `title`; anything else is
/// dropped by the caller's validation and counted, so the list is reported incomplete.
///
/// `time` is decoded strictly as a JSON number. A string `time` (another client could store one) is
/// dropped: the server finds it with `==` but removes with `!==`, so a delete would report success
/// and leave it in place.
struct AudioBookmarkDTO: Decodable {
  let libraryItemId: String?
  let time: Double?
  let title: String?
  let createdAt: Date?

  private enum CodingKeys: String, CodingKey {
    case libraryItemId, time, title, createdAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `.reject`, not `.truncate`: a truncated item id would address a different item.
    libraryItemId = try? container.decodeBoundedString(forKey: .libraryItemId, policy: .reject)
    let rawTime = try container.decode(LossyOptional<Double>.self, forKey: .time).wrappedValue
    if let rawTime, rawTime.isFinite, rawTime >= 0 {
      time = rawTime
    } else {
      time = nil
    }
    title = try container.decodeBoundedString(forKey: .title)
    createdAt = try container.decodeEpochMillisDate(forKey: .createdAt)
  }

  var isUsable: Bool {
    guard let libraryItemId, libraryItemId.isEmpty == false else { return false }
    return time != nil && title != nil
  }

  var bookmark: ServerAudioBookmark? {
    guard isUsable, let libraryItemId, let time, let title else { return nil }
    return ServerAudioBookmark(
      libraryItemID: libraryItemId, time: time, title: title, createdAt: createdAt)
  }
}

/// The body of a create or rename. `CodingKeys` is exhaustive on purpose: nothing else may reach
/// the server's user record.
struct AudioBookmarkWriteBody: Encodable {
  let time: Double
  let title: String

  private enum CodingKeys: String, CodingKey {
    case time, title
  }
}

extension ABSClient {
  /// The `:time` path segment of the delete route. The server parses it with `Number(...)` and
  /// matches with strict equality, so it must round-trip to this double. Swift's `description` is
  /// the shortest such form (`1234.0`, `0.1`); a fixed-precision format would not be.
  static func audioBookmarkTimePathSegment(_ time: Double) -> String {
    // `-0.0` prints as "-0.0"; the server's `Number("-0.0") !== 0` is false, but normalising keeps
    // the path free of a sign the server never stored.
    (time == 0 ? 0.0 : time).description
  }

  /// `POST /api/me/item/{libraryItemId}/bookmark` with `{time, title}`. The server upserts: a
  /// bookmark already at this `(item, time)` only has its title replaced, so a replay after a lost
  /// acknowledgement is safe. The response body (the bookmark) is not needed and is not decoded.
  /// A 404 (the item is gone) and every other non-2xx status throw.
  public func createAudioBookmark(
    account: TokenAccount,
    libraryItemID: String,
    time: Double,
    title: String
  ) async throws {
    let request = try audioBookmarkWriteRequest(
      method: .post, libraryItemID: libraryItemID, time: time, title: title)
    let response = try await authenticatedSend(
      request, account: account, initialTokens: try loadTokens(for: account))
    try validateSuccess(response)
  }

  /// `PATCH /api/me/item/{libraryItemId}/bookmark` with `{time, title}`. Never creates a bookmark.
  /// A 404 maps to `.notFound`; every other non-2xx status throws.
  public func renameAudioBookmark(
    account: TokenAccount,
    libraryItemID: String,
    time: Double,
    title: String
  ) async throws -> AudioBookmarkRename {
    let request = try audioBookmarkWriteRequest(
      method: .patch, libraryItemID: libraryItemID, time: time, title: title)
    let response = try await authenticatedSend(
      request, account: account, initialTokens: try loadTokens(for: account))
    guard response.statusCode != 404 else { return .notFound }
    try validateSuccess(response)
    return .renamed
  }

  /// `DELETE /api/me/item/{libraryItemId}/bookmark/{time}`. A 404 maps to `.alreadyGone`; every
  /// other non-2xx status throws.
  public func deleteAudioBookmark(
    account: TokenAccount,
    libraryItemID: String,
    time: Double
  ) async throws -> AudioBookmarkDeletion {
    guard isUsablePathSegment(libraryItemID), time.isFinite, time >= 0 else {
      throw RequestBuilderError.invalidURL
    }
    let request = try requestBuilder.makeRequest(
      method: .delete,
      path:
        "/api/me/item/\(libraryItemID)/bookmark/\(Self.audioBookmarkTimePathSegment(time))",
      routeTemplate: "/api/me/item/:id/bookmark/:time",
      transportClass: .progressSync
    )
    let response = try await authenticatedSend(
      request, account: account, initialTokens: try loadTokens(for: account))
    guard response.statusCode != 404 else { return .alreadyGone }
    try validateSuccess(response)
    return .deleted
  }

  private func audioBookmarkWriteRequest(
    method: HTTPMethod,
    libraryItemID: String,
    time: Double,
    title: String
  ) throws -> HTTPRequest {
    // The item id is server-supplied, so it must be exactly one path segment: an id containing `/`
    // would address another route. The server rejects an empty title and a non-numeric time.
    guard isUsablePathSegment(libraryItemID), time.isFinite, time >= 0, title.isEmpty == false
    else {
      throw RequestBuilderError.invalidURL
    }
    return try requestBuilder.makeJSONRequest(
      method: method,
      path: "/api/me/item/\(libraryItemID)/bookmark",
      body: AudioBookmarkWriteBody(time: time, title: title),
      routeTemplate: "/api/me/item/:id/bookmark",
      transportClass: .progressSync,
      outputFormatting: [.sortedKeys]
    )
  }
}
