import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The hand-built bodies follow the upstream `Collection.toOldJSONExpanded` /
/// `Playlist.toOldJSONExpanded` shapes. The `current-server-2-35-1-library-*` fixtures are captures
/// from a disposable 2.35.1 server, with ids renamed.
@Suite("Collection and playlist listing endpoints")
struct CollectionPlaylistEndpointTests {

  @Test("collections: path, route template, auth and bounded limit/page")
  func requestsCollections() async throws {
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: emptyPage)])

    _ = try await client.listLibraryCollections(
      account: account, library: "library_book_fixture", limit: 30, page: 2)

    let request = try #require(http.requests.first)
    #expect(request.method == .get)
    #expect(request.url.path == "/api/libraries/library_book_fixture/collections")
    #expect(request.routeTemplate == "/api/libraries/:id/collections")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
    #expect(queryItems(of: request) == ["limit": "30", "page": "2"])
  }

  @Test("playlists: path and route template")
  func requestsPlaylists() async throws {
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: emptyPage)])

    _ = try await client.listLibraryPlaylists(account: account, library: "library_podcast_fixture")

    let request = try #require(http.requests.first)
    #expect(request.url.path == "/api/libraries/library_podcast_fixture/playlists")
    #expect(request.routeTemplate == "/api/libraries/:id/playlists")
    #expect(queryItems(of: request) == ["limit": String(CollectionPlaylistBounds.fallback), "page": "0"])
  }

  @Test(
    "a non-positive limit falls back; an oversized one clamps",
    arguments: [
      (requested: 0, expected: CollectionPlaylistBounds.fallback),
      (requested: -3, expected: CollectionPlaylistBounds.fallback),
      (requested: 10_000, expected: CollectionPlaylistBounds.maximum),
    ])
  func boundsLimit(requested: Int, expected: Int) async throws {
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: emptyPage)])

    _ = try await client.listLibraryCollections(
      account: account, library: "library_book_fixture", limit: requested)

    #expect(queryItems(of: try #require(http.requests.first))["limit"] == String(expected))
  }

  @Test("a collection decodes its book ids in order and ignores the expanded bodies")
  func decodesCollection() async throws {
    let body = page(results: [
      [
        "id": "col_fixture", "libraryId": "library_book_fixture", "name": "Fixture Shelf",
        "description": "Plain text", "lastUpdate": 1_700_000_000_000, "createdAt": 1,
        "books": [expandedBook("li_b"), expandedBook("li_a")],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryCollections(account: account, library: "lib")

    #expect(result.kind == .collection)
    #expect(result.droppedCount == 0)
    #expect(result.total == 1)
    #expect(
      result.lists == [
        LibraryCollectionSummary(
          id: "col_fixture", name: "Fixture Shelf", description: "Plain text",
          lastUpdate: Date(timeIntervalSince1970: 1_700_000_000),
          members: [
            LibraryCollectionMemberReference(serverItemID: "li_b"),
            LibraryCollectionMemberReference(serverItemID: "li_a"),
          ])
      ])
  }

  @Test("a playlist decodes book and episode items, keeping the episode title as a fallback")
  func decodesPlaylist() async throws {
    let body = page(results: [
      [
        "id": "pl_fixture", "libraryId": "lib", "userId": "user_fixture", "name": "Commute",
        "items": [
          [
            "libraryItemId": "li_show", "episodeId": "ep_1",
            "episode": ["id": "ep_1", "title": "Episode One", "audioFile": ["ino": "1"]],
            "libraryItem": ["id": "li_show", "mediaType": "podcast"],
          ],
          ["libraryItemId": "li_book", "libraryItem": expandedBook("li_book")],
        ],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryPlaylists(account: account, library: "lib")

    #expect(result.kind == .playlist)
    #expect(result.droppedCount == 0)
    #expect(
      result.lists.first?.members == [
        LibraryCollectionMemberReference(
          serverItemID: "li_show", serverEpisodeID: "ep_1", fallbackTitle: "Episode One"),
        LibraryCollectionMemberReference(serverItemID: "li_book"),
      ])
  }

  @Test("a missing or blank name stays nil; a long description is cut to the bound")
  func lenientText() async throws {
    let long = String(repeating: "d", count: CollectionPlaylistBounds.maximumDescriptionCharacters + 50)
    let body = page(results: [
      ["id": "a", "books": [], "description": long],
      ["id": "b", "name": "   ", "books": []],
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryCollections(account: account, library: "lib")

    #expect(result.lists.map(\.name) == [nil, nil])
    #expect(result.lists.first?.description?.count == CollectionPlaylistBounds.maximumDescriptionCharacters)
    #expect(result.droppedCount == 0)
  }

  @Test("a list without an id and members without ids are dropped and counted, not silently lost")
  func reportsDrops() async throws {
    let body = page(
      results: [
        ["name": "No id", "books": []],
        ["id": "kept", "books": [expandedBook("li_ok"), ["title": "no id"], "not an object"]],
      ], total: 2)
    let diagnostics = DecodeDiagnostics()
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryCollections(
      account: account, library: "lib", diagnostics: diagnostics)

    #expect(result.lists.map(\.id) == ["kept"])
    #expect(result.lists.first?.members == [LibraryCollectionMemberReference(serverItemID: "li_ok")])
    #expect(result.droppedCount == 3)
    #expect(diagnostics.entries.count == 3)
    #expect(diagnostics.entries.allSatisfy { $0.endpoint == "/api/libraries/:id/collections" })
  }

  @Test("a playlist item without a libraryItemId is dropped and counted")
  func reportsPlaylistMemberDrop() async throws {
    let body = page(results: [
      ["id": "pl", "items": [["episodeId": "ep_orphan"], ["libraryItemId": "li_ok"]]]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryPlaylists(account: account, library: "lib")

    #expect(result.lists.first?.members == [LibraryCollectionMemberReference(serverItemID: "li_ok")])
    #expect(result.droppedCount == 1)
  }

  @Test("members past the per-list bound are cut and counted as dropped")
  func boundsMembers() async throws {
    let extra = 3
    let books = (0..<(CollectionPlaylistBounds.maximumMembersPerList + extra)).map { ["id": "li_\($0)"] }
    let body = page(results: [["id": "big", "books": books]])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: body)])

    let result = try await client.listLibraryCollections(account: account, library: "lib")

    #expect(result.lists.first?.members.count == CollectionPlaylistBounds.maximumMembersPerList)
    #expect(
      result.lists.first?.members.last?.serverItemID == "li_\(CollectionPlaylistBounds.maximumMembersPerList - 1)")
    #expect(result.droppedCount == extra)
  }

  @Test("a captured collections page decodes every list and member in the server's order")
  func decodesCapturedCollections() async throws {
    let result = try await decodeCaptured(
      "current-server-2-35-1-library-collections", kind: .collection)

    #expect(result.droppedCount == 0)
    #expect(result.total == 3)
    #expect(result.lists.map(\.name) == ["Space Opera", "Only Hidden", "Chambers"])
    #expect(
      result.lists.first?.members.map(\.serverItemID)
        == ["li_ancillary_sword", "li_ancillary_justice", "li_hidden_book", "li_the_long_way"])
    #expect(result.lists.first?.description == "Leckie, then Chambers")
    #expect(result.lists.last?.description == nil)
    #expect(result.lists.allSatisfy { $0.lastUpdate != nil })
  }

  @Test("the server's page index is zero-based: limit=1&page=1 is the second list")
  func capturedPageIsZeroBased() async throws {
    let result = try await decodeCaptured(
      "current-server-2-35-1-library-collections-page-1", kind: .collection)

    #expect(result.page == 1)
    #expect(result.limit == 1)
    #expect(result.total == 3)
    #expect(result.lists.map(\.name) == ["Only Hidden"])
  }

  @Test("a captured episode playlist keeps its stored order and each episode's title")
  func decodesCapturedEpisodePlaylist() async throws {
    let result = try await decodeCaptured(
      "current-server-2-35-1-library-playlists-podcast", kind: .playlist)

    #expect(result.droppedCount == 0)
    #expect(
      result.lists.first?.members == [
        LibraryCollectionMemberReference(
          serverItemID: "li_fixture_show", serverEpisodeID: "ep_3", fallbackTitle: "Episode 3"),
        LibraryCollectionMemberReference(
          serverItemID: "li_fixture_show", serverEpisodeID: "ep_1", fallbackTitle: "Episode 1"),
      ])
  }

  /// The server drops a collection whose every book the user cannot see, but still lists a
  /// restricted book inside a collection that holds others. The local catalogue is what hides it.
  @Test("a restricted user's collections still name a book their item listing hides")
  func capturedRestrictedCollectionsStillListHiddenBooks() async throws {
    let result = try await decodeCaptured(
      "current-server-2-35-1-library-collections-restricted", kind: .collection)

    #expect(result.lists.map(\.name) == ["Space Opera", "Chambers"])
    #expect(result.lists.first?.members.map(\.serverItemID).contains("li_hidden_book") == true)
  }

  @Test("an HTTP failure throws rather than returning an empty page")
  func failureThrows() async throws {
    let (client, _, account) = try makeClient(responses: [
      HTTPResponse(statusCode: 500, headers: [:], body: Data())
    ])

    await #expect(throws: (any Error).self) {
      _ = try await client.listLibraryPlaylists(account: account, library: "lib")
    }
  }
}

