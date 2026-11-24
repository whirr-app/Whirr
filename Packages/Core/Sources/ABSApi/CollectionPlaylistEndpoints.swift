import Foundation

/// `GET /api/libraries/{id}/collections` and `GET /api/libraries/{id}/playlists`.
///
/// Both listings embed every member as an expanded library item. Only member ids (and an episode's
/// title as a fallback label) are modelled; `JSONDecoder` still parses the whole body. Each page
/// reports how many elements it dropped, since a snapshot from a silently lossy page would make
/// that list or member vanish locally.
public enum LibraryCollectionKind: String, Sendable, Equatable, CaseIterable {
  case collection
  case playlist
}

/// One member of a collection or playlist, by server id. A collection member is always a book, so
/// `serverEpisodeID` is nil; a playlist member is a book or a podcast episode.
public struct LibraryCollectionMemberReference: Sendable, Equatable {
  public let serverItemID: String
  public let serverEpisodeID: String?
  /// The episode's title as the server sent it, kept only so an episode the local catalogue has
  /// not seen yet can still be labelled. Nil for books.
  public let fallbackTitle: String?

  public init(serverItemID: String, serverEpisodeID: String? = nil, fallbackTitle: String? = nil) {
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
    self.fallbackTitle = fallbackTitle
  }
}

public struct LibraryCollectionSummary: Sendable, Equatable, Identifiable {
  public let id: String
  /// Nil when the server sent none; the presentation layer supplies the placeholder.
  public let name: String?
  public let description: String?
  public let lastUpdate: Date?
  /// In the server's stored order.
  public let members: [LibraryCollectionMemberReference]

  public init(
    id: String,
    name: String?,
    description: String?,
    lastUpdate: Date?,
    members: [LibraryCollectionMemberReference]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.lastUpdate = lastUpdate
    self.members = members
  }
}

/// One page of either listing. `droppedCount` counts every list and every member that failed to
/// decode, failed its required-id check, or exceeded `CollectionPlaylistBounds`; a caller building
/// a snapshot must treat a non-zero count as an incomplete pass and keep its old rows.
public struct LibraryCollectionPage: Sendable, Equatable {
  public let kind: LibraryCollectionKind
  public let lists: [LibraryCollectionSummary]
  public let total: Int
  public let limit: Int
  public let page: Int
  public let droppedCount: Int

  public init(
    kind: LibraryCollectionKind,
    lists: [LibraryCollectionSummary],
    total: Int,
    limit: Int,
    page: Int,
    droppedCount: Int
  ) {
    self.kind = kind
    self.lists = lists
    self.total = total
    self.limit = limit
    self.page = page
    self.droppedCount = droppedCount
  }
}

/// Page size and stored-row bounds. Every page embeds expanded library items, so the page is kept
/// far smaller than `AuthorSeriesBounds`. The fallback may need tuning against a real server.
public enum CollectionPlaylistBounds {
  public static let fallback = 20
  public static let maximum = 100
  /// Lists one library may hold before the pass is treated as incomplete.
  public static let maximumListsPerLibrary = 2_000
  /// Members one list may hold; a longer list drops the excess and marks the page lossy.
  public static let maximumMembersPerList = 5_000
  public static let maximumDescriptionCharacters = 4_000
  public static let maximumFallbackTitleCharacters = 500
}

