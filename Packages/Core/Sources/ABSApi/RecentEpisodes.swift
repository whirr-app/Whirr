import Foundation

/// One episode from a library's newest-episodes shelf, with just enough parent-show context to
/// render it without a second request.
///
/// The wire element is a whole episode object (as in `media.episodes`), so `PodcastEpisodeDTO`
/// decodes it unchanged; this type adds the owning item's id and the show's metadata.
public struct RecentEpisode: Sendable, Equatable {
  public let libraryItemID: String
  public let showTitle: String?
  public let showAuthor: String?
  public let episode: PodcastEpisode

  public init(
    libraryItemID: String,
    showTitle: String?,
    showAuthor: String?,
    episode: PodcastEpisode
  ) {
    self.libraryItemID = libraryItemID
    self.showTitle = showTitle
    self.showAuthor = showAuthor
    self.episode = episode
  }
}

extension ABSClient {
  /// `GET /api/libraries/{id}/recent-episodes`, the route behind the web UI's newest-episodes
  /// shelf (present on a live v2.35.1 server). One request per library answers "what arrived
  /// recently" without inferring it from a locally expanded catalogue. `limit` is clamped to
  /// rule 15's paginated-list bound, as `listLibraryItems` clamps its own.
  public func recentEpisodes(
    account: TokenAccount,
    library libraryID: String,
    page: Int = 0,
    limit: Int = 50,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> [RecentEpisode] {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/recent-episodes",
      queryItems: [
        URLQueryItem(name: "limit", value: String(boundedLimit(limit))),
        URLQueryItem(name: "page", value: String(page)),
      ],
      routeTemplate: "/api/libraries/:id/recent-episodes"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      RecentEpisodesPageDTO.self,
      from: response.body,
      endpoint: "/api/libraries/:id/recent-episodes",
      diagnostics: diagnostics
    )

    // `wire.episodes` already excludes elements missing either required key; the `compactMap` is
    // a zero-cost safety net.
    return wire.episodes.compactMap { dto -> RecentEpisode? in
      guard let libraryItemID = dto.libraryItemId, let episode = dto.episode.asDomainEpisode else {
        return nil
      }
      return RecentEpisode(
        libraryItemID: libraryItemID,
        showTitle: dto.showTitle,
        showAuthor: dto.showAuthor,
        episode: episode)
    }
  }

  private func boundedLimit(_ requested: Int) -> Int {
    guard requested > 0 else { return LibraryItemsBounds.fallback }
    return min(requested, LibraryItemsBounds.maximum)
  }
}

extension PodcastEpisodeDTO {
  /// The mapping `PodcastMedia.init(dto:)` applies to episodes inside an item, so an episode
  /// decodes the same way whichever route delivered it.
  var asDomainEpisode: PodcastEpisode? {
    guard let id else { return nil }
    return PodcastEpisode(
      id: id,
      title: title,
      guid: guid,
      enclosureURL: enclosureURL,
      subtitle: subtitle,
      description: description,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeType: episodeType,
      contentUrl: contentUrl,
      mimeType: mimeType,
      duration: duration,
      size: size,
      publishedAt: publishedAt,
      audioFile: PodcastMedia.validatedAudioFile(from: audioFile))
  }
}

struct RecentEpisodesPageDTO: Decodable {
  let episodes: [RecentEpisodeDTO]

  private enum CodingKeys: String, CodingKey { case episodes }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    episodes = try container.decodeLossyArrayIfPresent(
      forKey: .episodes,
      validating: { $0.libraryItemId != nil && $0.episode.id != nil },
      requiredKey: "libraryItemId")
  }
}

struct RecentEpisodeDTO: Decodable {
  let libraryItemId: String?
  let showTitle: String?
  let showAuthor: String?
  let episode: PodcastEpisodeDTO

  private enum CodingKeys: String, CodingKey { case libraryItemId, podcast }
  private enum PodcastCodingKeys: String, CodingKey { case metadata }
  private enum MetadataCodingKeys: String, CodingKey { case title, author }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    libraryItemId = try container.decodeIfPresent(String.self, forKey: .libraryItemId)
    if let podcast = try? container.nestedContainer(
      keyedBy: PodcastCodingKeys.self, forKey: .podcast),
      let metadata = try? podcast.nestedContainer(
        keyedBy: MetadataCodingKeys.self, forKey: .metadata)
    {
      showTitle = try metadata.decodeBoundedString(forKey: .title)
      showAuthor = try metadata.decodeBoundedString(forKey: .author)
    } else {
      showTitle = nil
      showAuthor = nil
    }
    // The element is itself the episode, so decode from the same container, not a nested one.
    episode = try PodcastEpisodeDTO(from: decoder)
  }
}