private func decodeCaptured(
  _ fixture: String, kind: LibraryCollectionKind
) async throws -> LibraryCollectionPage {
  let (client, _, account) = try makeClient(responses: [
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try Fixtures.data(named: fixture))
  ])
  switch kind {
  case .collection: return try await client.listLibraryCollections(account: account, library: "lib")
  case .playlist: return try await client.listLibraryPlaylists(account: account, library: "lib")
  }
}

private var emptyPage: [String: Any] { ["results": [], "total": 0, "limit": 20, "page": 0] }

private func page(results: [[String: Any]], total: Int? = nil) -> [String: Any] {
  ["results": results, "total": total ?? results.count, "limit": 20, "page": 0]
}

/// A trimmed expanded library item: enough nested structure to prove the decoder skips it.
private func expandedBook(_ id: String) -> [String: Any] {
  [
    "id": id, "mediaType": "book",
    "media": [
      "metadata": ["title": "Title \(id)", "authors": [["id": "a", "name": "A"]]],
      "audioFiles": [["ino": "1", "metadata": ["filename": "f.m4b"]]],
      "chapters": [["id": 0, "start": 0, "end": 10, "title": "One"]],
    ],
  ]
}

private func makeClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(responses: responses, serverURL: serverURL)
}

private func jsonResponse(object: Any) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try JSONSerialization.data(withJSONObject: object)
  )
}

private func queryItems(of request: HTTPRequest) -> [String: String] {
  guard let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems else {
    return [:]
  }
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}
