import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Wire-contract coverage using sanitized live shapes inline, not the research captures. Those
/// contain semantic tokens and are evidence only. This suite asserts the selected fields and
/// payload bounds at the ABSApi boundary.
@Suite("NP12 podcast wire endpoints")
struct PodcastWriteEndpointTests {

  @Test("projects declared library folders without changing book-library values")
  func projectsLibraryFolders() async throws {
    let envelope: [String: Any] = [
      "libraries": [
        [
          "id": "library-podcast",
          "name": "Podcasts",
          "mediaType": "podcast",
          "folders": [
            ["id": "folder-one", "libraryId": "library-podcast", "fullPath": "/podcasts"],
            ["id": "folder-two", "libraryId": "library-podcast", "fullPath": "/other-podcasts"],
          ],
        ],
        [
          "id": "library-book",
          "name": "Books",
          "mediaType": "book",
          "folders": [["id": "book-folder", "fullPath": "/books"]],
        ],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let libraries = try await client.listLibraries(account: account)

    let podcast = try #require(libraries.first { $0.id == "library-podcast" })
    #expect(podcast.folders.map(\.id) == ["folder-one", "folder-two"])
    #expect(podcast.folders.map(\.fullPath) == ["/podcasts", "/other-podcasts"])
    #expect(podcast.folders.map(\.libraryID) == ["library-podcast", "library-podcast"])
    let book = try #require(libraries.first { $0.id == "library-book" })
    #expect(book.folders.isEmpty == false)
  }

  @Test("missing, null, malformed, and incomplete folder elements are dropped")
  func dropsMalformedFolders() async throws {
    let envelope: [String: Any] = [
      "libraries": [
        [
          "id": "library-podcast",
          "name": "Podcasts",
          "mediaType": "podcast",
          "folders": [
            ["id": "kept", "fullPath": "/podcasts"],
            ["id": "missing-path"],
            ["fullPath": "/missing-id"],
            ["id": 42, "fullPath": "/wrong-id"],
            ["id": "relative", "fullPath": "podcasts"],
            ["id": "traversal", "fullPath": "/podcasts/../outside"],
            ["id": "encoded-traversal", "fullPath": "/podcasts/%2e%2e/outside"],
            "not-an-object",
          ],
        ],
        ["id": "null-folders", "name": "Null", "mediaType": "podcast", "folders": NSNull()],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let libraries = try await client.listLibraries(account: account)

    #expect(libraries[0].folders.map(\.id) == ["kept"])
    #expect(libraries[1].folders.isEmpty)

    let malformedArray: [String: Any] = [
      "libraries": [["id": "wrong-folders", "name": "Wrong", "mediaType": "podcast", "folders": "wrong"]]
    ]
    let malformedDiagnostics = DecodeDiagnostics()
    let (malformedClient, _, malformedAccount) = try makeClient(
      responses: [jsonResponse(object: malformedArray)])
    let malformedLibraries = try await malformedClient.listLibraries(
      account: malformedAccount, diagnostics: malformedDiagnostics)
    #expect(malformedLibraries.count == 1)
    #expect(malformedLibraries[0].folders.isEmpty)
    #expect(malformedDiagnostics.entries.contains { $0.codingPath == ["folders"] })
  }

  @Test("projects only a podcast feed URL from a minified item")
  func projectsMinifiedPodcastFeedURL() async throws {
    let envelope: [String: Any] = [
      "results": [
        [
          "id": "podcast-one", "libraryId": "library-podcast", "mediaType": "podcast",
          "media": ["metadata": ["title": "Show", "feedUrl": "https://feeds.example/show.xml"]],
        ],
        [
          "id": "book-one", "libraryId": "library-book", "mediaType": "book",
          "media": ["metadata": ["title": "Book", "feedUrl": "https://ignored.example/feed"]],
        ],
        [
          "id": "podcast-malformed", "libraryId": "library-podcast", "mediaType": "podcast",
          "media": ["metadata": ["title": "Malformed", "feedUrl": 42]],
        ],
      ],
      "total": 3, "limit": 3, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-podcast")

    #expect(
      page.items.map(\.feedURLState)
        == [.value("https://feeds.example/show.xml"), .absent, .invalid])
  }

  @Test("projects the minified podcast language, telling an omitted key from a cleared one")
  func projectsMinifiedPodcastLanguage() async throws {
    func podcast(_ id: String, metadata: [String: Any]) -> [String: Any] {
      ["id": id, "libraryId": "library-podcast", "mediaType": "podcast", "media": ["metadata": metadata]]
    }
    let overlong = String(repeating: "e", count: PodcastLanguageState.maximumBytes + 1)
    let envelope: [String: Any] = [
      "results": [
        podcast("tagged", metadata: ["title": "A", "language": "en-GB"]),
        podcast("padded", metadata: ["title": "B", "language": " EN-us \n"]),
        podcast("french", metadata: ["title": "C", "language": "fr"]),
        podcast("omitted", metadata: ["title": "D"]),
        podcast("null", metadata: ["title": "E", "language": NSNull()]),
        podcast("empty", metadata: ["title": "F", "language": "  "]),
        podcast("wrong-type", metadata: ["title": "G", "language": 7]),
        podcast("overlong", metadata: ["title": "H", "language": overlong]),
        ["id": "no-metadata", "libraryId": "library-podcast", "mediaType": "podcast", "media": [:]],
        [
          "id": "book", "libraryId": "library-book", "mediaType": "book",
          "media": ["metadata": ["title": "Book", "language": "en"]],
        ],
      ],
      "total": 10, "limit": 10, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-podcast")

    #expect(
      page.items.map(\.podcastLanguageState)
        == [
          .value("en-GB"), .value("EN-us"), .value("fr"), .absent, .cleared, .cleared, .cleared,
          .cleared, .absent, .absent,
        ])
  }

  @Test("projects only optional update and delete permissions from the user profile")
  func projectsNarrowUserPermissions() async throws {
    let profile: [String: Any] = [
      "id": "user-root",
      "username": "root",
      "type": "root",
      "isActive": true,
      "isLocked": false,
      "librariesAccessible": [],
      "mediaProgress": [],
      "permissions": [
        "update": true,
        "delete": false,
        "upload": "must-not-cross-boundary",
        "accessAllLibraries": true,
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: profile)])

    let decoded = try await client.fetchUserProfile(account: account)

    #expect(decoded.permissionsUpdate == true)
    #expect(decoded.permissionsDelete == false)
  }

  @Test("missing, null, and malformed narrow permissions remain unknown")
  func permissionsAreOptionalAndLossy() async throws {
    let profiles: [[String: Any]] = [
      ["id": "missing", "permissions": NSNull()],
      ["id": "null", "permissions": ["update": NSNull(), "delete": NSNull()]],
      ["id": "wrong", "permissions": ["update": "true", "delete": 1]],
    ]
    let (client, _, account) = try makeClient(responses: profiles.map { try! jsonResponse(object: $0) })

    for _ in profiles {
      let decoded = try await client.fetchUserProfile(account: account)
      #expect(decoded.permissionsUpdate == nil)
      #expect(decoded.permissionsDelete == nil)
    }
  }

  @Test("decodes expanded GUID and source enclosure independently from audioTrack content URL")
  func decodesEpisodeSourceIdentity() async throws {
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "episode-one",
        "guid": "guid-one",
        "enclosure": ["url": "https://cdn.example/episode-one.mp3", "type": "audio/mpeg", "length": "123"],
        "audioTrack": ["contentUrl": "/api/items/server-item/file/123", "mimeType": "audio/mpeg"],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "server-item")
    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.guid == "guid-one")
    #expect(episode.enclosureURL == "https://cdn.example/episode-one.mp3")
    #expect(episode.contentUrl == "/api/items/server-item/file/123")
    #expect(episode.enclosureURL != episode.contentUrl)
  }

  @Test("source identity fields are optional and malformed values do not drop the episode")
  func sourceIdentityFieldsAreLossy() async throws {
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "absent",
        "guid": NSNull(),
        "enclosure": NSNull(),
      ],
      [
        "id": "wrong-types",
        "guid": 7,
        "enclosure": ["url": 7],
      ],
      [
        "id": "valid",
        "guid": "guid-valid",
        "enclosure": ["url": "https://cdn.example/valid.mp3"],
      ],
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "server-item")
    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.episodes.map(\.id) == ["absent", "wrong-types", "valid"])
    #expect(podcast.episodes[0].guid == nil)
    #expect(podcast.episodes[0].enclosureURL == nil)
    #expect(podcast.episodes[1].guid == nil)
    #expect(podcast.episodes[1].enclosureURL == nil)
    #expect(podcast.episodes[2].enclosureURL == "https://cdn.example/valid.mp3")
    #expect(podcast.isEpisodeListStructurallyComplete)
  }

  @Test("create sends the minimal bounded payload and validates the returned usable item id")
  func createsPodcastWithMinimalPayload() async throws {
    let response = jsonResponse(body: Data(#"{"id":"created-item","mediaType":"podcast"}"#.utf8))
    let (client, http, account) = try makeClient(responses: [response])

    let itemID = try await client.createPodcast(
      account: account,
      libraryID: "library-podcast",
      folderID: "folder-one",
      path: "/podcasts/show-one",
      title: "Show One",
      author: "Publisher",
      feedURL: "https://feeds.example/show.xml"
    )

    #expect(itemID == "created-item")
    let request = try #require(http.requests.first)
    #expect(request.method == .post)
    #expect(request.url.path == "/api/podcasts")
    #expect(request.routeTemplate == "/api/podcasts")
    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(object.keys) == ["folderId", "libraryId", "media", "path"])
    #expect(object["folderId"] as? String == "folder-one")
    #expect(object["libraryId"] as? String == "library-podcast")
    #expect(object["path"] as? String == "/podcasts/show-one")
    let media = try #require(object["media"] as? [String: Any])
    let metadata = try #require(media["metadata"] as? [String: Any])
    #expect(Set(metadata.keys) == ["author", "feedUrl", "title"])
    #expect(metadata["author"] as? String == "Publisher")
    #expect(metadata["feedUrl"] as? String == "https://feeds.example/show.xml")
    #expect(metadata["title"] as? String == "Show One")
    #expect(object["episodesToDownload"] == nil)
    #expect(String(describing: request).contains("https://feeds.example") == false)
  }

  @Test("create encodes an eligible opaque-query artwork URL and keeps diagnostics redacted")
  func createsPodcastWithOptionalArtwork() throws {
    let artworkURL = "https://images.example/show.png?token=opaque&sig=a%2Bb"
    let request = PodcastCreateRequest(
      libraryID: "library-podcast",
      folderID: "folder-one",
      path: "/podcasts/show-one",
      title: "Show One",
      author: "Publisher",
      feedURL: "https://feeds.example/show.xml",
      imageURL: artworkURL)

    let body = try JSONEncoder().encode(request)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let media = try #require(object["media"] as? [String: Any])
    let metadata = try #require(media["metadata"] as? [String: Any])
    #expect(metadata["imageUrl"] as? String == artworkURL)
    #expect(Mirror(reflecting: request).children.isEmpty)

    for diagnostic in [request.description, request.debugDescription, String(reflecting: request)] {
      #expect(diagnostic.contains("images.example") == false)
      #expect(diagnostic.contains("opaque") == false)
      #expect(diagnostic.contains("a%2Bb") == false)
    }

    let httpRequest = HTTPRequest(
      method: .post,
      url: URL(string: "https://server.example/api/podcasts")!,
      headers: [:],
      body: body,
      routeTemplate: "/api/podcasts")
    #expect(String(describing: httpRequest).contains("opaque") == false)
    #expect(String(reflecting: httpRequest).contains("images.example") == false)
  }

  @Test("create omits missing or unsafe artwork without rejecting the show")
  func omitsUnsafeOptionalArtwork() throws {
    let invalidArtworkURLs = [
      String(repeating: "a", count: PodcastWriteBounds.maximumStringBytes + 1),
      "ftp://images.example/show.png",
      "https:///show.png",
      "https://user:password@images.example/show.png",
      "https://images.example/show.png#fragment",
      "https://images.example/show\0.png",
      "https://images.example/show%00.png",
      "https://images.example:0/show.png",
      "https://localhost/show.png",
      "https://localhost./show.png",
      "https://127.0.0.1/show.png",
      "https://127.1/show.png",
      "https://010.0.0.1/show.png",
      "https://2130706433/show.png",
      "https://0x7f000001/show.png",
      "https://192.168.1.7/show.png",
      "https://169.254.1.7/show.png",
      "https://[::1]/show.png",
      "https://[::ffff:127.0.0.1]/show.png",
      "https://[fc00::1]/show.png",
      "https://[fe80::1]/show.png",
      "https://[2001:11::1]/show.png",
      "https://[2001:20::1]/show.png",
      "https://[2001:2f::1]/show.png",
      "https://[2001:db8::1]/show.png",
    ]

    for imageURL in invalidArtworkURLs {
      let request = PodcastCreateRequest(
        libraryID: "library-podcast",
        folderID: "folder-one",
        path: "/podcasts/show-one",
        title: "Show One",
        author: nil,
        feedURL: "https://feeds.example/show.xml",
        imageURL: imageURL)
      #expect(request.imageURL == nil)

      let body = try JSONEncoder().encode(request)
      let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
      let media = try #require(object["media"] as? [String: Any])
      let metadata = try #require(media["metadata"] as? [String: Any])
      #expect(metadata["imageUrl"] == nil)
    }

    let publicLiteral = PodcastCreateRequest(
      libraryID: "library-podcast",
      folderID: "folder-one",
      path: "/podcasts/show-one",
      title: "Show One",
      feedURL: "https://feeds.example/show.xml",
      imageURL: "https://8.8.8.8/show.png?opaque-query")
    #expect(publicLiteral.imageURL == "https://8.8.8.8/show.png?opaque-query")

    let publicIPv6Literal = PodcastCreateRequest(
      libraryID: "library-podcast",
      folderID: "folder-one",
      path: "/podcasts/show-one",
      title: "Show One",
      feedURL: "https://feeds.example/show.xml",
      imageURL: "https://[2001:4860:4860::8888]/show.png")
    #expect(publicIPv6Literal.imageURL == "https://[2001:4860:4860::8888]/show.png")
  }

  @Test("mutation logging retains only the route template and status")
  func mutationLoggingDoesNotExposePayload() async throws {
    let logger = RedactingHTTPLogger()
    let response = jsonResponse(body: Data(#"{"id":"created-item"}"#.utf8))
    let (client, _, account) = try makeClient(responses: [response], logger: logger)

    _ = try await client.createPodcast(
      account: account,
      libraryID: "library-podcast",
      folderID: "folder-one",
      path: "/podcasts/show-one",
      title: "Show One",
      author: nil,
      feedURL: "https://feeds.example/private.xml"
    )

    let entries = await logger.formattedEntries()
    let entry = try #require(entries.first)
    #expect(entry.contains("POST /api/podcasts"))
    #expect(entry.contains("status=200"))
    #expect(entry.contains("private.xml") == false)
    #expect(entry.contains("Show One") == false)
    #expect(entry.contains("library-podcast") == false)

    let episodeRequest = PodcastEpisodeDownloadRequest(
      title: "Episode title", enclosureURL: "https://cdn.example/private.mp3")
    #expect(String(describing: episodeRequest).contains("private.mp3") == false)
    #expect(String(reflecting: episodeRequest).contains("Episode title") == false)
  }

  @Test("create treats a 200 response without a non-empty item id as malformed")
  func createRequiresUsableItemID() async throws {
    let responses = [
      jsonResponse(body: Data(#"{"mediaType":"podcast"}"#.utf8)),
      jsonResponse(body: Data(#"{"id":""}"#.utf8)),
      jsonResponse(body: Data(#"{"id":42}"#.utf8)),
    ]
    let (client, _, account) = try makeClient(responses: responses)

    for _ in responses {
      await #expect(throws: APIError.decoding) {
        _ = try await client.createPodcast(
          account: account,
          libraryID: "library-podcast",
          folderID: "folder-one",
          path: "/podcasts/show-one",
          title: "Show One",
          author: nil,
          feedURL: "https://feeds.example/show.xml"
        )
      }
    }
  }

  @Test("create and enqueue reject path-unsafe identifiers")
  func rejectsPathUnsafeIdentifiers() async throws {
    for invalidID in ["show one", "show%one"] {
      let (enqueueClient, enqueueHTTP, account) = try makeClient(responses: [])
      await #expect(throws: PodcastWriteError.invalidValue(field: .itemID)) {
        try await enqueueClient.enqueuePodcastEpisode(
          account: account,
          itemID: invalidID,
          episode: PodcastEpisodeDownloadRequest(enclosureURL: "https://cdn.example/episode.mp3")
        )
      }
      #expect(enqueueHTTP.requests.isEmpty)

      let response = jsonResponse(body: Data("{\"id\":\"\(invalidID)\"}".utf8))
      let (createClient, _, createAccount) = try makeClient(responses: [response])
      await #expect(throws: APIError.decoding) {
        _ = try await createClient.createPodcast(
          account: createAccount,
          libraryID: "library-podcast",
          folderID: "folder-one",
          path: "/podcasts/show-one",
          title: "Show One",
          author: nil,
          feedURL: "https://feeds.example/show.xml"
        )
      }
    }
  }

  @Test("publishedAt rejects values outside the exact epoch-millisecond range")
  func rejectsTrappingPublishedAtConversion() async throws {
    let (client, http, account) = try makeClient(responses: [])
    await #expect(throws: PodcastWriteError.invalidValue(field: .publishedAt)) {
      try await client.enqueuePodcastEpisode(
        account: account,
        itemID: "show-one",
        episode: PodcastEpisodeDownloadRequest(
          enclosureURL: "https://cdn.example/episode.mp3",
          publishedAt: Date(timeIntervalSince1970: 9.223372036854776e15)
        )
      )
    }
    #expect(http.requests.isEmpty)
  }

  @Test("publishedAt also emits the RFC 822 pubDate spelling")
  func encodesPublishedAtAsPubDate() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])
    let publishedAt = Date(timeIntervalSince1970: 1_780_308_000)
    try await client.enqueuePodcastEpisode(
      account: account,
      itemID: "show-one",
      episode: PodcastEpisodeDownloadRequest(
        enclosureURL: "https://cdn.example/episode.mp3", publishedAt: publishedAt
      )
    )

    let body = try #require(http.requests.first?.body)
    let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    let payload = try #require(array.first)
    #expect(payload["pubDate"] as? String == "Mon, 01 Jun 2026 10:00:00 GMT")
    #expect(payload["publishedAt"] as? Int64 == 1_780_308_000_000)
  }

  @Test("enqueue sends exactly one bounded episode and accepts the normal empty 200 body")
  func enqueuesExactlyOneEpisode() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])
    let publishedAt = Date(timeIntervalSince1970: 1_780_740_000)
    let episode = PodcastEpisodeDownloadRequest(
      title: "Episode One",
      description: "A short synopsis",
      subtitle: "",
      enclosureURL: "https://cdn.example/episode-one.mp3",
      enclosureType: "audio/mpeg",
      declaredBytes: 24_521,
      publishedAt: publishedAt,
      guid: "guid-one",
      seasonNumber: "1",
      episodeNumber: "1"
    )

    try await client.enqueuePodcastEpisode(account: account, itemID: "show-one", episode: episode)

    let request = try #require(http.requests.first)
    #expect(request.method == .post)
    #expect(request.url.path == "/api/podcasts/show-one/download-episodes")
    #expect(request.routeTemplate == "/api/podcasts/:id/download-episodes")
    let body = try #require(request.body)
    let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    #expect(array.count == 1)
    let payload = try #require(array.first)
    #expect(payload["title"] as? String == "Episode One")
    #expect(payload["description"] as? String == "A short synopsis")
    #expect(payload["subtitle"] as? String == "")
    #expect(payload["guid"] as? String == "guid-one")
    #expect(payload["season"] as? String == "1")
    #expect(payload["episode"] as? String == "1")
    #expect(payload["publishedAt"] as? Int64 == 1_780_740_000_000)
    let enclosure = try #require(payload["enclosure"] as? [String: Any])
    #expect(enclosure["url"] as? String == "https://cdn.example/episode-one.mp3")
    #expect(enclosure["type"] as? String == "audio/mpeg")
    #expect(enclosure["length"] as? String == "24521")
    #expect(payload["episodesToDownload"] == nil)
    #expect(String(describing: request).contains("cdn.example") == false)
  }

  @Test("enqueue omits absent optional fields instead of sending nulls")
  func enqueueOmitsOptionalFields() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])
    try await client.enqueuePodcastEpisode(
      account: account,
      itemID: "show-one",
      episode: PodcastEpisodeDownloadRequest(
        title: "Episode One", description: nil, enclosureURL: "https://cdn.example/one.mp3"
      )
    )

    let body = try #require(http.requests.first?.body)
    let array = try #require(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
    let payload = try #require(array.first)
    #expect(Set(payload.keys) == ["enclosure", "title"])
    #expect(payload.values.contains { $0 is NSNull } == false)
  }

  @Test("hard removal uses the exact episode route, hard=1, and validates an empty 200")
  func removesPodcastEpisode() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.removePodcastEpisode(
      account: account, itemID: "show-one", episodeID: "episode-one")

    let request = try #require(http.requests.first)
    #expect(request.method == .delete)
    #expect(request.url.path == "/api/podcasts/show-one/episode/episode-one")
    #expect(request.routeTemplate == "/api/podcasts/:id/episode/:episodeId")
    #expect(queryItems(of: request)["hard"] == "1")
    #expect(request.body == nil)
  }

  @Test("maps the typed bad-request and other endpoint status categories")
  func mapsEndpointStatuses() async throws {
    let statuses = [400, 401, 403, 404, 429, 500]
    for status in statuses {
      let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
      let (client, _, account) = try makeClient(responses: [response], refreshToken: nil)
      let expected: APIError =
        switch status {
        case 400: .badRequest
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        default: .serverFailure(statusCode: status)
        }
      await #expect(throws: expected) {
        try await client.removePodcastEpisode(
          account: account, itemID: "show-one", episodeID: "episode-one")
      }
    }
  }

  @Test("create refreshes once and resends the identical request with rotated credentials")
  func createRefreshesOnceAndResendsIdentically() async throws {
    let success = jsonResponse(body: Data(#"{"id":"created-item"}"#.utf8))
    try await assertSingleRefresh(
      finalResponse: success,
      expectedMethod: .post,
      expectedRoute: "/api/podcasts",
      operation: { client, account in
        _ = try await client.createPodcast(
          account: account,
          libraryID: "library-podcast",
          folderID: "folder-one",
          path: "/podcasts/show-one",
          title: "Show One",
          author: nil,
          feedURL: "https://feeds.example/show.xml"
        )
      }
    )
  }

  @Test("create stops after one resend when the refreshed request is still unauthorized")
  func createDoesNotRetryASecond401() async throws {
    try await assertSingleRefresh(
      finalResponse: unauthorizedResponse(),
      expectedMethod: .post,
      expectedRoute: "/api/podcasts",
      expectsUnauthorized: true,
      operation: { client, account in
        _ = try await client.createPodcast(
          account: account,
          libraryID: "library-podcast",
          folderID: "folder-one",
          path: "/podcasts/show-one",
          title: "Show One",
          author: nil,
          feedURL: "https://feeds.example/show.xml"
        )
      }
    )
  }

  @Test("enqueue refreshes once and resends the identical request with rotated credentials")
  func enqueueRefreshesOnceAndResendsIdentically() async throws {
    try await assertSingleRefresh(
      finalResponse: emptyResponse(),
      expectedMethod: .post,
      expectedRoute: "/api/podcasts/:id/download-episodes",
      operation: { client, account in
        try await client.enqueuePodcastEpisode(
          account: account,
          itemID: "show-one",
          episode: PodcastEpisodeDownloadRequest(
            title: "Episode One", enclosureURL: "https://cdn.example/episode-one.mp3")
        )
      }
    )
  }

  @Test("enqueue stops after one resend when the refreshed request is still unauthorized")
  func enqueueDoesNotRetryASecond401() async throws {
    try await assertSingleRefresh(
      finalResponse: unauthorizedResponse(),
      expectedMethod: .post,
      expectedRoute: "/api/podcasts/:id/download-episodes",
      expectsUnauthorized: true,
      operation: { client, account in
        try await client.enqueuePodcastEpisode(
          account: account,
          itemID: "show-one",
          episode: PodcastEpisodeDownloadRequest(
            title: "Episode One", enclosureURL: "https://cdn.example/episode-one.mp3")
        )
      }
    )
  }

  @Test("remove refreshes once and resends the identical request with rotated credentials")
  func removeRefreshesOnceAndResendsIdentically() async throws {
    try await assertSingleRefresh(
      finalResponse: emptyResponse(),
      expectedMethod: .delete,
      expectedRoute: "/api/podcasts/:id/episode/:episodeId",
      operation: { client, account in
        try await client.removePodcastEpisode(
          account: account, itemID: "show-one", episodeID: "episode-one")
      }
    )
  }

  @Test("remove stops after one resend when the refreshed request is still unauthorized")
  func removeDoesNotRetryASecond401() async throws {
    try await assertSingleRefresh(
      finalResponse: unauthorizedResponse(),
      expectedMethod: .delete,
      expectedRoute: "/api/podcasts/:id/episode/:episodeId",
      expectsUnauthorized: true,
      operation: { client, account in
        try await client.removePodcastEpisode(
          account: account, itemID: "show-one", episodeID: "episode-one")
      }
    )
  }

  @Test("enqueue logging omits payload values for success, forbidden, and transport outcomes")
  func enqueueMutationLoggingDoesNotExposePayload() async throws {
    let operation: PodcastMutationOperation = { client, account in
      try await client.enqueuePodcastEpisode(
        account: account,
        itemID: "show-secret",
        episode: PodcastEpisodeDownloadRequest(
          title: "Episode title secret", enclosureURL: "https://cdn.example/private.mp3")
      )
    }
    let secrets = [
      "show-secret", "episode-secret", "private.mp3", "Episode title secret", "hard=1",
      "canary-access",
    ]

    try await assertRedactedMutation(
      responses: [emptyResponse()],
      expectedLog: "status=200",
      method: .post,
      route: "/api/podcasts/:id/download-episodes",
      secrets: secrets,
      operation: operation
    )
    try await assertRedactedMutation(
      responses: [HTTPResponse(statusCode: 403, headers: [:], body: Data())],
      expectedLog: "status=403",
      method: .post,
      route: "/api/podcasts/:id/download-episodes",
      secrets: secrets,
      expectedError: .forbidden,
      operation: operation
    )
    try await assertRedactedMutation(
      responses: [],
      expectedLog: "status=error",
      method: .post,
      route: "/api/podcasts/:id/download-episodes",
      secrets: secrets,
      expectedError: .transport,
      transportFailure: URLError(.timedOut),
      operation: operation
    )
  }

  @Test("remove logging redacts identifiers for every outcome")
  func removeMutationLoggingDoesNotExposePayload() async throws {
    let operation: PodcastMutationOperation = { client, account in
      try await client.removePodcastEpisode(
        account: account, itemID: "show-secret", episodeID: "episode-secret")
    }
    let secrets = [
      "show-secret", "episode-secret", "private.mp3", "Episode title secret", "hard=1",
      "canary-access",
    ]

    try await assertRedactedMutation(
      responses: [emptyResponse()],
      expectedLog: "status=200",
      method: .delete,
      route: "/api/podcasts/:id/episode/:episodeId",
      secrets: secrets,
      operation: operation
    )
    try await assertRedactedMutation(
      responses: [HTTPResponse(statusCode: 403, headers: [:], body: Data())],
      expectedLog: "status=403",
      method: .delete,
      route: "/api/podcasts/:id/episode/:episodeId",
      secrets: secrets,
      expectedError: .forbidden,
      operation: operation
    )
    try await assertRedactedMutation(
      responses: [],
      expectedLog: "status=error",
      method: .delete,
      route: "/api/podcasts/:id/episode/:episodeId",
      secrets: secrets,
      expectedError: .transport,
      transportFailure: URLError(.timedOut),
      operation: operation
    )
  }

  @Test("an oversized folder id drops only that folder")
  func oversizedFolderIDIsDropped() async throws {
    let oversizedID = String(
      repeating: "i", count: EndpointDecodeLimits.standard.maximumListStringBytes + 1)
    let envelope: [String: Any] = [
      "libraries": [
        [
          "id": "library-podcast", "name": "Podcasts", "mediaType": "podcast",
          "folders": [["id": oversizedID, "fullPath": "/podcasts"]],
        ]
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let libraries = try await client.listLibraries(account: account)

    #expect(libraries.count == 1)
    #expect(libraries[0].folders.isEmpty)
  }

  @Test("an oversized folder path drops only that folder")
  func oversizedFolderPathIsDropped() async throws {
    let oversizedPath =
      "/"
      + String(
        repeating: "p", count: EndpointDecodeLimits.standard.maximumListStringBytes)
    let envelope: [String: Any] = [
      "libraries": [
        [
          "id": "library-podcast", "name": "Podcasts", "mediaType": "podcast",
          "folders": [["id": "folder-one", "fullPath": oversizedPath]],
        ]
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let libraries = try await client.listLibraries(account: account)

    #expect(libraries.count == 1)
    #expect(libraries[0].folders.isEmpty)
  }

  @Test("an oversized minified podcast feed URL is dropped without dropping the item")
  func oversizedMinifiedFeedURLIsDropped() async throws {
    let oversizedURL =
      "https://feeds.example/"
      + String(
        repeating: "f", count: EndpointDecodeLimits.standard.maximumListStringBytes)
    let envelope: [String: Any] = [
      "results": [
        [
          "id": "podcast-one", "libraryId": "library-podcast", "mediaType": "podcast",
          "media": ["metadata": ["title": "Show", "feedUrl": oversizedURL]],
        ]
      ],
      "total": 1, "limit": 1, "page": 0,
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let page = try await client.listLibraryItems(account: account, library: "library-podcast")

    #expect(page.items.count == 1)
    #expect(page.items[0].feedURLState == .invalid)
  }

  @Test("an oversized episode GUID is dropped while the episode list remains complete")
  func oversizedEpisodeGUIDIsDroppedWithoutIncompleteness() async throws {
    let oversizedGUID = String(
      repeating: "g", count: EndpointDecodeLimits.standard.maximumListStringBytes + 1)
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "episode-one",
        "guid": oversizedGUID,
        "enclosure": ["url": "https://cdn.example/episode-one.mp3"],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "server-item")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.guid == nil)
    #expect(episode.enclosureURL == "https://cdn.example/episode-one.mp3")
    #expect(podcast.isEpisodeListStructurallyComplete)
  }

  @Test("an oversized episode enclosure URL is dropped while the episode list remains complete")
  func oversizedEpisodeEnclosureURLIsDroppedWithoutIncompleteness() async throws {
    let oversizedURL =
      "https://cdn.example/"
      + String(
        repeating: "e", count: EndpointDecodeLimits.standard.maximumListStringBytes)
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "episode-one",
        "guid": "guid-one",
        "enclosure": ["url": oversizedURL],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "server-item")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.guid == "guid-one")
    #expect(episode.enclosureURL == nil)
    #expect(podcast.isEpisodeListStructurallyComplete)
  }

  @Test("rejects credentialed URLs, non-http schemes, oversized fields, and unsafe paths before send")
  func rejectsUnsafeWriteInputs() async throws {
    let (client, http, account) = try makeClient(responses: [])

    await #expect(throws: PodcastWriteError.credentialedURL) {
      _ = try await client.createPodcast(
        account: account,
        libraryID: "library-podcast",
        folderID: "folder-one",
        path: "/podcasts/show-one",
        title: "Show One",
        author: nil,
        feedURL: "https://user:password@feeds.example/show.xml"
      )
    }
    await #expect(throws: PodcastWriteError.unsupportedURLScheme) {
      try await client.enqueuePodcastEpisode(
        account: account,
        itemID: "show-one",
        episode: PodcastEpisodeDownloadRequest(
          title: "Episode", enclosureURL: "file:///tmp/episode.mp3")
      )
    }
    await #expect(
      throws: PodcastWriteError.fieldTooLong(
        field: .enclosureURL, maximumBytes: PodcastWriteBounds.maximumStringBytes)
    ) {
      try await client.enqueuePodcastEpisode(
        account: account,
        itemID: "show-one",
        episode: PodcastEpisodeDownloadRequest(
          title: "Episode",
          enclosureURL: "https://cdn.example/"
            + String(
              repeating: "e", count: PodcastWriteBounds.maximumStringBytes) + ".mp3")
      )
    }
    await #expect(throws: PodcastWriteError.invalidPath) {
      _ = try await client.createPodcast(
        account: account,
        libraryID: "library-podcast",
        folderID: "folder-one",
        path: "../outside",
        title: "Show One",
        author: nil,
        feedURL: "https://feeds.example/show.xml"
      )
    }
    await #expect(
      throws: PodcastWriteError.fieldTooLong(
        field: .title, maximumBytes: PodcastWriteBounds.maximumStringBytes)
    ) {
      _ = try await client.createPodcast(
        account: account,
        libraryID: "library-podcast",
        folderID: "folder-one",
        path: "/podcasts/show-one",
        title: String(repeating: "x", count: PodcastWriteBounds.maximumStringBytes + 1),
        author: nil,
        feedURL: "https://feeds.example/show.xml"
      )
    }
    #expect(http.requests.isEmpty)
  }

  @Test("a cancelled task never sends a podcast mutation")
  func cancellationBeforeSend() async throws {
    let (client, http, account) = try makeClient(responses: [])
    let task = Task {
      try await client.removePodcastEpisode(
        account: account, itemID: "show-one", episodeID: "episode-one")
    }
    task.cancel()

    await #expect(throws: APIError.cancelled) {
      try await task.value
    }
    #expect(http.requests.isEmpty)
  }

  @Test("a cancelled transport error maps to APIError.cancelled")
  func cancellationDuringSendMapsToCancelled() async throws {
    let (client, _, account) = try makeClient(
      responses: [], transportFailure: URLError(.cancelled))

    await #expect(throws: APIError.cancelled) {
      try await client.removePodcastEpisode(
        account: account, itemID: "show-one", episodeID: "episode-one")
    }
  }
}

