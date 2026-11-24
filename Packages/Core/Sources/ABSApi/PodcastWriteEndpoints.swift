import Foundation

/// Bounds applied to values crossing the Audiobookshelf podcast-write boundary. The server does
/// not publish a useful contract for these fields, so ABSApi uses the same conservative string
/// bound as its read-side decoder and never forwards an unbounded native RSS value.
public enum PodcastWriteBounds {
  public static let maximumStringBytes = EndpointDecodeLimits.standard.maximumListStringBytes
}

public enum PodcastWriteField: String, Sendable, Equatable {
  case libraryID
  case folderID
  case path
  case title
  case author
  case feedURL
  case imageURL
  case itemID
  case episodeID
  case episodeTitle
  case description
  case subtitle
  case guid
  case enclosureURL
  case enclosureType
  case seasonNumber
  case episodeNumber
  case episodeType
  case publishedAt
  case declaredBytes
  case automationSettings
  case maxNewEpisodesToDownload
  case maxEpisodesToKeep
}

/// Client-side validation failures for the narrow podcast mutation surface. These cases carry
/// only a field name and a bound; raw URLs, paths, credentials, and native feed text never enter
/// an error value or its description.
public enum PodcastWriteError: Error, Sendable, Equatable {
  case credentialedURL
  case unsupportedURLScheme
  case invalidPath
  case invalidValue(field: PodcastWriteField)
  case fieldTooLong(field: PodcastWriteField, maximumBytes: Int)
}

/// The small body sent to `POST /api/podcasts`. Artwork is optional and only an
/// independently validated declared URL is sent; descriptions and server queue controls are
/// absent. In particular, `episodesToDownload` is not a field in this model and can
/// never be emitted by its encoder.
public struct PodcastCreateRequest: Encodable, Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let libraryID: String
  public let folderID: String
  public let path: String
  public let title: String
  public let author: String?
  public let feedURL: String
  /// A best-effort, credential-free cover declaration. Invalid values are represented as `nil`
  /// rather than making an otherwise valid show creation fail.
  public let imageURL: String?

  public init(
    libraryID: String,
    folderID: String,
    path: String,
    title: String,
    author: String? = nil,
    feedURL: String,
    imageURL: String? = nil
  ) {
    self.libraryID = libraryID
    self.folderID = folderID
    self.path = path
    self.title = title
    self.author = author
    self.feedURL = feedURL
    self.imageURL = Self.validatedImageURL(imageURL)
  }

  private enum CodingKeys: String, CodingKey { case libraryId, folderId, path, media }
  private enum MediaCodingKeys: String, CodingKey { case metadata }
  private enum MetadataCodingKeys: String, CodingKey { case title, author, feedUrl, imageUrl }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(libraryID, forKey: .libraryId)
    try container.encode(folderID, forKey: .folderId)
    try container.encode(path, forKey: .path)

    var media = container.nestedContainer(keyedBy: MediaCodingKeys.self, forKey: .media)
    var metadata = media.nestedContainer(keyedBy: MetadataCodingKeys.self, forKey: .metadata)
    try metadata.encode(title, forKey: .title)
    if let author, author.isEmpty == false {
      try metadata.encode(author, forKey: .author)
    }
    try metadata.encode(feedURL, forKey: .feedUrl)
    try metadata.encodeIfPresent(imageURL, forKey: .imageUrl)
  }

  public var description: String {
    "PodcastCreateRequest(libraryID: <redacted>, folderID: <redacted>, path: <redacted>, "
      + "title: <redacted>, authorPresent: \(author?.isEmpty == false), feedURL: <redacted>, "
      + "imageURLPresent: \(imageURL != nil))"
  }

  public var debugDescription: String { description }

  /// Source URLs and metadata are not diagnostic data. Suppress synthesized reflection so a
  /// failed assertion cannot print either URL or its opaque query.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }

  /// Validates a persisted or caller-provided artwork declaration at the wire boundary. The
  /// original spelling is returned so an opaque query remains intact; the query is never included
  /// in this request's descriptions or reflection.
  public static func validatedImageURL(_ value: String?) -> String? {
    guard let value,
      value.isEmpty == false,
      value.utf8.count <= PodcastWriteBounds.maximumStringBytes,
      value.utf8.allSatisfy({ $0 != 0 }),
      value.range(of: "%00", options: .caseInsensitive) == nil,
      let url = URL(string: value),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), host.isEmpty == false,
      url.user == nil,
      url.password == nil,
      url.port == nil || (1...65_535).contains(url.port!),
      url.fragment == nil,
      isPublicArtworkHost(host)
    else { return nil }
    return value
  }
}

/// One episode body accepted by Audiobookshelf's `download-episodes` route. The public API takes
/// one value and wraps it in a one-element array at the send seam; callers cannot accidentally
/// request a batch. Optional values are omitted rather than encoded as JSON null.
public struct PodcastEpisodeDownloadRequest: Encodable, Sendable, Equatable, CustomReflectable {
  public let title: String?
  public let description: String?
  public let subtitle: String?
  public let enclosureURL: String
  public let enclosureType: String?
  public let declaredBytes: Int64?
  public let publishedAt: Date?
  public let guid: String?
  public let seasonNumber: String?
  public let episodeNumber: String?
  public let episodeType: String?

