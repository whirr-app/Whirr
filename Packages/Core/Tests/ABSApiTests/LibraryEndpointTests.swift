import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Page-fetch primitives only; traversal belongs to the sync layer. Filter-string encoding is
/// covered in `FilterStringTests`.
@Suite("Library and item-list endpoints")
struct LibraryEndpointTests {

  @Test("listing libraries throws unauthorized when no tokens are stored for the account")
  func listingLibrariesWithoutStoredTokensThrowsUnauthorized() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: InMemoryTokenStore())

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.listLibraries(account: account)
    }
  }

  @Test("decodes book and podcast libraries from the unfiltered libraries list")
  func decodesBookAndPodcastLibraries() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "libraries-response")]
    )

    let libraries = try await client.listLibraries(account: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/libraries")
    #expect(http.requests[0].routeTemplate == "/api/libraries")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")
    #expect(libraries.map(\.id) == ["library_book_fixture", "library_podcast_fixture", "library_book_extra_fixture"])
    #expect(libraries.map(\.mediaType) == ["book", "podcast", "book"])
  }

  @Test("decodes the Continue Series setting and treats absent, null, and wrong types as false")
  func decodesContinueSeriesSettingLossily() async throws {
    let envelope: [String: Any] = [
      "libraries": [
        [
          "id": "library_true", "name": "True", "mediaType": "book",
          "settings": ["onlyShowLaterBooksInContinueSeries": true],
        ],
        [
          "id": "library_false", "name": "False", "mediaType": "book",
          "settings": ["onlyShowLaterBooksInContinueSeries": false],
        ],
        ["id": "library_absent", "name": "Absent", "mediaType": "book"],
        [
          "id": "library_null", "name": "Null", "mediaType": "book",
          "settings": ["onlyShowLaterBooksInContinueSeries": NSNull()],
        ],
        [
          "id": "library_wrong_type", "name": "Wrong type", "mediaType": "book",
          "settings": ["onlyShowLaterBooksInContinueSeries": "true"],
        ],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let libraries = try await client.listLibraries(account: account)

    #expect(libraries.map(\.onlyShowLaterBooksInContinueSeries) == [true, false, false, false, false])
  }

  @Test("requests library items with bounded limit, zero-indexed page, minified=1, and sort")
  func requestsCarryBoundedPaginationAndSort() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(
      account: account,
      library: "library_book_fixture",
      page: 3,
      limit: 40,
      sort: "media.metadata.title"
    )

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .get)
    #expect(request.url.path == "/api/libraries/library_book_fixture/items")
    #expect(request.routeTemplate == "/api/libraries/:id/items")
    let query = queryItems(of: request)
    #expect(query["limit"] == "40")
    #expect(query["page"] == "3")
    #expect(query["minified"] == "1")
    #expect(query["sort"] == "media.metadata.title")
  }

  @Test("omits the sort query item when no sort is requested")
  func omitsSortWhenNotRequested() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    let query = queryItems(of: http.requests[0])
    #expect(query.keys.contains("sort") == false)
  }

  @Test("omits the filter query item when no filter is requested")
  func omitsFilterWhenNotRequested() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    let query = queryItems(of: http.requests[0])
    #expect(query.keys.contains("filter") == false)
  }

  @Test("carries a supplied filter as the encoded query item, decoded round-trip")
  func carriesFilterQueryItem() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(
      account: account,
      library: "library_book_fixture",
      filter: LibraryItemFilter(group: "genres", value: "Sci Fi")
    )

    #expect(queryItems(of: http.requests[0])["filter"] == "genres.U2NpIEZp")
  }

  @Test("percent-escapes '+' and '=' from the base64 filter value on the actual wire, not just round-tripped")
  func escapesFilterSpecialCharactersOnTheWire() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    // printf '%s' "??>>" | base64  ->  Pz8+Pg==  (exercises both '+' and '=' padding).
    // `URLComponents.queryItems` leaves '+' and '/' raw and only escapes '='; many
    // form-urlencoded query parsers read an unescaped '+' in a value as a space, corrupting the
    // base64 payload. The wire must carry the fully percent-encoded form.
    _ = try await client.listLibraryItems(
      account: account,
      library: "library_book_fixture",
      filter: LibraryItemFilter(group: "genres", value: "??>>")
    )

    let rawQuery = try #require(
      URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    )
    #expect(rawQuery.contains("filter=genres.Pz8%2BPg%3D%3D"))
    #expect(rawQuery.contains("+") == false)
  }

  @Test("percent-escapes '=' padding from a non-ASCII base64 filter value on the wire")
  func escapesNonASCIIFilterOnTheWire() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    // printf '%s' "Sigur Rós" | base64  ->  U2lndXIgUsOzcw==
    _ = try await client.listLibraryItems(
      account: account,
      library: "library_book_fixture",
      filter: LibraryItemFilter(group: "authors", value: "Sigur Rós")
    )

    let rawQuery = try #require(
      URLComponents(url: http.requests[0].url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    )
    #expect(rawQuery.contains("filter=authors.U2lndXIgUsOzcw%3D%3D"))
  }

  @Test("clamps a non-positive requested limit to the default page size")
  func clampsNonPositiveLimit() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(account: account, library: "library_book_fixture", limit: 0)

    #expect(queryItems(of: http.requests[0])["limit"] == String(LibraryItemsBounds.fallback))
  }

  @Test("keeps the library page-size ceiling inside rule 15's 50–100 band")
  func libraryItemsMaximumIsWithinRule15Band() {
    #expect((50...100).contains(LibraryItemsBounds.maximum))
  }

  @Test("clamps an oversized requested limit to the maximum page size")
  func clampsOversizedLimit() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(account: account, library: "library_book_fixture", limit: 10_000)

    #expect(queryItems(of: http.requests[0])["limit"] == String(LibraryItemsBounds.maximum))
  }

  @Test("writes rule 15's 100-item ceiling for oversized library item requests")
  func clampsOversizedLimitToRule15CeilingOnWire() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    _ = try await client.listLibraryItems(
      account: account, library: "library_book_fixture", limit: 10_000)

    #expect(queryItems(of: http.requests[0])["limit"] == "100")
  }

  @Test("decodes an empty results page while preserving pagination metadata")
  func decodesEmptyPage() async throws {
    let envelope: [String: Any] = ["results": [], "total": 0, "limit": 50, "page": 0]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.isEmpty)
    #expect(page.total == 0)
    #expect(page.limit == 50)
    #expect(page.page == 0)
  }

  @Test("decodes a final page shorter than the requested limit")
  func decodesFinalPage() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_fixture_last", "libraryId": "library_book_fixture", "mediaType": "book"]
      ],
      "total": 3,
      "limit": 2,
      "page": 1,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_fixture_last"])
    #expect(page.total == 3)
    #expect(page.limit == 2)
    #expect(page.page == 1)
  }

  @Test("preserves repeated ids within a single page rather than deduplicating")
  func preservesRepeatedIds() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_dup", "libraryId": "library_book_fixture"],
        ["id": "item_dup", "libraryId": "library_book_fixture"],
      ],
      "total": 2,
      "limit": 50,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_dup", "item_dup"])
  }

  @Test("surfaces a changed total across two fetched pages without merging them")
  func surfacesChangedTotalAcrossFetches() async throws {
    let firstEnvelope: [String: Any] = ["results": [], "total": 385, "limit": 2, "page": 0]
    let secondEnvelope: [String: Any] = ["results": [], "total": 386, "limit": 2, "page": 1]
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(object: firstEnvelope), jsonResponse(object: secondEnvelope)]
    )

    let first = try await client.listLibraryItems(account: account, library: "library_book_fixture", page: 0)
    let second = try await client.listLibraryItems(account: account, library: "library_book_fixture", page: 1)

    #expect(first.total == 385)
    #expect(second.total == 386)
  }

  @Test("treats a null or wrong-type title as absent while keeping sibling fields")
  func treatsNullOrWrongTypeTitleAsAbsent() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "library-items-minified")) as? [String: Any]
    )
    var results = try #require(object["results"] as? [[String: Any]])
    var firstMedia = try #require(results[0]["media"] as? [String: Any])
    var firstMetadata = try #require(firstMedia["metadata"] as? [String: Any])
    firstMetadata["title"] = NSNull()
    firstMedia["metadata"] = firstMetadata
    results[0]["media"] = firstMedia

    var secondMedia = try #require(results[1]["media"] as? [String: Any])
    var secondMetadata = try #require(secondMedia["metadata"] as? [String: Any])
    secondMetadata["title"] = 12345
    secondMedia["metadata"] = secondMetadata
    results[1]["media"] = secondMedia

    object["results"] = results
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.count == 2)
    #expect(page.items[0].title == nil)
    #expect(page.items[0].authorName == "Fixture Author")
    #expect(page.items[1].title == nil)
    #expect(page.items[1].authorName == "Fixture Author 2")
  }

  @Test("decodes addedAt as epoch milliseconds")
  func minifiedItemDecodesAddedAtAsEpochMilliseconds() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified-media")]
    )

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    // Verbatim from the capture: sub-second precision survives the millisecond conversion.
    #expect(page.items.first?.addedAt == Date(timeIntervalSince1970: 1_741_359_815.635))
  }

  @Test("decodes podcast change signals lossily from a minified item")
  func minifiedPodcastDecodesChangeSignals() async throws {
    let envelope: [String: Any] = [
      "results": [
        [
          "id": "podcast-1",
          "libraryId": "library-podcast",
          "mediaType": "podcast",
          "updatedAt": 1_800_000_123_000,
          "media": ["numEpisodes": 42, "metadata": ["title": "Show"]],
        ],
        [
          "id": "podcast-broken-signals",
          "mediaType": "podcast",
          "updatedAt": "yesterday",
          "media": ["numEpisodes": "many"],
        ],
      ],
      "total": 2, "limit": 2, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-podcast")

    #expect(page.items[0].updatedAt == Date(timeIntervalSince1970: 1_800_000_123))
    #expect(page.items[0].podcastEpisodeCount == 42)
    #expect(page.items[1].updatedAt == nil)
    #expect(page.items[1].podcastEpisodeCount == nil)
  }

  @Test("distinguishes present, absent, and unknown server artwork in minified items")
  func minifiedItemsDecodeArtworkAvailability() async throws {
    let envelope: [String: Any] = [
      "results": [
        [
          "id": "with-cover", "mediaType": "book",
          "media": ["coverPath": "/metadata/items/with-cover.jpg"],
        ],
        [
          "id": "without-cover", "mediaType": "book",
          "media": ["coverPath": NSNull()],
        ],
        [
          "id": "unknown-cover", "mediaType": "book",
          "media": ["metadata": ["title": "Older payload"]],
        ],
        [
          "id": "malformed-cover", "mediaType": "book",
          "media": ["coverPath": 42],
        ],
      ],
      "total": 4, "limit": 4, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-book")

    #expect(page.items.map(\.hasServerArtwork) == [true, false, nil, nil])
  }

  /// A podcast's creator is at `media.metadata.author`, not `authorName`. That key is the book
  /// shape's flattening of its `authors[]` array, and podcast metadata has no such array (see
  /// `ItemDetail`'s podcast decoder). `authorName` still wins where both appear.
  @Test("decodes a podcast's creator from the minified metadata's author key")
  func minifiedPodcastDecodesAuthorFromItsOwnMetadataKey() async throws {
    let envelope: [String: Any] = [
      "results": [
        [
          "id": "podcast-1", "libraryId": "library-podcast", "mediaType": "podcast",
          "media": ["metadata": ["title": "Show", "author": "Fixture Broadcasting"]],
        ],
        [
          "id": "podcast-no-author", "libraryId": "library-podcast", "mediaType": "podcast",
          "media": ["metadata": ["title": "Anonymous Show"]],
        ],
        [
          "id": "book-1", "libraryId": "library-book", "mediaType": "book",
          "media": ["metadata": ["title": "Book", "authorName": "Fixture Author", "author": "Ignored"]],
        ],
      ],
      "total": 3, "limit": 3, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-podcast")

    #expect(page.items[0].authorName == "Fixture Broadcasting")
    #expect(page.items[1].authorName == nil)
    #expect(page.items[2].authorName == "Fixture Author")
  }

  /// Regression: the minified media key is `ebookFormat`. A hand-written fixture once shared an
  /// invented spelling with the decoder, so the suite agreed with itself and every ebook decoded as
  /// an audiobook. This fixture is a sanitized capture from a live 2.35.1 server with verbatim
  /// media keys.
  @Test("decodes the live server's ebookFormat key across the real audio/ebook matrix")
  func minifiedItemDecodesEbookFormatFromLiveCapture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified-media")]
    )

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")
    let byId = Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0) })

    // A plain audiobook: audio files present, no ebook format at all.
    let audiobook = try #require(byId["item_live_audiobook"])
    #expect(audiobook.numAudioFiles == 1)
    #expect(audiobook.ebookFormat == nil)
    #expect(audiobook.durationSeconds == 14220.085986)

    // An audiobook shipping a bundled PDF: both signals present, and audio must win downstream.
    let withPDF = try #require(byId["item_live_audiobook_with_pdf"])
    #expect(withPDF.numAudioFiles == 1)
    #expect(withPDF.ebookFormat == "pdf")

    // A real ebook: zero audio files, zero duration, format carried on `ebookFormat`.
    let ebook = try #require(byId["item_live_ebook"])
    #expect(ebook.numAudioFiles == 0)
    #expect(ebook.ebookFormat == "epub")
    #expect(ebook.durationSeconds == 0)
  }

  @Test("keeps the item and defaults each new field to nil when it is independently absent, null, or wrong-typed")
  func minifiedItemKeepsItemWhenNewFieldsAreAbsentNullOrWrongType() async throws {
    let baseObject = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "library-items-minified-media"))
        as? [String: Any]
    )
    let baseResults = try #require(baseObject["results"] as? [[String: Any]])
    // The ebook item is the only capture carrying all three new media fields at once, so it is the
    // base each mutation strips one field from.
    let baseItem = try #require(baseResults.first { $0["id"] as? String == "item_live_ebook" })

    var missingAddedAt = baseItem
    missingAddedAt["id"] = "item_absent_addedAt"
    missingAddedAt.removeValue(forKey: "addedAt")

    var nullDuration = baseItem
    nullDuration["id"] = "item_null_duration"
    var nullDurationMedia = try #require(nullDuration["media"] as? [String: Any])
    nullDurationMedia["duration"] = NSNull()
    nullDuration["media"] = nullDurationMedia

    var wrongTypeNumAudioFiles = baseItem
    wrongTypeNumAudioFiles["id"] = "item_wrongtype_numAudioFiles"
    var wrongNumMedia = try #require(wrongTypeNumAudioFiles["media"] as? [String: Any])
    wrongNumMedia["numAudioFiles"] = "twelve"
    wrongTypeNumAudioFiles["media"] = wrongNumMedia

    var wrongTypeEbookFormat = baseItem
    wrongTypeEbookFormat["id"] = "item_wrongtype_ebookFormat"
    var wrongFormatMedia = try #require(wrongTypeEbookFormat["media"] as? [String: Any])
    wrongFormatMedia["ebookFormat"] = 42
    wrongTypeEbookFormat["media"] = wrongFormatMedia

    var object = baseObject
    object["results"] = [missingAddedAt, nullDuration, wrongTypeNumAudioFiles, wrongTypeEbookFormat]
    object["total"] = 4
    object["limit"] = 4

    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])
    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    let byId = Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0) })
    #expect(byId.count == 4)

    let absentAddedAt = try #require(byId["item_absent_addedAt"])
    #expect(absentAddedAt.addedAt == nil)
    #expect(absentAddedAt.durationSeconds == 0)
    #expect(absentAddedAt.title == "Fixture Ebook")

    let nullDur = try #require(byId["item_null_duration"])
    #expect(nullDur.durationSeconds == nil)
    #expect(nullDur.addedAt == Date(timeIntervalSince1970: 1_742_052_567.692))

    let wrongNum = try #require(byId["item_wrongtype_numAudioFiles"])
    #expect(wrongNum.numAudioFiles == nil)
    #expect(wrongNum.ebookFormat == "epub")

    let wrongFormat = try #require(byId["item_wrongtype_ebookFormat"])
    #expect(wrongFormat.ebookFormat == nil)
    #expect(wrongFormat.numAudioFiles == 0)
  }

  // The trimmed fixture lacks the newer media fields. `addedAt` is present (zeroed by the
  // sanitisation in Fixtures.swift) so it decodes to the epoch rather than nil; the other three
  // are absent from this fixture's `media` object.
  @Test("existing minified fixture still decodes with the media-derived new fields nil")
  func existingMinifiedFixtureStillDecodes() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "library-items-minified")]
    )

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.count == 2)
    #expect(page.items.allSatisfy { $0.addedAt == Date(timeIntervalSince1970: 0) })
    #expect(page.items.allSatisfy { $0.durationSeconds == nil })
    #expect(page.items.allSatisfy { $0.numAudioFiles == nil })
    #expect(page.items.allSatisfy { $0.ebookFormat == nil })
  }

  @Test("skips malformed elements and required-id-missing elements, recording safe diagnostics")
  func skipsMalformedAndRequiredIdElements() async throws {
    let malformedResults = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "malformed-library-items")) as? [Any]
    )
    let envelope: [String: Any] = ["results": malformedResults, "total": 4, "limit": 4, "page": 0]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let page = try await client.listLibraryItems(
      account: account,
      library: "library_book_fixture",
      diagnostics: diagnostics
    )

    #expect(page.items.map(\.id) == ["valid-id"])
    let entries = diagnostics.entries
    #expect(entries.count == 3)
    #expect(entries.allSatisfy { $0.endpoint == "/api/libraries/:id/items" })
    // Element 1 now reports through the `requiredKey` post-filter (after the array is scanned),
    // while element 2 still fails structurally during `LossyArray`'s scan, so the entries are not
    // in element order. Assert the set of indices, then the path each one reported.
    #expect(entries.compactMap(\.elementIndex).sorted() == [1, 2, 3])
    // Index 1 is a wrong-typed id: `decodeBoundedString` treats a wrong type as absent, so it now
    // drops through this endpoint's `requiredKey` post-filter like a missing id. Index 2 is a
    // structurally-malformed element caught inside `LossyArray` itself, whose coding path is the
    // real `DecodingError` context, prefixed with "results" because `results` is nested inside the
    // page envelope (unlike `BoundedDecoderTests`' bare top-level array). Index 3 is a
    // structurally-valid element missing "id", caught by the same `requiredKey` post-filter.
    let paths = Dictionary(
      uniqueKeysWithValues: entries.map { ($0.elementIndex ?? -1, $0.codingPath) })
    #expect(paths == [1: ["id"], 2: ["results"], 3: ["id"]])
    let formatted = entries.map(\.description).joined(separator: "\n")
    for secret in ["wrong-type", "not-an-object", "private-title"] {
      #expect(formatted.contains(secret) == false)
    }
  }

  @Test("drops an item whose id exceeds the string bound, keeping the rest")
  func dropsOversizedItemIdElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_valid_fixture", "libraryId": "library_book_fixture", "mediaType": "book"],
        [
          "id": String(repeating: "x", count: limit + 1),
          "libraryId": "library_book_fixture",
          "mediaType": "book",
        ],
      ],
      "total": 2,
      "limit": 2,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_valid_fixture"])
  }

  @Test("an oversized libraryId drops the item rather than reading as an unknown library")
  func oversizedLibraryIdDropsElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_valid_fixture", "libraryId": "library_book_fixture", "mediaType": "book"],
        [
          "id": "item_oversized_library_fixture",
          "libraryId": String(repeating: "l", count: limit + 1),
          "mediaType": "book",
        ],
      ],
      "total": 2,
      "limit": 2,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_valid_fixture"])
  }

  @Test("a wrong-typed libraryId drops the item rather than reading as an unknown library")
  func wrongTypedLibraryIdDropsElement() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_valid_fixture", "libraryId": "library_book_fixture", "mediaType": "book"],
        ["id": "item_wrong_type_library_fixture", "libraryId": 42, "mediaType": "book"],
      ],
      "total": 2,
      "limit": 2,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_valid_fixture"])
  }

  @Test("an absent or null libraryId stays nil and keeps the item")
  func absentOrNullLibraryIdKeepsItem() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "item_absent_library_fixture", "mediaType": "book"],
        ["id": "item_null_library_fixture", "libraryId": NSNull(), "mediaType": "book"],
      ],
      "total": 2,
      "limit": 2,
      "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library_book_fixture")

    #expect(page.items.map(\.id) == ["item_absent_library_fixture", "item_null_library_fixture"])
    #expect(page.items.allSatisfy { $0.libraryID == nil })
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
