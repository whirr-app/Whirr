import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/libraries/{id}/recent-episodes`. The fixture below mirrors a live v2.35.1 capture:
/// each element is a whole episode object of the same shape as one inside `media.episodes`, with
/// the parent show embedded under `podcast` and the owning item named by `libraryItemId`.
@Suite("Recent episodes")
struct RecentEpisodesTests {
  @Test("recent episodes decode with their parent show context")
  func recentEpisodesCarryShowContext() async throws {
    let harness = try Harness()
    harness.http.enqueue(Self.response(Self.page))

    let episodes = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts", limit: 25)

    #expect(episodes.count == 1)
    let first = try #require(episodes.first)
    #expect(first.libraryItemID == "item-1")
    #expect(first.showTitle == "The Rest Is History")
    #expect(first.showAuthor == "Goalhanger")
    #expect(first.episode.id == "episode-1")
    #expect(first.episode.title == "691. The Queen's Spymaster")
    #expect(first.episode.publishedAt == Date(timeIntervalSince1970: 1_785_107_100))
    #expect(first.episode.duration == 4_729.913469)
    #expect(first.episode.episodeNumber == "691")
    #expect(first.episode.audioFile?.ino == "2891448")
  }

  @Test("the request is a bounded, paged GET on the library's recent-episodes route")
  func requestShapeIsBoundedAndPaged() async throws {
    let harness = try Harness()
    harness.http.enqueue(Self.response(Self.page))

    _ = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts", page: 2, limit: 5_000)

    let request = try #require(harness.http.requests.first)
    #expect(request.url.path == "/api/libraries/lib-podcasts/recent-episodes")
    let query = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "page" }?.value == "2")
    // Rule 15's paginated-list bound, not the caller's number.
    #expect(query.first { $0.name == "limit" }?.value == "100")
  }

  /// An element with no `libraryItemId` names no local show, so nothing can be joined to it and it
  /// is dropped rather than guessed at, the same required-key rule the item routes apply to `id`.
  @Test("an element without a library item id is dropped, not guessed at")
  func elementWithoutLibraryItemIDIsDropped() async throws {
    let harness = try Harness()
    var orphan = Self.episode
    orphan["libraryItemId"] = nil
    harness.http.enqueue(Self.response(["episodes": [orphan, Self.episode]]))

    let episodes = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts")

    #expect(episodes.map(\.episode.id) == ["episode-1"])
  }

  @Test("a show with no embedded metadata still yields its episode")
  func missingShowMetadataStillYieldsTheEpisode() async throws {
    let harness = try Harness()
    var bare = Self.episode
    bare["podcast"] = nil
    harness.http.enqueue(Self.response(["episodes": [bare]]))

    let episodes = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts")

    #expect(episodes.count == 1)
    #expect(episodes.first?.showTitle == nil)
    #expect(episodes.first?.libraryItemID == "item-1")
  }

  @Test("throws when the present recent-episodes array has the wrong top-level type")
  func throwsForWrongTypeEpisodesArray() async throws {
    let harness = try Harness()
    harness.http.enqueue(Self.response(["episodes": "not-an-array"]))

    await #expect(throws: APIError.decoding) {
      try await harness.client.recentEpisodes(
        account: harness.account, library: "lib-podcasts")
    }
  }

  enum ArrayPresenceState: String, CaseIterable {
    case absent, null
  }

  @Test(
    "treats an absent or null recent-episodes array as empty",
    arguments: ArrayPresenceState.allCases
  )
  func treatsMissingOrNullEpisodesArrayAsEmpty(state: ArrayPresenceState) async throws {
    let harness = try Harness()
    var envelope: [String: Any] = ["limit": 25, "page": 0]
    if state == .null {
      envelope["episodes"] = NSNull()
    }
    harness.http.enqueue(Self.response(envelope))

    let episodes = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts")

    #expect(episodes.isEmpty)
  }

  @Test("keeps valid recent episodes when one array element is malformed")
  func keepsValidEpisodeWhenOneElementIsMalformed() async throws {
    let harness = try Harness()
    harness.http.enqueue(
      Self.response(["episodes": [Self.episode, "not-an-object", Self.episode]])
    )

    let episodes = try await harness.client.recentEpisodes(
      account: harness.account, library: "lib-podcasts")

    #expect(episodes.map(\.episode.id) == ["episode-1", "episode-1"])
  }

  private static var episode: [String: Any?] {
    [
      "id": "episode-1",
      "libraryItemId": "item-1",
      "title": "691. The Queen's Spymaster",
      "subtitle": "",
      "season": "",
      "episode": "691",
      "episodeType": "full",
      "publishedAt": 1_785_107_100_000,
      "duration": 4_729.913469,
      "size": 189_203_590,
      "audioFile": [
        "ino": "2891448",
        "mimeType": "audio/mpeg",
        "duration": 4_729.913469,
        "metadata": ["size": 189_203_590],
      ],
      "podcast": [
        "id": "podcast-1",
        "metadata": ["title": "The Rest Is History", "author": "Goalhanger"],
      ],
    ]
  }

  private static var page: [String: Any] {
    ["episodes": [episode], "limit": 25, "page": 0]
  }

  private static func response(_ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: compact(object)))
  }

  /// `JSONSerialization` rejects Swift `nil`; dropping those keys is how a fixture says "the
  /// server omitted this field".
  private static func compact(_ value: Any) -> Any {
    if let dictionary = value as? [String: Any?] {
      return dictionary.compactMapValues { $0.map(compact) }
    }
    if let array = value as? [Any] {
      return array.map(compact)
    }
    return value
  }

  private struct Harness {
    let client: ABSClient
    let http: FakeHTTPClient
    let account: TokenAccount

    init() throws {
      let server = try ABSServerConfig(url: try #require(URL(string: "https://recent.example.test")))
      account = try TokenAccount(server: server, userID: "user_fixture")
      let tokenStore = InMemoryTokenStore()
      try tokenStore.save(
        TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
      http = FakeHTTPClient()
      client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    }
  }
}
