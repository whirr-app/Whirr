import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Podcast episode and show shapes from `GET /api/items/{id}?expanded=1`, beyond the basic
/// id/title/contentUrl/mimeType/duration/publishedAt set. One episode shape only (the stored
/// episode). No feed, download-request or queue endpoint is tested here.
@Suite("Podcast endpoint decoding")
struct PodcastEndpointTests {

  // MARK: - Live fixture

  @Test("decodes the live fixture's presentation and stored-audio fields for every episode")
  func decodesLiveFixturePresentationAndStoredAudioFields() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(named: "podcast-item-expanded-live")]
    )

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_live")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.episodes.count == 12)
    #expect(podcast.isEpisodeListStructurallyComplete)

    // Diagnostic fields (stand in for a feed-check control): both present on the live capture.
    #expect(podcast.autoDownloadEpisodes == true)
    #expect(podcast.lastEpisodeCheck == Date(timeIntervalSince1970: 1_784_937_618.548))
    #expect(podcast.autoDownloadSchedule == "0 0 * * *")
    #expect(podcast.maxEpisodesToKeep == 10)
    #expect(podcast.maxNewEpisodesToDownload == 3)

    // Episode 1: unseasoned (season == ""), fully populated stored-audio identity.
    let first = try #require(podcast.episodes.first)
    #expect(first.id == "episode_live_01")
    #expect(first.subtitle == "")
    #expect(first.description?.hasPrefix("<") == true)
    #expect(first.seasonNumber == "")
    #expect(first.episodeNumber == "199")
    #expect(first.episodeType == "full")
    #expect(first.size == 106_323_431)
    #expect(first.isOfflineDownloadable == true)
    let audioFile = try #require(first.audioFile)
    #expect(audioFile.ino == "1000001")
    #expect(audioFile.expectedSize == 106_323_431)
    #expect(audioFile.mimeType == "audio/mpeg")
    #expect(audioFile.duration > 2657.0)

    // Episode 6: seasoned (season == "9"), proving both coexist in one show.
    let seasoned = try #require(podcast.episodes.first { $0.id == "episode_live_06" })
    #expect(seasoned.seasonNumber == "9")
    #expect(seasoned.episodeNumber == "1")
    #expect(seasoned.subtitle == "Sanitized subtitle 06")
  }

  @Test("absent or malformed episode arrays are distinguishable from a genuinely empty show")
  func episodeListStructuralCompletenessIsExplicit() async throws {
    var absent = podcastEnvelope(episodes: [])
    var absentMedia = try #require(absent["media"] as? [String: Any])
    absentMedia.removeValue(forKey: "episodes")
    absent["media"] = absentMedia

    var malformed = podcastEnvelope(episodes: [])
    var malformedMedia = try #require(malformed["media"] as? [String: Any])
    malformedMedia["episodes"] = "not-an-array"
    malformed["media"] = malformedMedia

    let genuinelyEmpty = podcastEnvelope(episodes: [])
    let (client, _, account) = try makeClient(
      responses: [
        jsonResponse(object: absent),
        jsonResponse(object: malformed),
        jsonResponse(object: genuinelyEmpty),
      ])

    var completeness: [Bool] = []
    for itemID in ["absent", "malformed", "empty"] {
      let detail = try await client.fetchItemDetail(account: account, itemID: itemID)
      guard case .podcast(let podcast) = try #require(detail.media) else {
        Issue.record("expected podcast media")
        return
      }
      #expect(podcast.episodes.isEmpty)
      completeness.append(podcast.isEpisodeListStructurallyComplete)
    }
    #expect(completeness == [false, false, true])
  }

  // MARK: - Absent/null/wrong-type optional fields never drop the episode

  @Test("absent, null, and wrong-type optional episode fields decode to nil without dropping the episode")
  func absentNullAndWrongTypeFieldsDoNotDropTheEpisode() async throws {
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "episode_1",
        "title": "Episode One",
        "subtitle": NSNull(),
        "description": NSNull(),
        // Wrong type: season/episode/episodeType are documented as always strings; a server that
        // ever sends numbers must not crash the decode or drop the episode.
        "season": 9,
        "episode": 1,
        "episodeType": NSNull(),
        // Wrong type: size as a non-numeric string.
        "size": "not-a-number",
        "audioTrack": ["contentUrl": NSNull(), "mimeType": NSNull()],
        "publishedAt": NSNull(),
        "duration": NSNull(),
          // audioFile entirely absent.
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.episodes.count == 1)
    let episode = try #require(podcast.episodes.first)
    #expect(episode.id == "episode_1")
    #expect(episode.title == "Episode One")
    #expect(episode.subtitle == nil)
    #expect(episode.description == nil)
    #expect(episode.seasonNumber == nil)
    #expect(episode.episodeNumber == nil)
    #expect(episode.episodeType == nil)
    #expect(episode.size == nil)
    #expect(episode.contentUrl == nil)
    #expect(episode.mimeType == nil)
    #expect(episode.publishedAt == nil)
    #expect(episode.duration == nil)
    #expect(episode.audioFile == nil)
    #expect(episode.isOfflineDownloadable == false)
  }

  // MARK: - Missing required episode id drops only that element, with a diagnostic

  @Test("drops only the episode missing its required id, recording a decode diagnostic")
  func dropsOnlyTheEpisodeMissingItsRequiredIdWithDiagnostic() async throws {
    let envelope = podcastEnvelope(episodes: [
      ["id": "episode_ok", "title": "Kept Episode"],
      ["title": "Episode Missing Id"],
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let detail = try await client.fetchItemDetail(
      account: account,
      itemID: "item_podcast_fixture",
      diagnostics: diagnostics
    )

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast.episodes.map(\.id) == ["episode_ok"])
    #expect(diagnostics.entries.isEmpty == false)
    #expect(diagnostics.entries.allSatisfy { $0.endpoint == "/api/items/:id" })
  }

  // MARK: - Bounded strings

  @Test("truncates an oversized episode description instead of rejecting or crashing")
  func truncatesOversizedEpisodeDescription() async throws {
    let longDescription = String(repeating: "a", count: 16 * 1024 + 512)
    let envelope = podcastEnvelope(episodes: [
      ["id": "episode_1", "title": "Episode One", "description": longDescription]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.description?.utf8.count == 16 * 1024)
  }

  // MARK: - Bounded arrays

  /// An episode array past `EndpointDecodeLimits.maximumArrayElements` is refused wholesale rather
  /// than silently truncated, and the refusal is reported through
  /// `isEpisodeListStructurallyComplete`, which SyncEngine uses to withhold deletion inference.
  /// Truncating would look like a show whose tail episodes were deleted.
  @Test("an oversized episode array yields no episodes and an explicitly incomplete list")
  func oversizedEpisodeArrayIsRefusedAndReportedIncomplete() async throws {
    let limit = EndpointDecodeLimits.standard.maximumArrayElements
    let (client, _, account) = try makeClient(
      responses: [
        jsonResponse(body: Self.podcastBody(episodeCount: limit)),
        jsonResponse(body: Self.podcastBody(episodeCount: limit + 1)),
      ])

    let atLimit = try await client.fetchItemDetail(account: account, itemID: "at-limit")
    guard case .podcast(let atLimitPodcast) = try #require(atLimit.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(atLimitPodcast.episodes.count == limit)
    #expect(atLimitPodcast.isEpisodeListStructurallyComplete)

    let overLimit = try await client.fetchItemDetail(account: account, itemID: "over-limit")
    guard case .podcast(let overLimitPodcast) = try #require(overLimit.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(overLimitPodcast.episodes.isEmpty)
    #expect(overLimitPodcast.isEpisodeListStructurallyComplete == false)
  }

  private static func podcastBody(episodeCount: Int) -> Data {
    let episodes = (0..<episodeCount).map { #"{"id":"episode_\#($0)"}"# }.joined(separator: ",")
    return Data(
      #"""
      {"id":"item_podcast_fixture","libraryId":"library_podcast_fixture","mediaType":"podcast",
       "media":{"metadata":{"title":"Fixture Podcast"},"episodes":[\#(episodes)]}}
      """#.utf8)
  }

  // MARK: - No stored-audio identity => not offline-downloadable

  @Test("an episode with an empty audioFile.ino decodes fine but is not offline-downloadable")
  func episodeWithEmptyInoIsNotOfflineDownloadable() async throws {
    let envelope = podcastEnvelope(episodes: [
      [
        "id": "episode_1",
        "title": "Episode One",
        "audioFile": [
          "index": 1, "ino": "", "duration": 100.0, "mimeType": "audio/mpeg",
          "metadata": ["size": 12345],
        ],
      ]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.id == "episode_1")
    #expect(episode.title == "Episode One")
    #expect(episode.audioFile == nil)
    #expect(episode.isOfflineDownloadable == false)
  }

  @Test("an episode with no audioFile key at all decodes fine but is not offline-downloadable")
  func episodeWithNoAudioFileKeyIsNotOfflineDownloadable() async throws {
    let envelope = podcastEnvelope(episodes: [
      ["id": "episode_1", "title": "Episode One"]
    ])
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")

    guard case .podcast(let podcast) = try #require(detail.media) else {
      Issue.record("expected podcast media")
      return
    }
    let episode = try #require(podcast.episodes.first)
    #expect(episode.audioFile == nil)
    #expect(episode.isOfflineDownloadable == false)
  }

  // MARK: - Diagnostic fields: lenient, absent-tolerant

  @Test("the show diagnostic fields decode leniently and are absent-tolerant")
  func showDiagnosticFieldsAreAbsentTolerant() async throws {
    // Neither field present at all.
    let envelopeMissing = podcastEnvelope(episodes: [["id": "episode_1", "title": "Episode One"]])
    let (client1, _, account1) = try makeClient(responses: [jsonResponse(object: envelopeMissing)])

    let detail1 = try await client1.fetchItemDetail(account: account1, itemID: "item_podcast_fixture")
    guard case .podcast(let podcast1) = try #require(detail1.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast1.autoDownloadEpisodes == nil)
    #expect(podcast1.lastEpisodeCheck == nil)

    let fields: [(String, (PodcastMedia) -> Bool)] = [
      ("autoDownloadSchedule", { $0.autoDownloadSchedule == nil }),
      ("maxEpisodesToKeep", { $0.maxEpisodesToKeep == nil }),
      ("maxNewEpisodesToDownload", { $0.maxNewEpisodesToDownload == nil }),
    ]
    for (field, isAbsent) in fields {
      var envelope = podcastEnvelope(episodes: [["id": "episode_1", "title": "Episode One"]])
      var media = try #require(envelope["media"] as? [String: Any])
      media["autoDownloadSchedule"] = "0 0 * * *"
      media["maxEpisodesToKeep"] = 10
      media["maxNewEpisodesToDownload"] = 3
      media.removeValue(forKey: field)
      envelope["media"] = media
      let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
      let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")
      guard case .podcast(let podcast) = try #require(detail.media) else {
        Issue.record("expected podcast media")
        return
      }
      #expect(isAbsent(podcast))
    }

    // Present but wrong type.
    var envelopeWrongType = podcastEnvelope(episodes: [["id": "episode_1", "title": "Episode One"]])
    var media = try #require(envelopeWrongType["media"] as? [String: Any])
    media["autoDownloadEpisodes"] = "not-a-bool"
    media["lastEpisodeCheck"] = "not-a-number"
    envelopeWrongType["media"] = media
    let (client2, _, account2) = try makeClient(responses: [jsonResponse(object: envelopeWrongType)])

    let detail2 = try await client2.fetchItemDetail(account: account2, itemID: "item_podcast_fixture")
    guard case .podcast(let podcast2) = try #require(detail2.media) else {
      Issue.record("expected podcast media")
      return
    }
    #expect(podcast2.autoDownloadEpisodes == nil)
    #expect(podcast2.lastEpisodeCheck == nil)
  }

  @Test("each new show diagnostic field degrades independently when present with the wrong type")
  func newShowDiagnosticFieldsAreLossyForWrongTypes() async throws {
    let fields: [(String, Any, (PodcastMedia) -> Bool)] = [
      ("autoDownloadSchedule", 123, { $0.autoDownloadSchedule == nil }),
      ("maxEpisodesToKeep", "not-an-int", { $0.maxEpisodesToKeep == nil }),
      ("maxNewEpisodesToDownload", "not-an-int", { $0.maxNewEpisodesToDownload == nil }),
    ]

    for (field, wrongValue, isNil) in fields {
      var envelope = podcastEnvelope(episodes: [["id": "episode_1", "title": "Episode One"]])
      var media = try #require(envelope["media"] as? [String: Any])
      media["autoDownloadSchedule"] = "0 0 * * *"
      media["maxEpisodesToKeep"] = 10
      media["maxNewEpisodesToDownload"] = 3
      media[field] = wrongValue
      envelope["media"] = media
      let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
      let detail = try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")
      guard case .podcast(let podcast) = try #require(detail.media) else {
        Issue.record("expected podcast media")
        return
      }
      #expect(isNil(podcast))
    }
  }

  // MARK: - Non-2xx handling and route-template redaction

  @Test("a 404 for the podcast item surfaces APIError.notFound")
  func notFoundSurfacesAPIError() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())]
    )

    await #expect(throws: APIError.notFound) {
      try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")
    }
  }

  @Test("a 500 for the podcast item surfaces APIError.serverFailure")
  func serverFailureSurfacesAPIError() async throws {
    let (client, _, account) = try makeClient(
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())]
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      try await client.fetchItemDetail(account: account, itemID: "item_podcast_fixture")
    }
  }

  @Test("the request route template redacts the item id")
  func routeTemplateRedactsItemID() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(named: "podcast-item-expanded-live")]
    )

    _ = try await client.fetchItemDetail(account: account, itemID: "item_podcast_live")

    #expect(http.requests.count == 1)
    #expect(http.requests[0].routeTemplate == "/api/items/:id")
    // The route template, which is what reaches logs and diagnostics, never contains the raw id,
    // even though the actual request URL (not logged verbatim) does.
    #expect(http.requests[0].routeTemplate.contains("item_podcast_live") == false)
  }
}

// MARK: - Helpers

private func podcastEnvelope(episodes: [[String: Any]]) -> [String: Any] {
  [
    "id": "item_podcast_fixture",
    "libraryId": "library_podcast_fixture",
    "mediaType": "podcast",
    "media": [
      "metadata": [
        "title": "Fixture Podcast",
        "author": "Fixture Publisher",
      ],
      "episodes": episodes,
    ],
  ]
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

private func jsonResponse(body: Data) -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

private func jsonResponse(object: Any) throws -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "application/json"],
    body: try JSONSerialization.data(withJSONObject: object)
  )
}
