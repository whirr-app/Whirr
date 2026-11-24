import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Playback-session endpoints. These are endpoint/payload builders only, exercised against the
/// sanitised direct-play capture and a minimal transcode fixture. No live playback is started.
@Suite("Playback session endpoints")
struct SessionTests {

  // MARK: - Starting a session

  @Test("defaults plain /play to transcode and exposes its HLS stream")
  func defaultsPlainPlaybackToTranscodeAndDecodesHLSStream() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-transcode-response"))]
    )

    let session = try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .post)
    #expect(http.requests[0].url.path == "/api/items/item_book_fixture/play")
    #expect(http.requests[0].routeTemplate == "/api/items/:id/play")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")

    #expect(session.id == "session_transcode_fixture")
    #expect(session.libraryItemID == "item_book_fixture")
    #expect(session.episodeID == nil)
    #expect(session.mediaType == "book")
    #expect(session.displayTitle == "Fixture Book")
    #expect(session.displayAuthor == "Fixture Author")
    #expect(session.duration == 11670.881451)
    #expect(session.currentTime == 120.25)
    #expect(session.playMethod == 2)
    #expect(session.deviceID == "device_id_fixture")
    #expect(session.audioTracks.count == 1)
    let track = try #require(session.audioTracks.first)
    // Decoding succeeding proves PlaybackStreamResource.resolve accepted the transcode URL; the
    // resolver has its own path tests.
    #expect(track.stream.url.path == "/hls/session_transcode_fixture/output.m3u8")
    // No token or query credential survives into a resolved stream URL.
    #expect(session.audioTracks.allSatisfy { $0.stream.url.query == nil })

    #expect(session.chapters.count == 5)
    #expect(session.chapters.first?.id == 0)
    #expect(session.chapters.first?.start == 0)
    #expect(session.chapters.first?.end == 2679.901678)
    #expect(session.chapters.first?.title == "Fixture Chapter 1")
    #expect(session.chapters.last?.id == 4)
    #expect(session.chapters.last?.title == "Fixture Chapter 5")
  }

  @Test("forceDirectPlay requests and decodes the direct-play track shape")
  func forceDirectPlayRequestsDirectPlayback() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-response"))]
    )

    let session = try await client.startPlaybackSession(
      account: account,
      itemID: "item_book_fixture",
      options: StartPlaybackSessionOptions(forceDirectPlay: true)
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["forceDirectPlay"] as? Bool == true)
    #expect(session.playMethod == 0)
    // Multi-file direct-play shape, as seen on a device: 1-based track index and a bare
    // `/api/items/{id}/file/{ino}` content URL with no `/download` suffix. The ino is not a
    // 0-based index.
    #expect(
      session.audioTracks.map { $0.stream.url.path } == [
        "/api/items/item_book_fixture/file/101",
        "/api/items/item_book_fixture/file/102",
        "/api/items/item_book_fixture/file/103",
        "/api/items/item_book_fixture/file/104",
        "/api/items/item_book_fixture/file/105",
      ])
    #expect(session.audioTracks.map(\.index) == [1, 2, 3, 4, 5])
    #expect(
      session.audioTracks.map(\.startOffset) == [
        0, 2679.901678, 5340.681723, 8015.071564, 10544.612426,
      ])
    #expect(session.audioTracks.first?.duration == 2679.901678)
    #expect(session.audioTracks.first?.title == "Fixture Track 1")
    #expect(session.audioTracks.first?.mimeType == "audio/mpeg")
    #expect(session.audioTracks.allSatisfy { $0.stream.url.query == nil })
  }

  @Test("drops a malformed chapter element while keeping the well-formed ones (lossy, never throws)")
  func dropsMalformedChapterElementLossily() async throws {
    let envelope: [String: Any] = [
      "id": "session_fixture",
      "audioTracks": [
        ["contentUrl": "/api/items/item_book_fixture/file/101"]
      ],
      "chapters": [
        ["id": 0, "start": 0, "end": 100, "title": "Chapter 1"],
        ["id": 1, "start": "not-a-number", "end": 200, "title": "Malformed start"],
        ["id": 2, "title": "Missing start and end"],
        ["id": 3, "start": 200, "end": 300, "title": "Chapter 4"],
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let session = try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")

    #expect(session.chapters.map(\.id) == [0, 3])
  }

  @Test("drops a track with a missing or hostile content URL while keeping usable tracks (lossy)")
  func dropsUnusableTrackLossily() async throws {
    let envelope: [String: Any] = [
      "id": "session_fixture",
      "audioTracks": [
        ["index": 1, "contentUrl": "/api/items/item_book_fixture/file/101"],
        ["index": 2],
        ["index": 3, "contentUrl": "https://evil.example.test/steal"],
        ["index": 4, "contentUrl": "/api/items/item_book_fixture/file/104"],
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let session = try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")

    #expect(session.audioTracks.map(\.index) == [1, 4])
  }

  enum PlaybackSessionArrayField: String, CaseIterable {
    case audioTracks, chapters
  }

  @Test(
    "throws when a present playback-session array has the wrong top-level type",
    arguments: PlaybackSessionArrayField.allCases
  )
  func throwsForWrongTypePlaybackSessionArray(field: PlaybackSessionArrayField) throws {
    let object: [String: Any] = [
      "id": "session_fixture",
      field.rawValue: "not-an-array",
    ]
    let data = try JSONSerialization.data(withJSONObject: object)

    #expect(throws: APIError.decoding) {
      try BoundedDecoder().decode(
        PlaybackSessionDTO.self,
        from: data,
        endpoint: "/api/session/:id/play"
      )
    }
  }

  @Test(
    "treats an absent or null playback-session array as empty",
    arguments: PlaybackSessionArrayField.allCases, [false, true]
  )
  func treatsMissingOrNullPlaybackSessionArrayAsEmpty(
    field: PlaybackSessionArrayField, isNull: Bool
  ) throws {
    var object: [String: Any] = ["id": "session_fixture"]
    if isNull {
      object[field.rawValue] = NSNull()
    }
    let data = try JSONSerialization.data(withJSONObject: object)

    let session = try BoundedDecoder().decode(
      PlaybackSessionDTO.self,
      from: data,
      endpoint: "/api/session/:id/play"
    )

    switch field {
    case .audioTracks:
      #expect(session.audioTracks.isEmpty)
    case .chapters:
      #expect(session.chapters.isEmpty)
    }
  }

  @Test("fails closed when a session has an id but zero usable streams survive mapping")
  func failsClosedWithNoUsableStream() async throws {
    let envelope: [String: Any] = [
      "id": "session_fixture",
      "audioTracks": [
        ["index": 1],
        ["index": 2, "contentUrl": "https://evil.example.test/steal"],
      ],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")
    }
  }

  @Test("fails closed when a session has an id but no audioTracks at all")
  func failsClosedWithNoAudioTracksField() async throws {
    let envelope: [String: Any] = ["id": "session_fixture"]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")
    }
  }

  @Test("POSTs /api/items/{id}/play/{episodeId} when an episode id is supplied")
  func startsEpisodePlaybackSessionAtEpisodeScopedPath() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-response"))]
    )

    _ = try await client.startPlaybackSession(
      account: account,
      itemID: "item_book_fixture",
      episodeID: "episode_fixture"
    )

    #expect(http.requests[0].url.path == "/api/items/item_book_fixture/play/episode_fixture")
    #expect(http.requests[0].routeTemplate == "/api/items/:id/play/:episodeId")
  }

  @Test("encodes device info and force-play options into the play request body")
  func encodesStartPlaybackSessionOptions() async throws {
    let (client, http, account) = try makeClient(
      responses: [jsonResponse(data: Fixtures.data(named: "session-play-response"))]
    )

    _ = try await client.startPlaybackSession(
      account: account,
      itemID: "item_book_fixture",
      options: StartPlaybackSessionOptions(
        deviceID: "device_fixture",
        clientVersion: "1.0.0",
        forceDirectPlay: true,
        supportedMimeTypes: ["audio/mp4"],
        mediaPlayer: "avplayer"
      )
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["forceDirectPlay"] as? Bool == true)
    #expect(object["supportedMimeTypes"] as? [String] == ["audio/mp4"])
    #expect(object["mediaPlayer"] as? String == "avplayer")
    let deviceInfo = try #require(object["deviceInfo"] as? [String: Any])
    #expect(deviceInfo["deviceId"] as? String == "device_fixture")
    #expect(deviceInfo["clientVersion"] as? String == "1.0.0")
  }

  @Test("throws a decoding error when the response is missing the required session id")
  func throwsWhenSessionIdMissing() async throws {
    let envelope: [String: Any] = ["mediaType": "book"]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    await #expect(throws: APIError.decoding) {
      try await client.startPlaybackSession(account: account, itemID: "item_book_fixture")
    }
  }

  // MARK: - Syncing a session

  @Test("POSTs /api/session/{id}/sync with currentTime and the delta encoded as timeListened")
  func syncsSessionEncodingDeltaAsTimeListened() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.syncPlaybackSession(
      account: account,
      sessionID: "session_fixture",
      update: SessionSyncUpdate(currentTime: 135.0, deltaSeconds: 15.0)
    )

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .post)
    #expect(http.requests[0].url.path == "/api/session/session_fixture/sync")
    #expect(http.requests[0].routeTemplate == "/api/session/:id/sync")
    #expect(http.requests[0].transportClass == .progressSync)
    #expect(http.requests[0].timeout == 15)

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    // `timeListened` is the delta since the last acknowledged sync, never cumulative. The wire key
    // is `timeListened`; the public initialiser calls it `deltaSeconds` to make that explicit.
    #expect(object["currentTime"] as? Double == 135.0)
    #expect(object["timeListened"] as? Double == 15.0)
    #expect(object["deltaSeconds"] == nil)
  }

  @Test("includes an optional duration fallback in the sync body when supplied")
  func syncIncludesOptionalDuration() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.syncPlaybackSession(
      account: account,
      sessionID: "session_fixture",
      update: SessionSyncUpdate(currentTime: 10, deltaSeconds: 10, duration: 3600)
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["duration"] as? Double == 3600)
  }

  @Test("sync succeeds against a 200 response carrying no JSON body")
  func syncSucceedsWithEmptyResponseBody() async throws {
    let (client, _, account) = try makeClient(responses: [emptyResponse()])

    try await client.syncPlaybackSession(
      account: account,
      sessionID: "session_fixture",
      update: SessionSyncUpdate(currentTime: 10, deltaSeconds: 10)
    )
  }

  // MARK: - Closing a session

  @Test("POSTs /api/session/{id}/close with no body when no final position is given")
  func closesSessionWithoutFinalPosition() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.closePlaybackSession(account: account, sessionID: "session_fixture")

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .post)
    #expect(http.requests[0].url.path == "/api/session/session_fixture/close")
    #expect(http.requests[0].routeTemplate == "/api/session/:id/close")
    #expect(http.requests[0].body == nil)
    #expect(http.requests[0].transportClass == .progressSync)
  }

  @Test("POSTs /api/session/{id}/close carrying the final position when supplied")
  func closesSessionWithFinalPosition() async throws {
    let (client, http, account) = try makeClient(responses: [emptyResponse()])

    try await client.closePlaybackSession(
      account: account,
      sessionID: "session_fixture",
      finalPosition: SessionSyncUpdate(currentTime: 200.0, deltaSeconds: 5.0)
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(object["currentTime"] as? Double == 200.0)
    #expect(object["timeListened"] as? Double == 5.0)
  }

  // MARK: - Local/offline batch sync

  @Test("POSTs a bounded batch of local sessions to /api/session/local-all with sessions+deviceInfo")
  func postsLocalAllBatch() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "local_one", "success": true, "progressSynced": true],
        ["id": "local_two", "success": true, "progressSynced": true],
      ]
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let sessions = [makeLocalSession(id: "local_one"), makeLocalSession(id: "local_two")]

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: sessions,
      deviceInfo: ["deviceId": "device_fixture"]
    )

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .post)
    #expect(http.requests[0].url.path == "/api/session/local-all")
    #expect(http.requests[0].routeTemplate == "/api/session/local-all")
    #expect(http.requests[0].transportClass == .progressSync)

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let wireSessions = try #require(object["sessions"] as? [[String: Any]])
    // The client-generated stable id is round-tripped verbatim. This layer never calls
    // UUID()/Date() to mint or rewrite an id.
    #expect(wireSessions.map { $0["id"] as? String } == ["local_one", "local_two"])
    let deviceInfo = try #require(object["deviceInfo"] as? [String: String])
    #expect(deviceInfo["deviceId"] == "device_fixture")

    #expect(outcome.acknowledged == ["local_one", "local_two"])
    #expect(outcome.unacknowledged.isEmpty)
  }

  @Test("carries each local session's own start position as `startTime`, omitting it when unknown")
  func postsLocalAllBatchWithStartTime() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "local_one", "success": true],
        ["id": "local_two", "success": true],
      ]
    ]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    _ = try await client.syncLocalSessions(
      account: account,
      sessions: [
        makeLocalSession(id: "local_one", startTime: 19_520.5),
        makeLocalSession(id: "local_two"),
      ]
    )

    let body = try #require(http.requests[0].body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let wireSessions = try #require(object["sessions"] as? [[String: Any]])
    #expect(wireSessions[0]["startTime"] as? Double == 19_520.5)
    // Absent, never `0`. The server persists what the payload carries, so a zero would claim the
    // session began at the start of the book.
    #expect(wireSessions[1]["startTime"] == nil)
  }

  @Test("rejects a local-all batch over the bound without a network call")
  func rejectsLocalAllBatchOverTheBound() async throws {
    let (client, http, account) = try makeClient(responses: [])
    let sessions = (0..<(LocalSessionSyncBounds.maximum + 1)).map { makeLocalSession(id: "local_\($0)") }

    await #expect(
      throws: LocalSessionSyncError.tooManySessions(
        requested: sessions.count,
        maximum: LocalSessionSyncBounds.maximum
      )
    ) {
      try await client.syncLocalSessions(account: account, sessions: sessions)
    }
    #expect(http.requests.isEmpty)
  }

  @Test("returns an empty outcome without a network call for an empty batch")
  func returnsEmptyOutcomeForEmptyBatch() async throws {
    let (client, http, account) = try makeClient(responses: [])

    let outcome = try await client.syncLocalSessions(account: account, sessions: [])

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged.isEmpty)
    #expect(http.requests.isEmpty)
  }

  @Test("leaves a session unacknowledged when the results array is empty")
  func leavesUnacknowledgedForEmptyResultsArray() async throws {
    let envelope: [String: Any] = ["results": [[String: Any]]()]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one")]
    )

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged == ["local_one"])
  }

  @Test("leaves a session unacknowledged when its id is missing from a non-empty results array")
  func leavesUnacknowledgedWhenIdMissingFromResults() async throws {
    let envelope: [String: Any] = [
      "results": [["id": "local_other", "success": true]]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one")]
    )

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged == ["local_one"])
  }

  @Test("leaves a session unacknowledged when its id appears more than once in results")
  func leavesUnacknowledgedWhenIdDuplicatedInResults() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "local_one", "success": true],
        ["id": "local_one", "success": true],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one")]
    )

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged == ["local_one"])
  }

  @Test("leaves a session unacknowledged when success is false")
  func leavesUnacknowledgedWhenSuccessIsFalse() async throws {
    let envelope: [String: Any] = [
      "results": [["id": "local_one", "success": false, "error": "conflict"]]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one")]
    )

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged == ["local_one"])
  }

  @Test("leaves a session unacknowledged, without throwing, when success has no explicit marker")
  func leavesUnacknowledgedWithoutThrowingForHostileShape() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["id": "local_one", "success": NSNull()],
        ["id": "local_two", "success": "yes"],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one"), makeLocalSession(id: "local_two")]
    )

    #expect(outcome.acknowledged.isEmpty)
    #expect(outcome.unacknowledged == ["local_one", "local_two"])
  }

  @Test("a row with no id at all never crashes decoding and never falsely acknowledges anything")
  func rowWithoutIdIsIgnoredDuringDecode() async throws {
    let envelope: [String: Any] = [
      "results": [
        ["success": true],
        ["id": "local_one", "success": true],
      ]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let outcome = try await client.syncLocalSessions(
      account: account,
      sessions: [makeLocalSession(id: "local_one")]
    )

    #expect(outcome.acknowledged == ["local_one"])
  }
}

private func makeLocalSession(id: String, startTime: Double? = nil) -> LocalPlaybackSession {
  LocalPlaybackSession(
    id: id,
    libraryItemID: "item_book_fixture",
    startTime: startTime,
    currentTime: 42,
    timeListening: 42,
    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
  )
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

private func jsonResponse(data: Data) -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: data)
}

private func emptyResponse() -> HTTPResponse {
  HTTPResponse(statusCode: 200, headers: [:], body: Data())
}
