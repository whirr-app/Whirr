import Foundation

/// Clean public value type, never the raw wire shape (ARCHITECTURE.md §1: wire DTOs stay internal
/// to ABSApi).
public struct Library: Sendable, Equatable, CustomReflectable {
  public let id: String
  public let name: String
  public let mediaType: String?
  public let onlyShowLaterBooksInContinueSeries: Bool
  /// Server-declared folders, kept for the podcast destination resolver. Not copied into
  /// Persistence or the library-selection UI projection; callers that don't write podcasts can
  /// ignore them.
  public let folders: [LibraryFolder]

  public init(
    id: String,
    name: String,
    mediaType: String?,
    onlyShowLaterBooksInContinueSeries: Bool,
    folders: [LibraryFolder] = []
  ) {
    self.id = id
    self.name = name
    self.mediaType = mediaType
    self.onlyShowLaterBooksInContinueSeries = onlyShowLaterBooksInContinueSeries
    self.folders = folders
  }

  /// Folder paths are server-local values and must not appear in accidental diagnostics.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// A server-declared library folder. `fullPath` is for internal destination resolution only and
/// is never logged or shown as an editable path. The nested `libraryId` is a consistency check;
/// prefer the containing `Library.id` when building a destination.
public struct LibraryFolder: Sendable, Equatable, CustomReflectable {
  public let id: String
  public let fullPath: String
  public let libraryID: String?

  public init(id: String, fullPath: String, libraryID: String? = nil) {
    self.id = id
    self.fullPath = fullPath
    self.libraryID = libraryID
  }

  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// Minified item shape (API-CONVENTIONS.md rule 15: library browsing always requests
/// `minified=1`). Clean public value type, not the wire DTO.
public struct LibraryItemSummary: Sendable, Equatable, CustomReflectable {
  public let id: String
  public let libraryID: String?
  public let mediaType: String?
  public let title: String?
  public let authorName: String?
  public let seriesName: String?
  /// Item-level `addedAt`, epoch milliseconds on the wire. Drives home-screen recency sort.
  public let addedAt: Date?
  /// `media.duration`. Documented on the full item shape; presence on the minified shape is
  /// believed but not confirmed.
  public let durationSeconds: Double?
  /// `media.numAudioFiles`, one of the minified audiobook-vs-ebook signals.
  public let numAudioFiles: Int?
  /// `media.ebookFormat`, the other minified audiobook-vs-ebook signal.
  public let ebookFormat: String?
  /// Item-level server mutation time. Audiobookshelf sends epoch milliseconds.
  public let updatedAt: Date?
  /// Podcast-only minified catalogue size. Nil for books and older/trimmed servers.
  public let podcastEpisodeCount: Int?
  /// Whether the minified media explicitly names a server-side cover. `nil` means the payload did
  /// not carry a trustworthy signal (for example an older/trimmed server), which downstream code
  /// must treat as unknown rather than as "no artwork".
  public let hasServerArtwork: Bool?
  /// Podcast-only source feed metadata. The state distinguishes an omitted field (which lets
  /// SyncEngine preserve a previous identity) from explicit null/wrong-type/over-bound data
  /// (which clears it).
  public let feedURLState: PodcastFeedURLState
  /// Podcast-only declared show language; see `PodcastLanguageState`.
  public let podcastLanguageState: PodcastLanguageState

  public init(
    id: String,
    libraryID: String?,
    mediaType: String?,
    title: String?,
    authorName: String?,
    seriesName: String?,
    addedAt: Date? = nil,
    durationSeconds: Double? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    updatedAt: Date? = nil,
    podcastEpisodeCount: Int? = nil,
    hasServerArtwork: Bool? = nil,
    feedURLState: PodcastFeedURLState = .absent,
    podcastLanguageState: PodcastLanguageState = .absent
  ) {
    self.id = id
    self.libraryID = libraryID
    self.mediaType = mediaType
    self.title = title
    self.authorName = authorName
    self.seriesName = seriesName
    self.addedAt = addedAt
    self.durationSeconds = durationSeconds
    self.numAudioFiles = numAudioFiles
    self.ebookFormat = ebookFormat
    self.updatedAt = updatedAt
    self.podcastEpisodeCount = podcastEpisodeCount
    self.hasServerArtwork = hasServerArtwork
    self.feedURLState = feedURLState
    self.podcastLanguageState = podcastLanguageState
  }