private func podcastEnvelope(episodes: [[String: Any]]) -> [String: Any] {
  [
    "id": "server-item",
    "libraryId": "library-podcast",
    "mediaType": "podcast",
    "media": [
      "metadata": ["title": "Show"],
      "episodes": episodes,
    ],
  ]
}

private func makeClient(
  responses: [HTTPResponse],
  refreshToken: String? = "canary-refresh",
  logger: RedactingHTTPLogger = RedactingHTTPLogger(),
  transportFailure: (any Error)? = nil
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let serverURL = try #require(ABSClientFixture.serverURL as URL?)
  return try ABSClientFixture.make(
    responses: responses, transportFailure: transportFailure, serverURL: serverURL,
    refreshToken: refreshToken, logger: logger)
}

private func jsonResponse(object: Any) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try JSONSerialization.data(withJSONObject: object)
  )
}

private func jsonResponse(body: Data) -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

private func emptyResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: [:], body: Data())
}

private func queryItems(of request: HTTPRequest) -> [String: String] {
  guard let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems else {
    return [:]
  }
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

private typealias PodcastMutationOperation =
  (ABSClient, TokenAccount) async throws -> Void

private func assertSingleRefresh(
  finalResponse: HTTPResponse,
  expectedMethod: HTTPMethod,
  expectedRoute: String,
  expectsUnauthorized: Bool = false,
  operation: @escaping PodcastMutationOperation
) async throws {
  let (client, http, account) = try makeClient(
    responses: [
      unauthorizedResponse(),
      makeRefreshResponse(accessToken: "rotated-access", refreshToken: "rotated-refresh"),
      finalResponse,
    ]
  )

  if expectsUnauthorized {
    await #expect(throws: APIError.unauthorized) {
      try await operation(client, account)
    }
  } else {
    try await operation(client, account)
  }

  let writeRequests = http.requests.filter { $0.routeTemplate == expectedRoute }
  let refreshRequests = http.requests.filter { $0.routeTemplate == "/auth/refresh" }
  #expect(http.requests.count == 3)
  #expect(writeRequests.count == 2)
  #expect(refreshRequests.count == 1)
  let first = try #require(writeRequests.first)
  let resend = try #require(writeRequests.last)
  #expect(first.method == expectedMethod)
  #expect(first.routeTemplate == expectedRoute)
  #expect(resend.method == first.method)
  #expect(resend.routeTemplate == first.routeTemplate)
  #expect(resend.url.path == first.url.path)
  #expect(queryItems(of: resend) == queryItems(of: first))
  #expect(resend.body == first.body)
  #expect(first.headers["Authorization"] == "Bearer canary-access")
  #expect(resend.headers["Authorization"] == "Bearer rotated-access")
  #expect(refreshRequests[0].headers["x-refresh-token"] == "canary-refresh")
}

private func assertRedactedMutation(
  responses: [HTTPResponse],
  expectedLog: String,
  method: HTTPMethod,
  route: String,
  secrets: [String],
  expectedError: APIError? = nil,
  transportFailure: (any Error)? = nil,
  operation: @escaping PodcastMutationOperation
) async throws {
  let logger = RedactingHTTPLogger()
  let (client, http, account) = try makeClient(
    responses: responses, logger: logger, transportFailure: transportFailure)

  if let expectedError {
    await #expect(throws: expectedError) {
      try await operation(client, account)
    }
  } else {
    try await operation(client, account)
  }

  let entries = await logger.formattedEntries()
  let entry = try #require(entries.first)
  #expect(entries.count == 1)
  #expect(entry.contains("\(method.rawValue) \(route)"))
  #expect(entry.contains(expectedLog))
  let request = try #require(http.requests.first)
  let descriptions = [String(describing: request), String(reflecting: request)]
  for secret in secrets {
    #expect(entry.contains(secret) == false)
    #expect(descriptions[0].contains(secret) == false)
    #expect(descriptions[1].contains(secret) == false)
  }
}

private func unauthorizedResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 401, headers: [:], body: Data())
}

private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
