import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/items/{id}?expanded=1`.
/// Covers the expanded book shape (tracks/chapters/ebookFile) and podcast shape (episodes) from
/// the sanitized fixtures, plus synthetic malformed/edge cases (API-CONVENTIONS rule 21).
@Suite("Item detail endpoint")
struct ItemDetailTests {

  @Test("fetching item detail throws unauthorized when no tokens are stored for the account")
  func fetchingItemDetailWithoutStoredTokensThrowsUnauthorized() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: InMemoryTokenStore())

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
    }
  }

  @Test("requests the expanded item with expanded=1 and bearer auth")
  func requestsExpandedItemWithAuth() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "book-item-expanded")]
    )

    _ = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    #expect(http.requests.count == 1)
    let request = http.requests[0]
    #expect(request.method == .get)
    #expect(request.url.path == "/api/items/item_book_fixture")
    #expect(request.routeTemplate == "/api/items/:id")
    #expect(request.headers["Authorization"] == "Bearer canary-access")
    let query = queryItems(of: request)
    #expect(query["expanded"] == "1")
  }

  @Test("decodes an expanded book's identity, metadata, and single track from the fixture")
  func decodesExpandedBookFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "book-item-expanded")]
    )

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    #expect(detail.id == "item_book_fixture")
    #expect(detail.libraryID == "library_book_fixture")
    #expect(detail.mediaType == "book")

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.title == "Fixture Book")
    #expect(book.authorName == "Fixture Author")
    #expect(book.narratorName == "Fixture Narrator")
    #expect(book.seriesName == nil)
    #expect(book.tracks.count == 1)
    #expect(book.tracks[0].index == 0)
    #expect(book.tracks[0].title == "Fixture Track")
    #expect(book.tracks[0].mimeType == "audio/mp4")
    #expect(book.chapters.isEmpty)
    #expect(book.ebookFile == nil)
  }

  @Test("decodes a clean AudioFileCatalog entry for each valid audioFiles[] element")
  func decodesAudioFileCatalogForValidEntries() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "book-item-expanded")]
    )

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.audioFiles.invalidEntryCount == 0)
    #expect(book.audioFiles.files.count == 1)
    let file = try #require(book.audioFiles.files.first)
    #expect(file.index == 0)
    #expect(file.ino == "0", "a numeric ino is still accepted, carried as its string form")
    #expect(file.mimeType == "audio/mp4")
    #expect(file.expectedSize > 0)
    #expect(file.duration > 0)
  }

  @Test("decodes the real server's string audioFiles[].ino shape")
  func decodesStringInoAudioFileEntries() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    // The shape a real Audiobookshelf server sends (`"ino": "649641337522215266"`): a decimal
    // string, wider than `Int32` and not guaranteed numeric at all.
    media["audioFiles"] = [
      [
        "index": 0, "ino": "649641337522215266", "duration": 654.0, "mimeType": "audio/mp4",
        "metadata": ["filename": "<redacted>", "path": "<redacted>", "size": 2048],
      ],
      [
        "index": 1, "ino": "", "duration": 60.0, "mimeType": "audio/mp4",
        "metadata": ["size": 100],
      ],  // empty ino: no usable file identity
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.audioFiles.files.map(\.ino) == ["649641337522215266"])
    #expect(book.audioFiles.invalidEntryCount == 1)
  }

  @Test("counts malformed and invalid audioFiles entries instead of disappearing silently")
  func countsInvalidAudioFileEntriesWithoutExposingRawPathOrFilename() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    media["audioFiles"] = [
      [
        "index": 0, "ino": 900, "duration": 654.0, "mimeType": "audio/mp4",
        "metadata": ["filename": "<redacted>", "path": "<redacted>", "size": 2048],
      ],  // valid
      ["ino": 901, "duration": 60.0, "mimeType": "audio/mp4", "metadata": ["size": 100]],  // missing index
      ["index": 2, "duration": 60.0, "mimeType": "audio/mp4", "metadata": ["size": 100]],  // missing ino
      ["index": 3, "ino": 903, "duration": 60.0, "mimeType": "audio/mp4", "metadata": ["size": 0]],  // zero size
      ["index": 4, "ino": 904, "duration": 60.0, "mimeType": "", "metadata": ["size": 100]],  // empty mimeType
      ["index": 5, "ino": 905, "duration": 0, "mimeType": "audio/mp4", "metadata": ["size": 100]],  // zero duration
      // negative duration
      ["index": 6, "ino": 906, "duration": -5.0, "mimeType": "audio/mp4", "metadata": ["size": 100]],
      "not-an-object",  // malformed element entirely
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.audioFiles.files.count == 1)
    #expect(book.audioFiles.files.first?.ino == "900")
    #expect(book.audioFiles.invalidEntryCount == 7)
  }

  enum BookMediaArrayField: String, CaseIterable {
    case audioFiles, tracks, chapters
  }

  @Test(
    "throws when a present book-media array has the wrong top-level type",
    arguments: BookMediaArrayField.allCases
  )
  func throwsForWrongTypeBookMediaArray(field: BookMediaArrayField) async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    media[field.rawValue] = "not-an-array"
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    await #expect(throws: APIError.decoding) {
      try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
    }
  }

  @Test(
    "treats an absent or null book-media array as empty",
    arguments: BookMediaArrayField.allCases, [false, true]
  )
  func treatsMissingOrNullBookMediaArrayAsEmpty(
    field: BookMediaArrayField, isNull: Bool
  ) async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    if isNull {
      media[field.rawValue] = NSNull()
    } else {
      media.removeValue(forKey: field.rawValue)
    }
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }

    switch field {
    case .audioFiles:
      #expect(book.audioFiles.files.isEmpty)
    case .tracks:
      #expect(book.tracks.isEmpty)
    case .chapters:
      #expect(book.chapters.isEmpty)
    }
  }

  @Test("decodes populated chapters and an ebookFile when the server includes them")
  func decodesExpandedBookChaptersAndEbookFile() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    media["chapters"] = [
      ["id": 0, "start": 0, "end": 120, "title": "Chapter One"],
      ["id": 1, "start": 120, "end": 240, "title": "Chapter Two"],
    ]
    media["ebookFile"] = [
      "ino": "12345",
      "metadata": ["filename": "fixture.epub", "ext": ".epub", "path": "<redacted>", "size": 2048],
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.chapters.map(\.id) == [0, 1])
    #expect(book.chapters.map(\.title) == ["Chapter One", "Chapter Two"])
    #expect(book.chapters[0].start == 0)
    #expect(book.chapters[0].end == 120)

    let ebookFile = try #require(book.ebookFile)
    #expect(ebookFile.ino == "12345")
    #expect(ebookFile.ext == "epub")
    #expect(ebookFile.filename == "fixture.epub")
    #expect(ebookFile.size == 2048)
  }

  @Test("decodes and pins the captured ebookFile shape with a leading-dot extension")
  func decodesCapturedEbookFileFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "search-full-buckets-authors")]
    )

    let results = try await client.searchLibrary(
      account: account, library: "library_fixture", query: "fixture"
    )
    let hit = try #require(results.bookHits.first)

    guard case .book(let book) = try #require(hit.libraryItem.media) else {
      Issue.record("expected the captured search hit to decode as book media")
      return
    }
    let ebookFile = try #require(book.ebookFile)
    #expect(ebookFile.ino == "3000002")
    #expect(ebookFile.ext == "epub")
    #expect(ebookFile.filename == "The Fixture at the End of the Shelf - Fen Fixture.epub")
    #expect(ebookFile.size == 131676)
  }

  @Test("normalizes EPUB extension spellings identically")
  func normalizesEpubExtensionSpellings() async throws {
    for rawExtension in [".epub", "EPUB", ".EPUB", "epub"] {
      var object = try #require(
        JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
      )
      var media = try #require(object["media"] as? [String: Any])
      media["ebookFile"] = [
        "ino": "12345",
        "metadata": ["filename": "fixture.epub", "ext": rawExtension, "size": 2048],
      ]
      object["media"] = media
      let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

      let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
      guard case .book(let book) = try #require(detail.media) else {
        Issue.record("expected book media")
        continue
      }
      let ebookFile = try #require(book.ebookFile)
      #expect(ebookFile.ext == "epub")
    }
  }

  @Test("keeps unknown and absent ebook extensions out of the EPUB value")
  func doesNotTreatUnknownOrAbsentExtensionAsEpub() async throws {
    for rawExtension in [".pdf", "mobi", ""] {
      var object = try #require(
        JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
      )
      var media = try #require(object["media"] as? [String: Any])
      media["ebookFile"] = [
        "ino": "12345",
        "metadata": ["filename": "fixture.book", "ext": rawExtension, "size": 2048],
      ]
      object["media"] = media
      let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

      let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
      guard case .book(let book) = try #require(detail.media) else {
        Issue.record("expected book media")
        continue
      }
      let ebookFile = try #require(book.ebookFile)
      #expect(ebookFile.ext != "epub")
    }

    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    media["ebookFile"] = [
      "ino": "12345",
      "metadata": ["filename": "fixture.book", "size": 2048],
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    let ebookFile = try #require(book.ebookFile)
    #expect(ebookFile.ext == nil)
    #expect(ebookFile.ext != "epub")
  }

  @Test("decodes an expanded podcast's episodes from the fixture")
  func decodesExpandedPodcastFixture() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "podcast-item-expanded")]
    )

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    #expect(detail.id == "item_podcast_fixture")
    #expect(detail.mediaType == "podcast")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.title == "Fixture Podcast")
    #expect(podcast.author == "Fixture Publisher")
    #expect(podcast.episodes.count == 1)
    let episode = try #require(podcast.episodes.first)
    #expect(episode.id == "episode_fixture")
    #expect(episode.title == "Fixture Episode")
    #expect(episode.mimeType == "audio/mpeg")
    #expect(episode.duration == 0)
    #expect(episode.publishedAt == Date(timeIntervalSince1970: 0))
  }

  @Test("decodes an episode's chapters leniently: malformed entries dropped, missing or null key is empty")
  func decodesPodcastEpisodeChapters() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "podcast-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    let template = try #require((media["episodes"] as? [[String: Any]])?.first)
    func episode(id: String, chapters: Any?) -> [String: Any] {
      var value = template
      value["id"] = id
      if let chapters { value["chapters"] = chapters } else { value.removeValue(forKey: "chapters") }
      return value
    }
    media["episodes"] = [
      episode(
        id: "with",
        chapters: [
          ["id": 0, "start": 0, "end": 60, "title": "Intro"],
          ["start": 60, "end": 90, "title": "No id"],
          "not an object",
          ["id": 2, "start": 90, "end": 120, "title": "Outro"],
        ]),
      episode(id: "missing", chapters: nil),
      episode(id: "null", chapters: NSNull()),
      episode(id: "wrongType", chapters: "nope"),
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let byID = Dictionary(uniqueKeysWithValues: podcast.episodes.map { ($0.id, $0) })
    #expect(byID["with"]?.chapters.map(\.id) == [0, 2])
    #expect(byID["with"]?.chapters.map(\.title) == ["Intro", "Outro"])
    #expect(byID["with"]?.chapters.last?.end == 120)
    #expect(byID["missing"]?.chapters == [])
    #expect(byID["null"]?.chapters == [])
    #expect(byID["wrongType"]?.chapters == [])
    #expect(podcast.episodes.count == 4)
  }

  @Test("ignores an embedded userMediaProgress object without changing item decoding")
  func ignoresEmbeddedUserMediaProgress() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    object["userMediaProgress"] = progress
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")

    #expect(detail.id == "item_book_fixture")
    #expect(detail.libraryID == "library_book_fixture")
    #expect(detail.mediaType == "book")
    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.title == "Fixture Book")
  }

  @Test("treats a missing or unrecognized mediaType as absent media without crashing")
  func treatsUnknownMediaTypeAsNilMedia() async throws {
    let envelope: [String: Any] = [
      "id": "item_weird_fixture",
      "libraryId": "library_book_fixture",
      "mediaType": "audiobookshelf-future-type",
      "media": ["metadata": ["title": "Unknown Shape"]],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_weird_fixture")

    #expect(detail.id == "item_weird_fixture")
    #expect(detail.mediaType == "audiobookshelf-future-type")
    #expect(detail.media == nil)
  }

  @Test("skips track and chapter elements missing their required identity, recording diagnostics")
  func skipsTrackAndChapterElementsMissingRequiredIdentity() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    var media = try #require(object["media"] as? [String: Any])
    media["tracks"] = [
      ["index": 0, "title": "Track Zero", "contentUrl": "<redacted>", "mimeType": "audio/mp4"],
      ["title": "Track Missing Index", "contentUrl": "<redacted>", "mimeType": "audio/mp4"],
    ]
    media["chapters"] = [
      ["id": 0, "start": 0, "end": 60, "title": "Chapter Zero"],
      ["start": 60, "end": 120, "title": "Chapter Missing Id"],
    ]
    object["media"] = media
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: object)])
    let diagnostics = DecodeDiagnostics()

    let detail = try await client.fetchItemDetail(
      account: account,
      itemID: "item_book_fixture",
      diagnostics: diagnostics
    )

    guard case .book(let book) = try #require(detail.media) else {
      Issue.record("expected book media")
      return
    }
    #expect(book.tracks.map(\.index) == [0])
    #expect(book.chapters.map(\.id) == [0])
    #expect(diagnostics.entries.isEmpty == false)
    #expect(diagnostics.entries.allSatisfy { $0.endpoint == "/api/items/:id" })
  }

  @Test("throws a decoding error when the top-level item id is missing")
  func throwsDecodingErrorWhenTopLevelIdIsMissing() async throws {
    let envelope: [String: Any] = ["libraryId": "library_book_fixture", "mediaType": "book"]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
    }
  }

  @Test("throws a decoding error when the top-level item id exceeds the string bound")
  func throwsDecodingErrorWhenTopLevelIdIsOversized() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let envelope: [String: Any] = [
      "id": String(repeating: "x", count: limit + 1),
      "libraryId": "library_book_fixture",
      "mediaType": "book",
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.fetchItemDetail(account: account, itemID: "item_book_fixture")
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