  /// A feed URL can carry a signed query or otherwise private source identity; keep it out of
  /// default reflection used by diagnostics and test failures.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}

/// A single fetched page plus the pagination metadata the wire response carried. A page-fetch
/// primitive only: sync owns traversal (stopping conditions, drift detection across repeated
/// fetches) using the `total`/`limit`/`page` exposed here.
public struct LibraryItemsPage: Sendable, Equatable {
  public let items: [LibraryItemSummary]
  public let total: Int
  public let limit: Int
  public let page: Int

  public init(items: [LibraryItemSummary], total: Int, limit: Int, page: Int) {
    self.items = items
    self.total = total
    self.limit = limit
    self.page = page
  }
}

/// Client-side page-size policy (API-CONVENTIONS.md rule 15: limit of about 50 to 100). The
/// client caps requests at the top of that band and substitutes the same fallback for
/// non-positive requests, so the server's unlimited `limit=0` is never forwarded. Internal so
/// tests can assert against the same constants.
enum LibraryItemsBounds {
  static let maximum = 100
  static let fallback = 100
}

/// `<group>.<base64(raw UTF-8 value)>`, with no URL-encode step first. The community docs say
/// otherwise, but a live v2.35.1 server matched a genre containing a space only this way.
///
/// Standalone no-value groups (`issues`/`feed-open`) are unsupported: their wire shape is
/// unverified (API-CONVENTIONS.md rule 22).
public struct LibraryItemFilter: Sendable, Equatable {
  public let queryValue: String

  public init(group: String, value: String) {
    queryValue = "\(group).\(Data(value.utf8).base64EncodedString())"
  }
}

extension ABSClient {
  /// The token-store lookup every endpoint shares, so an authentication-policy change is a single
  /// edit.
  func loadTokens(for account: TokenAccount) throws -> TokenPair {
    try refuseOtherAccount(account)
    guard let tokens = try tokenStore.load(for: account) else {
      throw APIError.unauthorized
    }
    return tokens
  }
}

extension ABSClient {
  /// `GET /api/libraries`.
  public func listLibraries(
    account: TokenAccount,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [Library] {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries",
      routeTemplate: "/api/libraries"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      LibraryListDTO.self,
      from: response.body,
      endpoint: "/api/libraries",
      diagnostics: diagnostics
    )
    return wire.libraries.map {
      Library(
        id: $0.id, name: $0.name, mediaType: $0.mediaType,
        onlyShowLaterBooksInContinueSeries: $0.onlyShowLaterBooksInContinueSeries,
        folders: $0.folders.compactMap(Self.makeLibraryFolder))
    }
  }

  /// Pre-persistence API-token variant used by login. It sends the candidate Bearer directly so
  /// resolving the fallback library cannot depend on a token already committed to the store.
  func listLibraries(apiToken: String) async throws -> [Library] {
    guard apiToken.isEmpty == false else { throw APIError.unauthorized }
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries",
      bearerToken: apiToken,
      routeTemplate: "/api/libraries"
    )
    let response = try await send(request)
    try validateSuccess(response)
    let wire = try decoder.decode(
      LibraryListDTO.self, from: response.body, endpoint: "/api/libraries")
    return wire.libraries.map {
      Library(
        id: $0.id, name: $0.name, mediaType: $0.mediaType,
        onlyShowLaterBooksInContinueSeries: $0.onlyShowLaterBooksInContinueSeries,
        folders: $0.folders.compactMap(Self.makeLibraryFolder))
    }
  }