  public init(
    title: String? = nil,
    description: String? = nil,
    subtitle: String? = nil,
    enclosureURL: String,
    enclosureType: String? = nil,
    declaredBytes: Int64? = nil,
    publishedAt: Date? = nil,
    guid: String? = nil,
    seasonNumber: String? = nil,
    episodeNumber: String? = nil,
    episodeType: String? = nil
  ) {
    self.title = title
    self.description = description
    self.subtitle = subtitle
    self.enclosureURL = enclosureURL
    self.enclosureType = enclosureType
    self.declaredBytes = declaredBytes
    self.publishedAt = publishedAt
    self.guid = guid
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
  }

  private enum CodingKeys: String, CodingKey {
    case title, description, subtitle, enclosure, guid, season, episode, episodeType, pubDate,
      publishedAt
  }
  private enum EnclosureCodingKeys: String, CodingKey { case url, type, length }

  private static let pubDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return formatter
  }()

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(title, forKey: .title)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encodeIfPresent(subtitle, forKey: .subtitle)
    try container.encodeIfPresent(guid, forKey: .guid)
    try container.encodeIfPresent(seasonNumber, forKey: .season)
    try container.encodeIfPresent(episodeNumber, forKey: .episode)
    try container.encodeIfPresent(episodeType, forKey: .episodeType)

    var enclosure = container.nestedContainer(keyedBy: EnclosureCodingKeys.self, forKey: .enclosure)
    try enclosure.encode(enclosureURL, forKey: .url)
    try enclosure.encodeIfPresent(enclosureType, forKey: .type)
    if let declaredBytes {
      try enclosure.encode(String(declaredBytes), forKey: .length)
    }

    if let publishedAt {
      let millis = try validatedPublishedAtMillis(publishedAt)
      try container.encode(Self.pubDateFormatter.string(from: publishedAt), forKey: .pubDate)
      try container.encode(millis, forKey: .publishedAt)
    }
  }

  /// Prevents accidental `String(describing:)` reflection from printing enclosure URLs, titles,
  /// or native description text in diagnostics.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

extension ABSClient {
  /// Creates one podcast item and returns only the server's usable item id. The endpoint does not
  /// enqueue an episode; that is a separate operation because Audiobookshelf's server queue is
  /// non-atomic and its create response is the persistence boundary for the item id.
  public func createPodcast(
    account: TokenAccount,
    request: PodcastCreateRequest,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> String {
    try checkPodcastWriteCancellation()
    try validate(request)

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/api/podcasts",
      body: request,
      routeTemplate: "/api/podcasts"
    )
    try checkPodcastWriteCancellation()

    let response = try await sendPodcastMutation(
      request, account: account, initialTokens: tokens)
    try validateSuccess(response)
    let wire = try decoder.decode(
      PodcastCreateResponseDTO.self,
      from: response.body,
      endpoint: "/api/podcasts",
      diagnostics: diagnostics
    )
    guard let id = wire.id,
      id.isEmpty == false,
      id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { throw APIError.decoding }
    do {
      try validateIdentifier(id, field: .itemID)
    } catch {
      throw APIError.decoding
    }
    return id
  }

  /// Convenience form for callers that already have the resolved destination fields.
  public func createPodcast(
    account: TokenAccount,
    libraryID: String,
    folderID: String,
    path: String,
    title: String,
    author: String?,
    feedURL: String,
    imageURL: String? = nil,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> String {
    try await createPodcast(
      account: account,
      request: PodcastCreateRequest(
        libraryID: libraryID,
        folderID: folderID,
        path: path,
        title: title,
        author: author,
        feedURL: feedURL,
        imageURL: imageURL
      ),
      diagnostics: diagnostics
    )
  }

  /// Queues exactly one episode. Audiobookshelf returns an empty-body 200 for the normal path,
  /// so this method validates status only and does not decode a success payload.
  public func enqueuePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episode: PodcastEpisodeDownloadRequest
  ) async throws {
    try checkPodcastWriteCancellation()
    try validateIdentifier(itemID, field: .itemID)
    try validate(episode)

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeJSONRequest(
      method: .post,
      path: "/api/podcasts/" + itemID + "/download-episodes",
      body: [episode],
      routeTemplate: "/api/podcasts/:id/download-episodes"
    )
    try checkPodcastWriteCancellation()

    let response = try await sendPodcastMutation(
      request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }

  /// Hard-removes one server episode. The caller supplies an episode id already confirmed by a
  /// complete server response; this route never accepts a show-wide or queue-wide delete.
  public func removePodcastEpisode(
    account: TokenAccount,
    itemID: String,
    episodeID: String
  ) async throws {
    try checkPodcastWriteCancellation()
    try validateIdentifier(itemID, field: .itemID)
    try validateIdentifier(episodeID, field: .episodeID)

    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .delete,
      path: "/api/podcasts/" + itemID + "/episode/" + episodeID,
      queryItems: [URLQueryItem(name: "hard", value: "1")],
      routeTemplate: "/api/podcasts/:id/episode/:episodeId"
    )
    try checkPodcastWriteCancellation()

    let response = try await sendPodcastMutation(
      request, account: account, initialTokens: tokens)
    try validateSuccess(response)
  }