extension ABSClient {
  /// `GET /api/libraries/{id}/collections?limit=<n>&page=<p>`. Collections hold books only.
  public func listLibraryCollections(
    account: TokenAccount,
    library libraryID: String,
    limit: Int = CollectionPlaylistBounds.fallback,
    page: Int = 0,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibraryCollectionPage {
    try await listLibraryCollectionPage(
      kind: .collection, account: account, library: libraryID, limit: limit, page: page,
      diagnostics: diagnostics)
  }

  /// `GET /api/libraries/{id}/playlists?limit=<n>&page=<p>`: only the calling user's playlists.
  public func listLibraryPlaylists(
    account: TokenAccount,
    library libraryID: String,
    limit: Int = CollectionPlaylistBounds.fallback,
    page: Int = 0,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> LibraryCollectionPage {
    try await listLibraryCollectionPage(
      kind: .playlist, account: account, library: libraryID, limit: limit, page: page,
      diagnostics: diagnostics)
  }

  private func listLibraryCollectionPage(
    kind: LibraryCollectionKind,
    account: TokenAccount,
    library libraryID: String,
    limit: Int,
    page: Int,
    diagnostics: DecodeDiagnostics?
  ) async throws -> LibraryCollectionPage {
    let tokens = try loadTokens(for: account)
    let boundedLimit =
      limit > 0
      ? min(limit, CollectionPlaylistBounds.maximum) : CollectionPlaylistBounds.fallback
    let segment = kind == .collection ? "collections" : "playlists"
    let routeTemplate = "/api/libraries/:id/\(segment)"

    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/libraries/\(libraryID)/\(segment)",
      queryItems: [
        URLQueryItem(name: "limit", value: String(boundedLimit)),
        URLQueryItem(name: "page", value: String(max(page, 0))),
      ],
      routeTemplate: routeTemplate
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    switch kind {
    case .collection:
      let wire = try decoder.decode(
        CollectionPageDTO.self, from: response.body, endpoint: routeTemplate,
        diagnostics: diagnostics)
      return LibraryCollectionPage(
        kind: kind, lists: wire.page.lists, total: wire.page.total, limit: wire.page.limit,
        page: wire.page.page, droppedCount: wire.page.droppedCount)
    case .playlist:
      let wire = try decoder.decode(
        PlaylistPageDTO.self, from: response.body, endpoint: routeTemplate,
        diagnostics: diagnostics)
      return LibraryCollectionPage(
        kind: kind, lists: wire.page.lists, total: wire.page.total, limit: wire.page.limit,
        page: wire.page.page, droppedCount: wire.page.droppedCount)
    }
  }
}

// MARK: - Wire

/// The decoded body of one page, shared by both kinds. `Member` is the kind's member DTO.
private struct DecodedCollectionPage {
  var lists: [LibraryCollectionSummary] = []
  var total = 0
  var limit = 0
  var page = 0
  var droppedCount = 0
}

private protocol CollectionMemberDTO: Decodable {
  var reference: LibraryCollectionMemberReference? { get }
}

private protocol CollectionListDTO: Decodable {
  associatedtype Member: CollectionMemberDTO
  var id: String? { get }
  var name: String? { get }
  var description: String? { get }
  var lastUpdate: Date? { get }
  var members: [Member] { get }
  var droppedMemberCount: Int { get }
}

private enum PageCodingKeys: String, CodingKey { case results, total, limit, page }

/// One list object reduced to its summary, with the members it lost on the way (undecodable,
/// missing an id, or past `maximumMembersPerList`). Nil when the list has no id.
private func summarize<List: CollectionListDTO>(
  _ list: List
) -> (summary: LibraryCollectionSummary, droppedMemberCount: Int)? {
  guard let id = list.id else { return nil }
  var members = list.members.compactMap(\.reference)
  var dropped = list.droppedMemberCount + (list.members.count - members.count)
  if members.count > CollectionPlaylistBounds.maximumMembersPerList {
    dropped += members.count - CollectionPlaylistBounds.maximumMembersPerList
    members = Array(members.prefix(CollectionPlaylistBounds.maximumMembersPerList))
  }
  return (
    LibraryCollectionSummary(
      id: id, name: list.name, description: list.description, lastUpdate: list.lastUpdate,
      members: members), dropped
  )
}

private func decodePage<List: CollectionListDTO>(
  _ type: List.Type, from decoder: Decoder
) throws -> DecodedCollectionPage {
  let container = try decoder.container(keyedBy: PageCodingKeys.self)
  let decoded = try container.decodeLossyArrayCountingDropped(
    forKey: .results, validating: { (list: List) in list.id != nil }, requiredKey: "id")
  var page = DecodedCollectionPage()
  page.droppedCount = decoded.droppedCount
  for list in decoded.elements {
    guard let (summary, dropped) = summarize(list) else { continue }
    page.droppedCount += dropped
    page.lists.append(summary)
  }
  // The listing omits these when no `limit` was sent; Whirr always sends one, so a missing value
  // is tolerated rather than thrown (rule 21) and the page then cannot claim more pages exist.
  page.total = try container.decode(LossyOptional<Int>.self, forKey: .total).wrappedValue ?? page.lists.count
  page.limit = try container.decode(LossyOptional<Int>.self, forKey: .limit).wrappedValue ?? 0
  page.page = try container.decode(LossyOptional<Int>.self, forKey: .page).wrappedValue ?? 0
  return page
}

private struct CollectionPageDTO: Decodable {
  let page: DecodedCollectionPage
  init(from decoder: Decoder) throws { page = try decodePage(CollectionDTO.self, from: decoder) }
}

private struct PlaylistPageDTO: Decodable {
  let page: DecodedCollectionPage
  init(from decoder: Decoder) throws { page = try decodePage(PlaylistDTO.self, from: decoder) }
}

private enum ListCodingKeys: String, CodingKey {
  case id, name, description, lastUpdate, books, items
}

private func decodeListText(
  _ container: KeyedDecodingContainer<ListCodingKeys>
) throws -> (id: String?, name: String?, description: String?, lastUpdate: Date?) {
  let id = try container.decode(LossyOptional<String>.self, forKey: .id).wrappedValue
  let name = try container.decodeBoundedString(forKey: .name).flatMap { name in
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
  }
  let description = try container.decodeBoundedString(
    forKey: .description, maximumBytes: CollectionPlaylistBounds.maximumDescriptionCharacters * 4
  ).map { String($0.prefix(CollectionPlaylistBounds.maximumDescriptionCharacters)) }
  return (
    id.flatMap { $0.isEmpty ? nil : $0 }, name, description,
    try container.decodeEpochMillisDate(forKey: .lastUpdate)
  )
}

/// `Collection.toOldJSONExpanded`: `books` is a list of full expanded library items, of which only
/// `id` is read.
private struct CollectionDTO: CollectionListDTO {
  let id: String?
  let name: String?
  let description: String?
  let lastUpdate: Date?
  let members: [CollectionBookDTO]
  let droppedMemberCount: Int

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ListCodingKeys.self)
    (id, name, description, lastUpdate) = try decodeListText(container)
    if container.contains(.books) {
      let books = try container.decodeLossyArrayCountingDropped(
        forKey: .books, validating: { (book: CollectionBookDTO) in book.reference != nil },
        requiredKey: "id")
      members = books.elements
      droppedMemberCount = books.droppedCount
    } else {
      members = []
      droppedMemberCount = 0
    }
  }
}