  /// `GET /api/libraries/{id}/items`. A page-fetch primitive with no traversal loop; callers drive
  /// repeated calls.
  public func listLibraryItems(
    account: TokenAccount,
    library libraryID: String,
    page: Int = 0,
    // Must match `LibraryItemsBounds.fallback`: a public default argument must be at least as
    // accessible as this function, so it can't reference the internal enum directly.
    limit: Int = 100,
    sort: String? = nil,
    filter: LibraryItemFilter? = nil,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibraryItemsPage {
    let tokens = try loadTokens(for: account)

    var queryItems = [
      URLQueryItem(name: "limit", value: String(boundedLimit(limit))),
      URLQueryItem(name: "page", value: String(page)),
      URLQueryItem(name: "minified", value: "1"),
    ]
    if let sort {
      queryItems.append(URLQueryItem(name: "sort", value: sort))
    }
    if let filter {
      queryItems.append(URLQueryItem(name: "filter", value: filter.queryValue))
    }

    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/items",
      queryItems: queryItems,
      routeTemplate: "/api/libraries/:id/items"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      LibraryItemsPageDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/items",
      diagnostics: diagnostics
    )

    // `wire.results` already excludes required-id failures (`requiredKey: "id"` below); this
    // `compactMap` is a safety net not expected to filter anything.
    let items = wire.results.compactMap { dto -> LibraryItemSummary? in
      guard let id = dto.id else { return nil }
      return LibraryItemSummary(
        id: id,
        libraryID: dto.libraryId,
        mediaType: dto.mediaType,
        title: dto.title,
        authorName: dto.authorName,
        seriesName: dto.seriesName,
        addedAt: dto.addedAt,
        durationSeconds: dto.durationSeconds,
        numAudioFiles: dto.numAudioFiles,
        ebookFormat: dto.ebookFormat,
        updatedAt: dto.updatedAt,
        podcastEpisodeCount: dto.podcastEpisodeCount,
        hasServerArtwork: dto.hasServerArtwork,
        feedURLState: dto.feedURLState,
        podcastLanguageState: dto.podcastLanguageState
      )
    }
    return LibraryItemsPage(items: items, total: wire.total, limit: wire.limit, page: wire.page)
  }

  private func boundedLimit(_ requested: Int) -> Int {
    guard requested > 0 else { return LibraryItemsBounds.fallback }
    return min(requested, LibraryItemsBounds.maximum)
  }

  private static func makeLibraryFolder(from dto: LibraryFolderDTO) -> LibraryFolder? {
    guard let id = dto.id, id.isEmpty == false,
      let fullPath = dto.fullPath, isUsableFolderPath(fullPath)
    else { return nil }
    return LibraryFolder(id: id, fullPath: fullPath, libraryID: dto.libraryId)
  }

  private static func isUsableFolderPath(_ value: String) -> Bool {
    isUsableAbsolutePath(
      value, maximumBytes: EndpointDecodeLimits.standard.maximumListStringBytes)
  }
}

private struct LibraryListDTO: Decodable {
  let libraries: [LibraryDTO]

  private enum CodingKeys: String, CodingKey { case libraries }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    libraries = try container.decodeLossyArray(forKey: .libraries)
  }
}

private struct LibraryDTO: Decodable {
  let id: String
  let name: String
  let mediaType: String?
  let onlyShowLaterBooksInContinueSeries: Bool
  let folders: [LibraryFolderDTO]

  private enum CodingKeys: String, CodingKey { case id, name, mediaType, settings, folders }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    // A wrong-typed `folders` costs only the podcast write destination, so it must not drop the
    // library from browsing. It still records a diagnostic so a server shape change is visible.
    do {
      folders = try container.decodeLossyArrayIfPresent(
        forKey: .folders,
        validating: { $0.id != nil && $0.fullPath != nil },
        requiredKey: "id"
      )
    } catch {
      BoundedDecoderContext.record(from: decoder, codingPath: [CodingKeys.folders.stringValue])
      folders = []
    }
    let settings = try? container.decode(LibrarySettingsDTO.self, forKey: .settings)
    onlyShowLaterBooksInContinueSeries = settings?.onlyShowLaterBooksInContinueSeries ?? false
  }
}

