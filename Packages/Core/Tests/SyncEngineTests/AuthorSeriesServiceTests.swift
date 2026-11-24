import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `AuthorSeriesService`, the production `AuthorSeriesReading` conformance. `entity` resolves an
/// author/series display name from the library filter index; `items` reuses the paginated
/// `/api/libraries/{id}/items?filter=authors|series.<id>` route, not the listing's embedded
/// `books[]`.
@Suite struct AuthorSeriesServiceTests {

  @Test("authors and series share one complete filter-data snapshot")
  func authorsAndSeriesShareSnapshot() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [["id": "author-1", "name": "Fixture Author"]],
          "series": [["id": "series-1", "name": "Fixture Series"]],
        ]))

    let authors = try await harness.service.entities(
      kind: .author, libraryID: nil, limit: 50, offset: 0)
    let series = try await harness.service.entities(
      kind: .series, libraryID: nil, limit: 50, offset: 0)

    #expect(authors.entities.map(\.name) == ["Fixture Author"])
    #expect(series.entities.map(\.name) == ["Fixture Series"])
    #expect(harness.http.requests.map(\.url.path) == ["/api/libraries/lib1/filterdata"])
  }

  @Test("authors browse uses the complete library filter index")
  func browsesAuthors() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [
            ["id": "author-1", "name": "Fixture Author"],
            ["id": "author-2", "name": "Other Author"],
          ]
        ]))

    let page = try await harness.service.entities(kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(
      page.entities
        == [
          AuthorSeriesEntity(
            kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib1"),
          AuthorSeriesEntity(
            kind: .author, entityID: "author-2", name: "Other Author", libraryID: "lib1"),
        ])
    #expect(page.hasMore == false)
    #expect(harness.http.requests.first?.url.path == "/api/libraries/lib1/filterdata")
  }

  @Test("series browse uses the complete library filter index")
  func browsesSeries() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [],
          "series": [["id": "series-1", "name": "Fixture Series"]],
        ]))

    let page = try await harness.service.entities(kind: .series, libraryID: nil, limit: 50, offset: 0)

    #expect(
      page.entities
        == [
          AuthorSeriesEntity(
            kind: .series, entityID: "series-1", name: "Fixture Series", libraryID: "lib1")
        ])
    #expect(page.hasMore == false)
    #expect(harness.http.requests.first?.url.path == "/api/libraries/lib1/filterdata")
  }

  /// Resolved from the same complete filter index the browse rows are built from, not from the
  /// dedicated authors route: that route has no id filter, so a bounded lookup page could not see
  /// an author past it, and it can only ever answer for one library.
  @Test("resolves an author entity's name from the library filter index")
  func resolvesAuthorEntity() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [
            ["id": "author-1", "name": "Fixture Author", "numBooks": 3],
            ["id": "author-2", "name": "Other Author"],
          ],
          "series": [],
        ]))

    let entity = try await harness.service.entity(kind: .author, entityID: "author-1")

    #expect(
      entity
        == AuthorSeriesEntity(
          kind: .author, entityID: "author-1", name: "Fixture Author", libraryID: "lib1",
          bookCount: 3))
    #expect(harness.http.requests.first?.url.path == "/api/libraries/lib1/filterdata")
  }

  @Test("uses the search hit's library instead of the account default library")
  func usesSearchHitLibrary() async throws {
    let harness = try await Harness(defaultLibraryId: "audiobooks")
    // The requested library is read first, then the account's own. The hit resolves in the
    // library it was found in even when that library holds nothing else the reader has synced.
    harness.http.enqueue(
      Harness.jsonResponse(
        object: ["authors": [["id": "author-ebook", "name": "Ebook Author"]], "series": []]))
    harness.http.enqueue(Harness.jsonResponse(object: ["authors": [], "series": []]))
    harness.http.enqueue(
      Harness.jsonResponse(
        object: ["results": [], "total": 0, "limit": 50, "page": 0]))

    let entity = try await harness.service.entity(
      kind: .author, entityID: "author-ebook", libraryID: "ebooks")
    _ = try await harness.service.items(
      kind: .author, entityID: "author-ebook", libraryID: "ebooks", limit: 50, offset: 0)

    #expect(entity?.libraryID == "ebooks")
    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/libraries/ebooks/filterdata", "/api/libraries/audiobooks/filterdata",
        "/api/libraries/ebooks/items",
      ])
  }

  @Test("resolves a series entity's name from the library filter index")
  func resolvesSeriesEntity() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [],
          "series": [["id": "series-1", "name": "Fixture Series"]],
        ]))

    let entity = try await harness.service.entity(kind: .series, entityID: "series-1")

    #expect(
      entity
        == AuthorSeriesEntity(kind: .series, entityID: "series-1", name: "Fixture Series", libraryID: "lib1"))
    #expect(harness.http.requests.first?.url.path == "/api/libraries/lib1/filterdata")
  }

  @Test("a semantic name resolves case-insensitively to the entity's current ids")
  func resolvesEntityBySemanticName() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [["id": "author-1", "name": "Matt Dinniman"]],
          "series": [],
        ]))

    let entity = try await harness.service.entity(kind: .author, named: "matt dinniman")

    #expect(entity?.entityID == "author-1")
    #expect(entity?.name == "Matt Dinniman")
  }

  @Test("an entity id absent from the fetched page resolves to nil rather than throwing")
  func entityNotFoundResolvesToNil() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.jsonResponse(object: ["authors": []]))

    let entity = try await harness.service.entity(kind: .author, entityID: "missing")

    #expect(entity == nil)
  }

  @Test("items() fetches the entity's books through the existing paginated items filter")
  func itemsFetchesThroughItemsFilter() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "book-1", "libraryId": "lib1", "mediaType": "book",
              "media": ["metadata": ["title": "Book One", "authorName": "Fixture Author"]],
            ]
          ],
          "total": 5,
          "limit": 1,
          "page": 0,
        ]))

    let page = try await harness.service.items(kind: .author, entityID: "author-1", limit: 1, offset: 0)

    #expect(
      page.rows
        == [
          SearchResultRow(
            kind: .book, entityID: "book-1", title: "Book One", subtitle: "Fixture Author",
            // Neither audio-file count nor ebook format is present on this fixture, so the
            // derivation lands on its own audiobook default rather than on "unknown".
            mediaCategory: .audiobook, libraryID: "lib1")
        ])
    #expect(page.hasMore)
    let request = try #require(harness.http.requests.first)
    #expect(request.url.path == "/api/libraries/lib1/items")
    let query = Dictionary(
      uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
    #expect(query["filter"] == LibraryItemFilter(group: "authors", value: "author-1").queryValue)
  }

  @Test("items() forwards a series entity id under the series filter group")
  func itemsUsesSeriesFilterGroup() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(object: ["results": [], "total": 0, "limit": 50, "page": 0]))

    _ = try await harness.service.items(kind: .series, entityID: "series-1", limit: 50, offset: 0)

    let request = try #require(harness.http.requests.first)
    let query = Dictionary(
      uniqueKeysWithValues: (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
    #expect(query["filter"] == LibraryItemFilter(group: "series", value: "series-1").queryValue)
  }

  @Test("narrator items use the narrator-name filter and retain the credit on each row")
  func narratorItemsUseNameFilter() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "book-1", "libraryId": "lib1", "mediaType": "book",
              "media": ["metadata": ["title": "Book One", "authorName": "Fixture Author"]],
            ]
          ],
          "total": 1,
          "limit": 50,
          "page": 0,
        ]))

    let page = try await harness.service.items(
      narratorName: "Jeff Hays", libraryID: "lib1", limit: 50, offset: 0)

    let request = try #require(harness.http.requests.first)
    #expect(
      Self.query(request.url)["filter"]
        == LibraryItemFilter(group: "narrators", value: "Jeff Hays").queryValue)
    #expect(page.rows.first?.narratorName == "Jeff Hays")
  }

  @Test("items() maps a podcast item's mediaType to the podcast kind")
  func itemsMapsPodcastMediaType() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "podcast-1", "libraryId": "lib1", "mediaType": "podcast",
              "media": ["metadata": ["title": "A Show"]],
            ]
          ],
          "total": 1,
          "limit": 50,
          "page": 0,
        ]))

    let page = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(page.rows.first?.kind == .podcast)
  }

  /// The author/series screen renders the same rows as Search (a media badge and the series
  /// line), both from fields the minified items route returns. Without them every row is a title
  /// over a repeated author name.
  @Test("items() carries each row's media category, series line, and audiobook duration")
  func itemsCarryCategorySeriesAndDuration() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "audiobook-1", "libraryId": "lib1", "mediaType": "book",
              "updatedAt": 1_790_000_000_123,
              "media": [
                "metadata": ["title": "Leviathan Wakes", "seriesName": "The Expanse #1"],
                "numAudioFiles": 24,
                "duration": 72_610,
              ],
            ],
            [
              "id": "ebook-1", "libraryId": "lib1", "mediaType": "book",
              "media": [
                "metadata": ["title": "Caliban's War", "seriesName": "The Expanse #2"],
                "ebookFormat": "epub",
              ],
            ],
          ],
          "total": 2,
          "limit": 50,
          "page": 0,
        ]))

    let page = try await harness.service.items(kind: .series, entityID: "series-1", limit: 50, offset: 0)

    #expect(page.rows.map(\.mediaCategory) == [.audiobook, .ebook])
    #expect(page.rows.map(\.seriesName) == ["The Expanse #1", "The Expanse #2"])
    #expect(page.rows.map(\.durationSeconds) == [72_610, nil])
    // The cover revision must match the one a persisted row of the same item produces.
    #expect(
      page.rows.map { ArtworkRevision(serverUpdatedAt: $0.serverUpdatedAt) }
        == [ArtworkRevision("1790000000123"), .unversioned])
  }

  /// `sequence` is only a valid sort while filtering by series, which is the case here. Without
  /// it a series' second page can arrive before its first book.
  @Test("a series listing is sorted by sequence, and an author listing is not")
  func seriesListingSortsBySequence() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(object: ["results": [], "total": 0, "limit": 50, "page": 0]))
    harness.http.enqueue(
      Harness.jsonResponse(object: ["results": [], "total": 0, "limit": 50, "page": 0]))

    _ = try await harness.service.items(kind: .series, entityID: "series-1", limit: 50, offset: 0)
    _ = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(Self.query(harness.http.requests[0].url)["sort"] == "sequence")
    #expect(Self.query(harness.http.requests[1].url)["sort"] == nil)
  }

  private static func query(_ url: URL) -> [String: String] {
    Dictionary(
      uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
  }

  @Test("a non-positive offset/limit ratio still requests the first server page")
  func firstPageRequestsServerPageZero() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(object: ["results": [], "total": 0, "limit": 50, "page": 0]))

    _ = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    let query = Dictionary(
      uniqueKeysWithValues: (URLComponents(
        url: try #require(harness.http.requests.first?.url), resolvingAgainstBaseURL: false
      )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["page"] == "0")
  }

  @Test("a page-aligned offset maps to the matching server page")
  func pageAlignedOffsetRequestsMatchingPage() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(object: ["results": [], "total": 101, "limit": 50, "page": 2]))

    _ = try await harness.service.items(
      kind: .author, entityID: "author-1", limit: 50, offset: 100)

    let request = try #require(harness.http.requests.first)
    let query = Self.query(request.url)
    #expect(query["page"] == "2")
    #expect(query["limit"] == "50")
  }

  @Test("a non-multiple offset is rejected instead of re-fetching an earlier page")
  func rejectsNonMultipleOffset() async throws {
    let harness = try await Harness()

    let page = try await harness.service.items(
      kind: .author, entityID: "author-1", limit: 50, offset: 25)

    #expect(page.rows.isEmpty)
    #expect(page.hasMore == false)
    #expect(harness.http.requests.isEmpty, "an invalid cursor must not reach the server")
  }

  @Test("a request failure returns nil/empty rather than throwing or crashing")
  func fetchFailureReturnsNilOrEmpty() async throws {
    let harness = try await Harness()
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    let entity = try await harness.service.entity(kind: .author, entityID: "author-1")
    let page = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(entity == nil)
    #expect(page.rows.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("no signed-in account returns nil/empty rather than throwing or crashing")
  func noAccountReturnsNilOrEmpty() async throws {
    let database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: InMemoryTokenStore())
    let service = AuthorSeriesService(database: database, client: client)

    let entity = try await service.entity(kind: .author, entityID: "author-1")
    let page = try await service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(entity == nil)
    #expect(page.rows.isEmpty)
    #expect(page.hasMore == false)
  }

  @Test("an account with no default library returns nil/empty rather than throwing or crashing")
  func noDefaultLibraryReturnsNilOrEmpty() async throws {
    let harness = try await Harness(defaultLibraryId: nil)

    let entity = try await harness.service.entity(kind: .author, entityID: "author-1")
    let page = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(entity == nil)
    #expect(page.rows.isEmpty)
    #expect(page.hasMore == false)
    #expect(harness.http.requests.isEmpty)
  }

  @Test("an excluded default-library hint never bootstraps author or series requests")
  func excludedDefaultLibraryDoesNotBootstrapRequests() async throws {
    let harness = try await Harness(defaultLibraryId: "legacy-default")
    try await harness.setLibraryIncluded(false, libraryID: "legacy-default")

    let entity = try await harness.service.entity(kind: .author, entityID: "author-1")
    let page = try await harness.service.items(kind: .author, entityID: "author-1", limit: 50, offset: 0)

    #expect(entity == nil)
    #expect(page.rows.isEmpty)
    #expect(harness.http.requests.isEmpty)
  }

  // MARK: - An entity that spans libraries

  @Test("one author held in two libraries is one entity carrying both ids")
  func mergesEntitiesAcrossLibraries() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([(id: "audiobooks", mediaType: "book"), (id: "ebooks", mediaType: "book")])
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [["id": "author-audio", "name": "Alexandre Dumas", "numBooks": 1]],
          "series": [],
        ]))
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [["id": "author-ebook", "name": "Alexandre Dumas", "numBooks": 2]],
          "series": [],
        ]))

    let page = try await harness.service.entities(
      kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(page.entities.count == 1, "the same author in two libraries is one row, not two")
    #expect(
      page.entities.first?.identities == [
        AuthorSeriesEntity.Identity(entityID: "author-audio", libraryID: "audiobooks"),
        AuthorSeriesEntity.Identity(entityID: "author-ebook", libraryID: "ebooks"),
      ])
    #expect(page.entities.first?.bookCount == 3, "the shelf is the sum of both libraries")
    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/libraries/audiobooks/filterdata", "/api/libraries/ebooks/filterdata",
      ])
  }

  /// Audiobookshelf files an author per name string, so a library whose book metadata spells the
  /// same initials two ways holds two author records (the Library tab's split rows), each with
  /// half of the same series.
  @Test("two spellings of one author in one library are one entity carrying both ids")
  func mergesSpellingVariantsWithinOneLibrary() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([(id: "audiobooks", mediaType: "book")])
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "authors": [
            ["id": "author-spaced", "name": "J. N. Chaney", "numBooks": 2],
            ["id": "author-tight", "name": "J.N. Chaney", "numBooks": 2],
          ],
          "series": [],
        ]))

    let page = try await harness.service.entities(
      kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(page.entities.count == 1, "one author spelled two ways is one row")
    #expect(
      page.entities.first?.identities == [
        AuthorSeriesEntity.Identity(entityID: "author-spaced", libraryID: "audiobooks"),
        AuthorSeriesEntity.Identity(entityID: "author-tight", libraryID: "audiobooks"),
      ])
    #expect(page.entities.first?.bookCount == 4, "the shelf is both spellings' books")
  }

  @Test("either spelling's id resolves the merged author")
  func spellingVariantIDsBothResolve() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([(id: "audiobooks", mediaType: "book")])
    let filterData = Harness.jsonResponse(
      object: [
        "authors": [
          ["id": "author-spaced", "name": "J. N. Chaney", "numBooks": 2],
          ["id": "author-tight", "name": "J.N. Chaney", "numBooks": 2],
        ],
        "series": [],
      ])
    harness.http.enqueue(filterData)

    let entity = try await harness.service.entity(kind: .author, entityID: "author-tight")

    #expect(entity?.identities.map(\.entityID) == ["author-tight", "author-spaced"])
    #expect(entity?.bookCount == 4)
  }

  @Test("a podcast library is never asked for authors or series")
  func skipsPodcastLibraries() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([(id: "books", mediaType: "book"), (id: "shows", mediaType: "podcast")])
    harness.http.enqueue(
      Harness.jsonResponse(object: ["authors": [["id": "a", "name": "Author"]], "series": []]))

    _ = try await harness.service.entities(kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(harness.http.requests.map(\.url.path) == ["/api/libraries/books/filterdata"])
  }

  @Test("an excluded book library is neither refreshed nor returned")
  func excludesLibraryFromFilterDataFanOutAndEntities() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([
      (id: "included", mediaType: "book"),
      (id: "excluded", mediaType: "book"),
    ])
    try await harness.setLibraryIncluded(false, libraryID: "excluded")
    harness.http.enqueue(
      Harness.jsonResponse(object: [
        "authors": [["id": "included-author", "name": "Included Author"]], "series": [],
      ]))

    let page = try await harness.service.entities(
      kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(page.entities.map(\.name) == ["Included Author"])
    #expect(harness.http.requests.map(\.url.path) == ["/api/libraries/included/filterdata"])
  }

  @Test("one unreachable library does not blank the other's entities")
  func survivesOneLibraryFailing() async throws {
    let harness = try await Harness(defaultLibraryId: nil)
    try await harness.seedLibraries([(id: "broken", mediaType: "book"), (id: "books", mediaType: "book")])
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    harness.http.enqueue(
      Harness.jsonResponse(object: ["authors": [["id": "a", "name": "Author"]], "series": []]))

    let page = try await harness.service.entities(
      kind: .author, libraryID: nil, limit: 50, offset: 0)

    #expect(page.entities.map(\.name) == ["Author"])
  }

  @Test("a single-identity author page preserves the server row order")
  func preservesSingleIdentityServerOrder() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            ["id": "standalone-z", "media": ["metadata": ["title": "Zoo"]]],
            [
              "id": "children-2",
              "media": ["metadata": ["title": "Children of Ruin", "seriesName": "Children of Time #2"]],
            ],
            [
              "id": "expert-1",
              "media": ["metadata": ["title": "The Expert System's Brother", "seriesName": "Expert System #1"]],
            ],
            [
              "id": "children-1",
              "media": ["metadata": ["title": "Children of Time", "seriesName": "Children of Time #1"]],
            ],
            ["id": "standalone-a", "media": ["metadata": ["title": "Alien Clay"]]],
            [
              "id": "children-3",
              "media": ["metadata": ["title": "Children of Memory", "seriesName": "Children of Time #3"]],
            ],
          ],
          "total": 6, "limit": 50, "page": 0,
        ]))

    let page = try await harness.service.items(
      kind: .author, entityID: "author-1", libraryID: "books", limit: 50, offset: 0)

    #expect(
      page.rows.map(\.entityID) == [
        "standalone-z", "children-2", "expert-1", "children-1", "standalone-a", "children-3",
      ])
  }

  /// Minimal single-account harness.
  private final class Harness: @unchecked Sendable {
    let http: FakeHTTPClient
    let service: AuthorSeriesService
    let database: AppDatabase
    let accountID: Int64

    init(defaultLibraryId: String? = "lib1") async throws {
      let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
      let tokenStore = InMemoryTokenStore()

      http = FakeHTTPClient()
      let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

      database = try AppDatabase.inMemory()
      let accountRecord = try await database.writeAsync { db in
        var record = AccountRecord(
          clientUUID: UUID().uuidString,
          serverBaseURL: server.baseURL.absoluteString,
          serverUserId: "user_fixture",
          serverVersion: "2.35.1",
          defaultLibraryId: defaultLibraryId
        )
        try record.save(db)
        return record
      }
      try tokenStore.save(
        TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
        for: try accountRecord.credentialTokenAccount)
      accountID = try #require(accountRecord.id)
      if let defaultLibraryId {
        try await database.writeAsync { [accountID] db in
          var library = LibraryRecord(
            accountId: accountID, serverLibraryId: defaultLibraryId, mediaType: "book",
            name: defaultLibraryId, isIncluded: true)
          try library.insert(db)
        }
      }

      service = AuthorSeriesService(database: database, client: client)
    }

    /// Records the reader's synced libraries, which is what makes the entity listing cross more
    /// than the account's default library.
    func seedLibraries(_ libraries: [(id: String, mediaType: String)]) async throws {
      try await database.writeAsync { [accountID] db in
        for library in libraries {
          var record = LibraryRecord(
            accountId: accountID, serverLibraryId: library.id, mediaType: library.mediaType,
            name: library.id)
          try record.save(db)
        }
      }
    }

    func setLibraryIncluded(_ included: Bool, libraryID: String) async throws {
      try await database.writeAsync { [accountID] db in
        try db.execute(
          sql: "UPDATE library SET isIncluded = ? WHERE accountId = ? AND serverLibraryId = ?",
          arguments: [included, accountID, libraryID])
      }
    }

    static func jsonResponse(object: Any) -> HTTPResponse {
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)
      )
    }
  }
}
