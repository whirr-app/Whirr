import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/libraries/{id}/search?q=<term>&limit=<n>`. `search-book-library-response.json`,
/// `search-podcast-library-response.json` and `malformed-search-hits.json` are hand-built from
/// the research's confirmed field list (`book`/`podcast` keyed hits carrying
/// `libraryItem`/`matchKey`/`matchText`), not captured live.
@Suite("Library search endpoint")
struct SearchEndpointTests {

  @Test("percent-encodes a query containing a space")
  func percentEncodesSpace() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fixture book")

    let rawQuery = try #require(percentEncodedQuery(of: http.requests[0]))
    #expect(rawQuery.contains("q=fixture%20book"))
  }

  @Test("percent-encodes a query containing an ampersand")
  func percentEncodesAmpersand() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fish & chips")

    let rawQuery = try #require(percentEncodedQuery(of: http.requests[0]))
    #expect(rawQuery.contains("q=fish%20%26%20chips"))
  }

  @Test("percent-encodes a non-ASCII query")
  func percentEncodesNonASCII() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "Sigur Rós")

    let rawQuery = try #require(percentEncodedQuery(of: http.requests[0]))
    #expect(rawQuery.contains("q=Sigur%20R%C3%B3s"))
  }

  @Test("rejects an empty query without sending a request")
  func rejectsEmptyQueryWithoutRequest() async throws {
    let (client, http, account) = try makeClient(responses: [])

    await #expect(throws: SearchError.emptyQuery) {
      try await client.searchLibrary(account: account, library: "library_book_fixture", query: "")
    }
    #expect(http.requests.isEmpty)
  }

  @Test("rejects a whitespace-only query without sending a request")
  func rejectsWhitespaceOnlyQueryWithoutRequest() async throws {
    let (client, http, account) = try makeClient(responses: [])

    await #expect(throws: SearchError.emptyQuery) {
      try await client.searchLibrary(account: account, library: "library_book_fixture", query: "  \n\t ")
    }
    #expect(http.requests.isEmpty)
  }

  @Test("requests the default bounded limit when none is supplied")
  func requestsDefaultLimit() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fixture")

    #expect(queryItems(of: http.requests[0])["limit"] == String(SearchBounds.fallback))
  }

  @Test("clamps a non-positive requested limit to the default")
  func clampsNonPositiveLimit() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture", limit: 0
    )

    #expect(queryItems(of: http.requests[0])["limit"] == String(SearchBounds.fallback))
  }

  @Test("clamps an oversized requested limit to the maximum")
  func clampsOversizedLimit() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture", limit: 10_000
    )

    #expect(queryItems(of: http.requests[0])["limit"] == String(SearchBounds.maximum))
  }

  @Test("passes a valid requested limit through unchanged")
  func passesValidLimitThrough() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture", limit: 5
    )

    #expect(queryItems(of: http.requests[0])["limit"] == "5")
  }

  @Test("requests the correct path, method, and bearer auth")
  func requestsCorrectPathAndAuth() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fixture")

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .get)
    #expect(request.url.path == "/api/libraries/library_book_fixture/search")
    #expect(request.routeTemplate == "/api/libraries/:id/search")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
  }

  @Test("decodes a book-library response into book hits, preserving matchKey/matchText")
  func decodesBookLibraryResponse() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture"
    )

    #expect(results.podcastHits.isEmpty)
    #expect(results.bookHits.count == 1)
    let hit = try #require(results.bookHits.first)
    #expect(hit.libraryItem.id == "item_book_fixture")
    #expect(hit.libraryItem.mediaType == "book")
    #expect(hit.matchKey == "title")
    #expect(hit.matchText == "Fixture Book")
  }

  @Test("decodes a podcast-library response into podcast hits, preserving matchKey/matchText")
  func decodesPodcastLibraryResponse() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-podcast-library-response")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_podcast_fixture", query: "fixture"
    )

    #expect(results.bookHits.isEmpty)
    #expect(results.podcastHits.count == 1)
    let hit = try #require(results.podcastHits.first)
    #expect(hit.libraryItem.id == "item_podcast_fixture")
    #expect(hit.libraryItem.mediaType == "podcast")
    #expect(hit.matchKey == "authors")
    #expect(hit.matchText == "Fixture Publisher")
  }

  @Test("skips malformed and required-id-missing hits, recording safe diagnostics")
  func skipsMalformedHits() async throws {
    let malformedHits = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "malformed-search-hits")) as? [Any]
    )
    let envelope: [String: Any] = ["book": malformedHits]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let results = try await client.searchLibrary(
      account: account,
      library: "library_book_fixture",
      query: "fixture",
      diagnostics: diagnostics
    )

    #expect(results.bookHits.map { $0.libraryItem.id } == ["valid-hit-id"])
    let entries = diagnostics.entries
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.endpoint == "/api/libraries/:id/search" })
    // A wrong-typed id now decodes as absent and reports through the `requiredKey` post-filter
    // after the array scan, so entries are ordered structural-first rather than by element index.
    #expect(entries.compactMap(\.elementIndex).sorted() == [1, 2, 3])
    let formatted = entries.map(\.description).joined(separator: "\n")
    for secret in ["wrong-type", "not-an-object", "private-title"] {
      #expect(formatted.contains(secret) == false)
    }
  }

  @Test("drops book, author, and series hits whose ids exceed the string bound")
  func dropsOversizedHitIdentities() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let oversized = String(repeating: "x", count: limit + 1)
    let envelope: [String: Any] = [
      "book": [
        ["libraryItem": ["id": "item_valid_fixture", "mediaType": "book"]],
        ["libraryItem": ["id": oversized, "mediaType": "book"]],
      ],
      "authors": [
        ["id": "author_valid", "name": "Valid Author"],
        ["id": oversized, "name": "Oversized Author"],
      ],
      "series": [
        ["series": ["id": "series_valid", "name": "Valid Series"], "books": []],
        ["series": ["id": oversized, "name": "Oversized Series"], "books": []],
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture"
    )

    #expect(results.bookHits.map { $0.libraryItem.id } == ["item_valid_fixture"])
    #expect(results.authorHits.map(\.id) == ["author_valid"])
    #expect(results.seriesHits.map(\.id) == ["series_valid"])
  }

  enum SearchArrayBucket: String, CaseIterable {
    case book, podcast, authors, series, tags
  }

  @Test(
    "throws when a present search array bucket has the wrong top-level type",
    arguments: SearchArrayBucket.allCases
  )
  func throwsForWrongTypeSearchArrayBucket(bucket: SearchArrayBucket) async throws {
    var envelope: [String: Any] = [
      "book": [],
      "podcast": [],
      "authors": [],
      "series": [],
      "tags": [],
    ]
    envelope[bucket.rawValue] = "not-an-array"
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.searchLibrary(
        account: account, library: "library_book_fixture", query: "fixture")
    }
  }

  @Test(
    "treats an absent or null search array bucket as empty",
    arguments: SearchArrayBucket.allCases, [false, true]
  )
  func treatsMissingOrNullSearchArrayBucketAsEmpty(
    bucket: SearchArrayBucket, isNull: Bool
  ) async throws {
    var envelope: [String: Any] = [
      "book": [],
      "podcast": [],
      "authors": [],
      "series": [],
      "tags": [],
    ]
    if isNull {
      envelope[bucket.rawValue] = NSNull()
    } else {
      envelope.removeValue(forKey: bucket.rawValue)
    }
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture")

    #expect(results.bookHits.isEmpty)
    #expect(results.podcastHits.isEmpty)
    #expect(results.authorHits.isEmpty)
    #expect(results.seriesHits.isEmpty)
  }

  // MARK: - Author/series buckets, tags-decoded-but-hidden, real `limit`

  /// Every real series hit is wrapped (`{"series": {...}, "books": [...]}`), as the live 2.35.1
  /// capture (`search-full-buckets.json`) shows, so this builds the wrapped shape.
  @Test("decodes author and series buckets into navigable hits")
  func decodesAuthorAndSeriesBuckets() async throws {
    let envelope: [String: Any] = [
      "book": [],
      "podcast": [],
      "tags": ["Fixture Tag"],
      "authors": [
        ["id": "author_fixture", "asin": "B0FIXTURE", "name": "Fixture Author", "numBooks": 3]
      ],
      "series": [
        [
          "series": ["id": "series_fixture", "name": "Fixture Series", "nameIgnorePrefix": "Fixture Series"],
          "books": [["id": "book_in_series_fixture"]],
        ]
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture"
    )

    #expect(results.authorHits == [SearchAuthorHit(id: "author_fixture", name: "Fixture Author")])
    #expect(
      results.seriesHits == [
        SearchSeriesHit(id: "series_fixture", name: "Fixture Series", bookCount: 1)
      ]
    )
  }

  // MARK: - Live 2.35.1 capture fixtures (search-full-buckets*.json)
  // The fixtures keep the capture's exact JSON shape (keys, nulls, types, array lengths) with
  // every title, name, id, inode, path and size replaced by synthetic values.

  /// A decode that reads a top-level `id` drops every wrapped `series` element at the
  /// `requiredKey: "id"` filter, leaving `seriesHits` empty. `SearchSeriesHitDTO` must read
  /// `series.id`/`series.name` from the nested object so both series hits decode.
  @Test("decodes the live full-buckets fixture: 2 book hits, 2 wrapped series hits, no matchKey/matchText")
  func decodesLiveFullBucketsFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-full-buckets")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_fixture", query: "fixture"
    )

    #expect(results.bookHits.count == 2)
    for hit in results.bookHits {
      #expect(hit.libraryItem.id.isEmpty == false)
      #expect(hit.matchKey == nil)
      #expect(hit.matchText == nil)
    }

    #expect(results.seriesHits.count == 2)
    for hit in results.seriesHits {
      #expect(hit.id.isEmpty == false)
      #expect(hit.name?.isEmpty == false)
    }
  }

  @Test("decodes the live authors fixture: 3 book hits, 1 author hit")
  func decodesLiveAuthorsFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-full-buckets-authors")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_fixture", query: "fixture"
    )

    #expect(results.bookHits.count == 3)
    #expect(results.authorHits.count == 1)
    let author = try #require(results.authorHits.first)
    #expect(author.id.isEmpty == false)
    #expect(author.name?.isEmpty == false)
  }

  @Test("decodes the live podcast fixture: 1 podcast hit, genres/tags/episodes ignored without error")
  func decodesLivePodcastFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-full-buckets-podcast")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_fixture", query: "fixture"
    )

    #expect(results.podcastHits.count == 1)
    let hit = try #require(results.podcastHits.first)
    #expect(hit.libraryItem.mediaType == "podcast")
    #expect(results.bookHits.isEmpty)
  }

  enum MalformedSeriesSubobjectState: String, CaseIterable {
    case absent, null, wrongType
  }

  @Test(
    "a wrapped series element with a missing/null/wrong-typed `series` subobject drops only that element",
    arguments: MalformedSeriesSubobjectState.allCases
  )
  func malformedWrappedSeriesElementDropsOnlyThatElement(
    state: MalformedSeriesSubobjectState
  ) async throws {
    var seriesElement: [String: Any] = [
      "books": [["id": "book_in_series_fixture"]]
    ]
    switch state {
    case .absent:
      break
    case .null:
      seriesElement["series"] = NSNull()
    case .wrongType:
      seriesElement["series"] = "not-an-object"
    }

    let envelope: [String: Any] = [
      "book": [
        [
          "libraryItem": ["id": "item_book_fixture", "mediaType": "book"]
        ]
      ],
      "podcast": [],
      "tags": [],
      "authors": [],
      "series": [
        seriesElement,
        [
          "series": ["id": "series_fixture", "name": "Fixture Series"],
          "books": [],
        ],
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture"
    )

    #expect(results.bookHits.map(\.libraryItem.id) == ["item_book_fixture"])
    #expect(results.seriesHits == [SearchSeriesHit(id: "series_fixture", name: "Fixture Series", bookCount: 0)])
  }

  enum MalformedBucketState: String, CaseIterable {
    case absent, null, wrongType, malformedElement
  }

  @Test(
    "book/podcast hits remain intact when an authors or series bucket is absent, null, or malformed",
    arguments: ["authors", "series"], MalformedBucketState.allCases
  )
  func keepsItemsWhenAuthorOrSeriesBucketIsMalformed(
    bucket: String, state: MalformedBucketState
  ) async throws {
    var envelope: [String: Any] = [
      "book": [
        [
          "libraryItem": ["id": "item_book_fixture", "mediaType": "book"],
          "matchKey": "title",
          "matchText": "Fixture Book",
        ]
      ],
      "podcast": [
        [
          "libraryItem": ["id": "item_podcast_fixture", "mediaType": "podcast"],
          "matchKey": "authors",
          "matchText": "Fixture Publisher",
        ]
      ],
      "tags": [],
      "authors": [],
      "series": [],
    ]

    switch state {
    case .absent:
      envelope.removeValue(forKey: bucket)
    case .null:
      envelope[bucket] = NSNull()
    case .wrongType:
      envelope[bucket] = "not-an-array"
    case .malformedElement:
      envelope[bucket] = [["name": "missing-id"]]
    }

    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    if state == .wrongType {
      await #expect(throws: APIError.decoding) {
        try await client.searchLibrary(
          account: account, library: "library_book_fixture", query: "fixture")
      }
      return
    }

    let results = try await client.searchLibrary(
      account: account, library: "library_book_fixture", query: "fixture"
    )

    #expect(results.bookHits.map(\.libraryItem.id) == ["item_book_fixture"])
    #expect(results.podcastHits.map(\.libraryItem.id) == ["item_podcast_fixture"])
    #expect(results.authorHits.isEmpty)
    #expect(results.seriesHits.isEmpty)
  }

  @Test("existing book/podcast fixtures still decode, with the new author/series buckets empty")
  func existingFixturesStillDecode() async throws {
    let (bookClient, _, bookAccount) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )
    let bookResults = try await bookClient.searchLibrary(
      account: bookAccount, library: "library_book_fixture", query: "fixture"
    )
    #expect(bookResults.bookHits.count == 1)
    #expect(bookResults.authorHits.isEmpty)
    #expect(bookResults.seriesHits.isEmpty)

    let (podcastClient, _, podcastAccount) = try makeClient(
      responses: [jsonResponse(named: "search-podcast-library-response")]
    )
    let podcastResults = try await podcastClient.searchLibrary(
      account: podcastAccount, library: "library_podcast_fixture", query: "fixture"
    )
    #expect(podcastResults.podcastHits.count == 1)
    #expect(podcastResults.authorHits.isEmpty)
    #expect(podcastResults.seriesHits.isEmpty)
  }

  @Test(
    "limit is forwarded to the query string and bounded: 0/negative falls back to 25, above maximum clamps to 100",
    arguments: [
      (requested: nil as Int?, expected: "25"),
      (requested: 0, expected: "25"),
      (requested: -5, expected: "25"),
      (requested: 40, expected: "40"),
      (requested: 10_000, expected: "100"),
    ]
  )
  func limitIsForwardedAndBounded(_ scenario: (requested: Int?, expected: String)) async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "search-book-library-response")]
    )

    if let requested = scenario.requested {
      _ = try await client.searchLibrary(
        account: account, library: "library_book_fixture", query: "fixture", limit: requested
      )
    } else {
      _ = try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fixture")
    }

    #expect(queryItems(of: http.requests[0])["limit"] == scenario.expected)
  }

  @Test("rejects an oversized response per bounds")
  func rejectsOversizedResponse() async throws {
    let oversized = Data(repeating: 0x61, count: 26 * 1024 * 1024)
    let (client, _, account) = try makeClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: oversized)
      ]
    )

    await #expect(throws: APIError.payloadTooLarge) {
      try await client.searchLibrary(account: account, library: "library_book_fixture", query: "fixture")
    }
  }
}

private func makeClient(
  responses: [HTTPResponse]
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(responses: responses, serverURL: serverURL)
}

private func jsonResponse(named name: String) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try Fixtures.data(named: name)
  )
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

private func percentEncodedQuery(of request: HTTPRequest) -> String? {
  URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
}