private struct LibraryFolderDTO: Decodable {
  let id: String?
  let libraryId: String?
  let fullPath: String?

  private enum CodingKeys: String, CodingKey { case id, libraryId, fullPath }

  init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      id = nil
      libraryId = nil
      fullPath = nil
      return
    }
    id = try container.decodeBoundedString(forKey: .id, policy: .reject)
    libraryId = try container.decodeBoundedString(forKey: .libraryId)
    fullPath = try container.decodeBoundedString(forKey: .fullPath, policy: .reject)
  }
}

private struct LibrarySettingsDTO: Decodable {
  let onlyShowLaterBooksInContinueSeries: Bool

  private enum CodingKeys: String, CodingKey { case onlyShowLaterBooksInContinueSeries }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    onlyShowLaterBooksInContinueSeries =
      try container.decode(LossyOptional<Bool>.self, forKey: .onlyShowLaterBooksInContinueSeries)
      .wrappedValue ?? false
  }
}

private struct LibraryItemsPageDTO: Decodable {
  let results: [LibraryItemDTO]
  let total: Int
  let limit: Int
  let page: Int

  private enum CodingKeys: String, CodingKey { case results, total, limit, page }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Required-id skip (ARCHITECTURE.md §7): a missing/null/wrong-type `id` never surfaces as a
    // `LibraryItemSummary`, but the page still decodes.
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

/// The minified item wire shape: `media.metadata` is trimmed to `authorName`/`seriesName`
/// strings, and `media` additionally carries `duration`, `numAudioFiles` and `ebookFormat`.
/// `title`/`authorName`/`seriesName`/`ebookFormat` are lossy scalars (null or wrong type becomes
/// absent, item kept). `id` is a bounded identity: an oversized value decodes as nil and falls out
/// through the page's `requiredKey` filter. `libraryId` is an optional identity: absent or null is
/// nil, but a present rejected value drops the item through `LossyArray`. `addedAt` is epoch
/// milliseconds (`decodeEpochMillisDate`).
private struct LibraryItemDTO: Decodable {
  let id: String?
  let libraryId: String?
  let mediaType: String?
  let title: String?
  let authorName: String?
  let seriesName: String?
  let addedAt: Date?
  let durationSeconds: Double?
  let numAudioFiles: Int?
  let ebookFormat: String?
  let updatedAt: Date?
  let podcastEpisodeCount: Int?
  let hasServerArtwork: Bool?
  let feedURLState: PodcastFeedURLState
  let podcastLanguageState: PodcastLanguageState

  private enum CodingKeys: String, CodingKey { case id, libraryId, mediaType, media, addedAt, updatedAt }
  private enum MediaCodingKeys: String, CodingKey {
    case metadata, duration, numAudioFiles, ebookFormat, numEpisodes, coverPath
  }
  /// `authorName` is the book shape's flattening of `authors[]`. Podcast metadata has no such
  /// array and gives a plain `author` string (as `ItemDetail`'s podcast decoder reads), so both
  /// are decoded and `authorName` wins where both appear.
  private enum MetadataCodingKeys: String, CodingKey { case title, authorName, author, seriesName, feedUrl, language }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    // A present but rejected library id must drop the item, not read as "library unknown": the
    // field is an identity, and callers fall back to the queried library only when it is absent.
    libraryId = try container.decodeOptionalIdentity(forKey: .libraryId)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
    addedAt = try container.decodeEpochMillisDate(forKey: .addedAt)
    updatedAt = try container.decodeEpochMillisDate(forKey: .updatedAt)
    let hasMedia = container.contains(.media)
    let mediaContainer: KeyedDecodingContainer<MediaCodingKeys>?
    if hasMedia {
      mediaContainer = try? container.nestedContainer(keyedBy: MediaCodingKeys.self, forKey: .media)
    } else {
      mediaContainer = nil
    }
    let metadataContainer: KeyedDecodingContainer<MetadataCodingKeys>?
    if let mediaContainer, mediaContainer.contains(.metadata) {
      metadataContainer = try? mediaContainer.nestedContainer(
        keyedBy: MetadataCodingKeys.self, forKey: .metadata)
    } else {
      metadataContainer = nil
    }
    feedURLState = Self.decodeFeedURLState(
      mediaType: mediaType,
      hasMedia: hasMedia,
      mediaContainer: mediaContainer,
      metadataContainer: metadataContainer,
      decoder: decoder)
    podcastLanguageState = Self.decodeLanguageState(
      mediaType: mediaType, hasMedia: hasMedia, mediaContainer: mediaContainer,
      metadataContainer: metadataContainer)