  // Enqueue constructs its one-element body before handing the request to this shared send seam.
  // Internal so the automation-settings endpoint, in its own file, shares the error mapping.
  func sendPodcastMutation(
    _ request: HTTPRequest,
    account: TokenAccount,
    initialTokens: TokenPair
  ) async throws -> HTTPResponse {
    do {
      return try await authenticatedSend(request, account: account, initialTokens: initialTokens)
    } catch is CancellationError {
      throw APIError.cancelled
    } catch let error as URLError where error.code == .cancelled {
      throw APIError.cancelled
    } catch let error as APIError {
      throw error
    } catch {
      throw APIError.transport
    }
  }

  func checkPodcastWriteCancellation() throws {
    do {
      try Task.checkCancellation()
    } catch {
      throw APIError.cancelled
    }
  }

  private func validate(_ request: PodcastCreateRequest) throws {
    try validateIdentifier(request.libraryID, field: .libraryID)
    try validateIdentifier(request.folderID, field: .folderID)
    try validatePath(request.path)
    try validateNonEmptyBounded(request.title, field: .title)
    if let author = request.author, author.isEmpty == false {
      try validateBounded(author, field: .author)
    }
    try validateSourceURL(request.feedURL, field: .feedURL)
  }

  private func validate(_ episode: PodcastEpisodeDownloadRequest) throws {
    if let title = episode.title {
      try validateBounded(title, field: .episodeTitle)
    }
    if let description = episode.description {
      try validateBounded(description, field: .description)
    }
    if let subtitle = episode.subtitle {
      try validateBounded(subtitle, field: .subtitle)
    }
    try validateSourceURL(episode.enclosureURL, field: .enclosureURL)
    if let enclosureType = episode.enclosureType {
      try validateBounded(enclosureType, field: .enclosureType)
    }
    if let guid = episode.guid {
      try validateBounded(guid, field: .guid)
    }
    if let seasonNumber = episode.seasonNumber {
      try validateBounded(seasonNumber, field: .seasonNumber)
    }
    if let episodeNumber = episode.episodeNumber {
      try validateBounded(episodeNumber, field: .episodeNumber)
    }
    if let episodeType = episode.episodeType {
      try validateBounded(episodeType, field: .episodeType)
    }
    if let declaredBytes = episode.declaredBytes, declaredBytes < 0 {
      throw PodcastWriteError.invalidValue(field: .declaredBytes)
    }
    if let publishedAt = episode.publishedAt {
      _ = try validatedPublishedAtMillis(publishedAt)
    }
  }

  func validateBounded(_ value: String, field: PodcastWriteField) throws {
    guard value.utf8.count <= PodcastWriteBounds.maximumStringBytes else {
      throw PodcastWriteError.fieldTooLong(
        field: field, maximumBytes: PodcastWriteBounds.maximumStringBytes)
    }
  }

  func validateNonEmptyBounded(_ value: String, field: PodcastWriteField) throws {
    guard value.isEmpty == false else { throw PodcastWriteError.invalidValue(field: field) }
    try validateBounded(value, field: field)
  }

  func validateIdentifier(_ value: String, field: PodcastWriteField) throws {
    try validateNonEmptyBounded(value, field: field)
    guard isUsablePathSegment(value) else {
      throw PodcastWriteError.invalidValue(field: field)
    }
  }

  private func validatePath(_ value: String) throws {
    if value.utf8.count > PodcastWriteBounds.maximumStringBytes {
      throw PodcastWriteError.fieldTooLong(
        field: .path, maximumBytes: PodcastWriteBounds.maximumStringBytes)
    }
    guard isUsableAbsolutePath(value, maximumBytes: PodcastWriteBounds.maximumStringBytes) else {
      throw PodcastWriteError.invalidPath
    }
  }

  private func validateSourceURL(_ value: String, field: PodcastWriteField) throws {
    try validateNonEmptyBounded(value, field: field)
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      url.host?.isEmpty == false
    else { throw PodcastWriteError.unsupportedURLScheme }
    guard scheme == "http" || scheme == "https" else {
      throw PodcastWriteError.unsupportedURLScheme
    }
    guard url.user == nil, url.password == nil else {
      throw PodcastWriteError.credentialedURL
    }
  }
}

private func validatedPublishedAtMillis(_ date: Date) throws -> Int64 {
  let millis = date.timeIntervalSince1970 * 1000
  guard millis.isFinite, millis >= 0,
    let exactMillis = Int64(exactly: millis.rounded(.towardZero))
  else {
    throw PodcastWriteError.invalidValue(field: .publishedAt)
  }
  return exactMillis
}

private struct PodcastCreateResponseDTO: Decodable {
  let id: String?

  private enum CodingKeys: String, CodingKey { case id }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeBoundedString(forKey: .id, policy: .reject)
  }
}