private struct CollectionBookDTO: CollectionMemberDTO {
  let reference: LibraryCollectionMemberReference?

  private enum CodingKeys: String, CodingKey { case id }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(LossyOptional<String>.self, forKey: .id).wrappedValue
    reference = id.flatMap { $0.isEmpty ? nil : LibraryCollectionMemberReference(serverItemID: $0) }
  }
}

/// `Playlist.toOldJSONExpanded`: each item has `libraryItemId`, plus `episodeId` and an expanded
/// `episode` for a podcast episode.
private struct PlaylistDTO: CollectionListDTO {
  let id: String?
  let name: String?
  let description: String?
  let lastUpdate: Date?
  let members: [PlaylistItemDTO]
  let droppedMemberCount: Int

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ListCodingKeys.self)
    (id, name, description, lastUpdate) = try decodeListText(container)
    if container.contains(.items) {
      let items = try container.decodeLossyArrayCountingDropped(
        forKey: .items, validating: { (item: PlaylistItemDTO) in item.reference != nil },
        requiredKey: "libraryItemId")
      members = items.elements
      droppedMemberCount = items.droppedCount
    } else {
      members = []
      droppedMemberCount = 0
    }
  }
}

private struct PlaylistItemDTO: CollectionMemberDTO {
  let reference: LibraryCollectionMemberReference?

  private enum CodingKeys: String, CodingKey { case libraryItemId, episodeId, episode }
  private enum EpisodeKeys: String, CodingKey { case title }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let itemID = try container.decode(LossyOptional<String>.self, forKey: .libraryItemId)
      .wrappedValue
    let episodeID = try container.decode(LossyOptional<String>.self, forKey: .episodeId)
      .wrappedValue.flatMap { $0.isEmpty ? nil : $0 }
    var title: String?
    if episodeID != nil,
      let episode = try? container.nestedContainer(keyedBy: EpisodeKeys.self, forKey: .episode)
    {
      title = try episode.decodeBoundedString(forKey: .title).map {
        String($0.prefix(CollectionPlaylistBounds.maximumFallbackTitleCharacters))
      }
    }
    guard let itemID, itemID.isEmpty == false else {
      reference = nil
      return
    }
    reference = LibraryCollectionMemberReference(
      serverItemID: itemID, serverEpisodeID: episodeID, fallbackTitle: title)
  }
}