    if let mediaContainer {
      durationSeconds = try mediaContainer.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
      numAudioFiles = try mediaContainer.decode(LossyOptional<Int>.self, forKey: .numAudioFiles).wrappedValue
      ebookFormat = try mediaContainer.decodeBoundedString(forKey: .ebookFormat)
      podcastEpisodeCount =
        try mediaContainer.decode(LossyOptional<Int>.self, forKey: .numEpisodes).wrappedValue
      if mediaContainer.contains(.coverPath) {
        do {
          let coverPath = try mediaContainer.decodeIfPresent(String.self, forKey: .coverPath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          hasServerArtwork = coverPath?.isEmpty == false
        } catch {
          hasServerArtwork = nil
        }
      } else {
        hasServerArtwork = nil
      }

      if let metadataContainer {
        title = try metadataContainer.decodeBoundedString(forKey: .title)
        authorName =
          try metadataContainer.decodeBoundedString(forKey: .authorName)
          ?? metadataContainer.decodeBoundedString(forKey: .author)
        seriesName = try metadataContainer.decodeBoundedString(forKey: .seriesName)
      } else {
        title = nil
        authorName = nil
        seriesName = nil
      }
    } else {
      title = nil
      authorName = nil
      seriesName = nil
      durationSeconds = nil
      numAudioFiles = nil
      ebookFormat = nil
      podcastEpisodeCount = nil
      hasServerArtwork = nil
    }
  }

  private static func decodeFeedURLState(
    mediaType: String?,
    hasMedia: Bool,
    mediaContainer: KeyedDecodingContainer<MediaCodingKeys>?,
    metadataContainer: KeyedDecodingContainer<MetadataCodingKeys>?,
    decoder: Decoder
  ) -> PodcastFeedURLState {
    guard mediaType == "podcast" else { return .absent }
    guard hasMedia else { return .absent }
    guard let mediaContainer else { return .invalid }
    guard mediaContainer.contains(.metadata) else { return .absent }
    guard let metadataContainer else { return .invalid }
    guard metadataContainer.contains(.feedUrl) else { return .absent }
    guard let value = try? metadataContainer.decode(String.self, forKey: .feedUrl) else {
      return .invalid
    }
    guard value.utf8.count <= BoundedDecoderContext.maximumListStringBytes(from: decoder) else {
      return .invalid
    }
    return .value(value)
  }

  /// Mirrors `decodeFeedURLState`'s presence ladder; only a missing key or container is `absent`.
  private static func decodeLanguageState(
    mediaType: String?,
    hasMedia: Bool,
    mediaContainer: KeyedDecodingContainer<MediaCodingKeys>?,
    metadataContainer: KeyedDecodingContainer<MetadataCodingKeys>?
  ) -> PodcastLanguageState {
    guard mediaType == "podcast", hasMedia else { return .absent }
    guard let mediaContainer else { return .cleared }
    guard mediaContainer.contains(.metadata) else { return .absent }
    guard let metadataContainer else { return .cleared }
    guard metadataContainer.contains(.language) else { return .absent }
    guard let raw = try? metadataContainer.decode(String.self, forKey: .language) else {
      return .cleared
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.isEmpty == false, value.utf8.count <= PodcastLanguageState.maximumBytes else {
      return .cleared
    }
    return .value(value)
  }
}
