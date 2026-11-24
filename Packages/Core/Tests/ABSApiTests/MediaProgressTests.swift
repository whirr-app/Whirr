import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /api/me` reads (API-CONVENTIONS rule 11). The public `MediaProgress` type never carries
/// the wire `id`/`userId` fields forward, so a progress write can't round-trip the server's own
/// primary key into a PATCH body (the corruption bug in issue #5188).
@Suite("Media progress reads")
struct MediaProgressTests {

  @Test("fetching media progress throws unauthorized when no tokens are stored for the account")
  func fetchingMediaProgressWithoutStoredTokensThrowsUnauthorized() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: InMemoryTokenStore())

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.fetchUserMediaProgress(account: account)
    }
  }

  @Test("requests /api/me with bearer auth and decodes an audio progress row with epoch-ms fields")
  func decodesAudioProgressWithEpochMsConversion() async throws {
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let envelope: [String: Any] = ["mediaProgresses": [progress]]
    let (client, http, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .get)
    #expect(http.requests[0].url.path == "/api/me")
    #expect(http.requests[0].routeTemplate == "/api/me")
    #expect(http.requests[0].headers["Authorization"] == "Bearer canary-access")

    let entry = try #require(entries.first)
    #expect(entries.count == 1)
    #expect(entry.libraryItemID == "item_book_fixture")
    #expect(entry.episodeID == nil)
    #expect(entry.mediaItemID == "media_book_fixture")
    #expect(entry.mediaItemType == "book")
    #expect(entry.duration == 0)
    #expect(entry.progress == 0)
    #expect(entry.currentTime == 0)
    #expect(entry.isFinished == false)
    #expect(entry.hideFromContinueListening == false)
    #expect(entry.ebookLocation == nil)
    #expect(entry.ebookProgress == nil)
    #expect(entry.lastUpdate == Date(timeIntervalSince1970: 0))
    #expect(entry.startedAt == Date(timeIntervalSince1970: 0))
    #expect(entry.finishedAt == nil)
  }

  @Test("decodes the server's hidden Continue Series ids with progress")
  func decodesHiddenContinueSeriesIDs() async throws {
    let envelope: [String: Any] = [
      "mediaProgresses": [["libraryItemId": "item_book_fixture"]],
      "seriesHideFromContinueListening": ["series-one", "series-two"],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.map(\.libraryItemID) == ["item_book_fixture"])
    #expect(snapshot.hiddenSeriesIDs == ["series-one", "series-two"])
  }

  @Test("an absent hidden Continue Series list defaults to empty")
  func absentHiddenContinueSeriesListDefaultsToEmpty() async throws {
    let envelope: [String: Any] = [
      "mediaProgresses": [["libraryItemId": "item_book_fixture"]]
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.hiddenSeriesIDs.isEmpty)
  }

  @Test("a null hidden Continue Series list defaults to empty")
  func nullHiddenContinueSeriesListDefaultsToEmpty() async throws {
    let envelope: [String: Any] = [
      "mediaProgresses": [["libraryItemId": "item_book_fixture"]],
      "seriesHideFromContinueListening": NSNull(),
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.hiddenSeriesIDs.isEmpty)
  }

  @Test("a wrong-typed hidden Continue Series list defaults to empty")
  func wrongTypedHiddenContinueSeriesListDefaultsToEmpty() async throws {
    let envelope: [String: Any] = [
      "mediaProgresses": [["libraryItemId": "item_book_fixture"]],
      "seriesHideFromContinueListening": "not-an-array",
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.hiddenSeriesIDs.isEmpty)
  }

  @Test("non-string or empty hidden Continue Series elements are discarded")
  func malformedHiddenContinueSeriesElementsDefaultToEmpty() async throws {
    let envelope: [String: Any] = [
      "mediaProgresses": [["libraryItemId": "item_book_fixture"]],
      "seriesHideFromContinueListening": [42, ""],
    ]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.hiddenSeriesIDs.isEmpty)
  }

  @Test("decodes the bounded profile fields from the full /api/me user object")
  func decodesUserProfile() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
    let http = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response"))]
    )
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)

    let profile = try await client.fetchUserProfile(account: account)

    #expect(profile.id == "user_fixture")
    #expect(profile.username == "fixture-user")
    #expect(profile.type == "user")
    #expect(profile.isActive == true)
    #expect(profile.isLocked == false)
    #expect(profile.librariesAccessible == ["library_book_fixture", "library_podcast_fixture"])
    #expect(profile.hiddenSeriesIDs.isEmpty)
    #expect(http.requests.first?.headers["Authorization"] == "Bearer canary-access")
  }

  @Test("decodes ebook progress values and non-zero epoch-ms timestamps")
  func decodesEbookProgressAndNonZeroTimestamps() async throws {
    let entry: [String: Any] = [
      "id": "progress_ebook_fixture",
      "userId": "user_fixture",
      "libraryItemId": "item_ebook_fixture",
      "episodeId": NSNull(),
      "mediaItemId": "media_ebook_fixture",
      "mediaItemType": "book",
      "duration": 0,
      "progress": 1,
      "currentTime": 0,
      "isFinished": true,
      "hideFromContinueListening": false,
      "ebookLocation": "epubcfi(/6/4!/4/2/1:0)",
      "ebookProgress": 0.42,
      "lastUpdate": 1_700_000_000_000,
      "startedAt": 1_699_000_000_000,
      "finishedAt": 1_700_000_500_000,
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let decoded = try #require(entries.first)
    #expect(decoded.isFinished == true)
    #expect(decoded.ebookLocation == "epubcfi(/6/4!/4/2/1:0)")
    #expect(decoded.ebookProgress == 0.42)
    #expect(decoded.lastUpdate == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(decoded.startedAt == Date(timeIntervalSince1970: 1_699_000_000))
    #expect(decoded.finishedAt == Date(timeIntervalSince1970: 1_700_000_500))
  }

  // MARK: - The envelope key `/api/me` actually answers with

  /// Audiobookshelf's user object carries this array under `mediaProgress` (singular). A missing
  /// key makes `superDecoder(forKey:)` throw `keyNotFound`, which `BoundedDecoder` maps to
  /// `APIError.decoding`, so decoding only the plural key fails every `/api/me` call against a
  /// real server. Fixtures written with the plural key would not catch it.
  @Test("decodes the singular `mediaProgress` envelope a real server sends")
  func decodesTheSingularMediaProgressEnvelope() async throws {
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let envelope: [String: Any] = ["mediaProgress": [progress]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    #expect(entries.map(\.libraryItemID) == ["item_book_fixture"])
  }

  /// Both spellings decode. Many fixtures and harnesses in this package send the plural, and a
  /// server that answers it is not worth failing over.
  @Test("still decodes the plural `mediaProgresses` envelope")
  func stillDecodesThePluralMediaProgressesEnvelope() async throws {
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let envelope: [String: Any] = ["mediaProgresses": [progress]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    #expect(entries.map(\.libraryItemID) == ["item_book_fixture"])
  }

  /// A response carrying neither spelling is not a user object at all, so it stays loud (the
  /// top-level-shape rule `fetchItemDetail` applies to a missing item id, ARCHITECTURE.md).
  /// Callers that would rather degrade wrap this in `try?`.
  @Test("a response with neither envelope key is still a decode failure")
  func neitherEnvelopeKeyIsADecodeFailure() async throws {
    let (client, _, account) = try makeClient(
      responses: [jsonResponse(object: ["username": "someone"])])

    await #expect(throws: APIError.decoding) {
      _ = try await client.fetchUserMediaProgress(account: account)
    }
  }

  @Test("sanitizes impossible numeric values to nil instead of throwing")
  func sanitizesImpossibleNumericValues() async throws {
    let entry: [String: Any] = [
      "libraryItemId": "item_impossible_fixture",
      "duration": -100,
      "progress": 2.5,
      "currentTime": -1,
      "ebookProgress": -0.1,
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let decoded = try #require(entries.first)
    #expect(decoded.duration == nil)
    #expect(decoded.progress == nil)
    #expect(decoded.currentTime == nil)
    #expect(decoded.ebookProgress == nil)
  }

  @Test("skips entries missing the required libraryItemId identity, recording diagnostics")
  func skipsEntriesMissingLibraryItemId() async throws {
    let valid = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let missingIdentity: [String: Any] = ["mediaItemId": "media_orphan_fixture", "progress": 0.5]
    let envelope: [String: Any] = ["mediaProgresses": [valid, missingIdentity]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])
    let diagnostics = DecodeDiagnostics()

    let entries = try await client.fetchUserMediaProgress(account: account, diagnostics: diagnostics)

    #expect(entries.map(\.libraryItemID) == ["item_book_fixture"])
    #expect(diagnostics.entries.isEmpty == false)
    #expect(diagnostics.entries.allSatisfy { $0.endpoint == "/api/me" })
  }

  // MARK: - serverProgressID (cross-device reset evidence)

  @Test("decodes the row id as serverProgressID")
  func decodesRowIdAsServerProgressID() async throws {
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let envelope: [String: Any] = ["mediaProgresses": [progress]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let entry = try #require(entries.first)
    #expect(entry.serverProgressID == "progress_fixture")
  }

  @Test("an oversized row id decodes as nil rather than a truncated identity")
  func oversizedRowIdDecodesAsNil() async throws {
    let oversizedID = String(repeating: "x", count: 20_000)
    let entry: [String: Any] = [
      "id": oversizedID,
      "libraryItemId": "item_book_fixture",
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let decoded = try #require(entries.first)
    #expect(decoded.libraryItemID == "item_book_fixture")
    #expect(decoded.serverProgressID == nil)
  }

  // MARK: - bounded identity strings

  @Test("an oversized libraryItemId drops the element rather than truncating the key")
  func oversizedLibraryItemIdDropsElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let valid: [String: Any] = ["libraryItemId": "item_valid_fixture"]
    let oversized: [String: Any] = ["libraryItemId": String(repeating: "x", count: limit + 1)]
    let envelope: [String: Any] = ["mediaProgresses": [valid, oversized]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.map(\.libraryItemID) == ["item_valid_fixture"])
    #expect(snapshot.isComplete == false)
  }

  @Test("an oversized episodeId drops the element instead of misattributing episode progress")
  func oversizedEpisodeIdDropsElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let valid: [String: Any] = ["libraryItemId": "item_valid_fixture"]
    let oversized: [String: Any] = [
      "libraryItemId": "item_episode_fixture",
      "episodeId": String(repeating: "e", count: limit + 1),
    ]
    let envelope: [String: Any] = ["mediaProgresses": [valid, oversized]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.map(\.libraryItemID) == ["item_valid_fixture"])
    #expect(snapshot.isComplete == false)
  }

  @Test("a wrong-typed episodeId drops the element")
  func wrongTypedEpisodeIdDropsElement() async throws {
    let entry: [String: Any] = [
      "libraryItemId": "item_episode_fixture",
      "episodeId": 42,
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.isEmpty)
    #expect(snapshot.isComplete == false)
  }

  @Test("an oversized mediaItemId drops the element instead of breaking duplicate-row matching")
  func oversizedMediaItemIdDropsElement() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let valid: [String: Any] = ["libraryItemId": "item_valid_fixture"]
    let oversized: [String: Any] = [
      "libraryItemId": "item_episode_fixture",
      "mediaItemId": String(repeating: "m", count: limit + 1),
    ]
    let envelope: [String: Any] = ["mediaProgresses": [valid, oversized]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.map(\.libraryItemID) == ["item_valid_fixture"])
    #expect(snapshot.isComplete == false)
  }

  @Test("a wrong-typed mediaItemId drops the element")
  func wrongTypedMediaItemIdDropsElement() async throws {
    let entry: [String: Any] = [
      "libraryItemId": "item_episode_fixture",
      "mediaItemId": 42,
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.isEmpty)
    #expect(snapshot.isComplete == false)
  }

  @Test("an absent or null episodeId stays nil and keeps the row")
  func absentOrNullEpisodeIdKeepsRow() async throws {
    let absent: [String: Any] = ["libraryItemId": "item_absent_fixture"]
    let null: [String: Any] = ["libraryItemId": "item_null_fixture", "episodeId": NSNull()]
    let envelope: [String: Any] = ["mediaProgresses": [absent, null]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.map(\.libraryItemID) == ["item_absent_fixture", "item_null_fixture"])
    #expect(snapshot.progress.allSatisfy { $0.episodeID == nil })
    #expect(snapshot.isComplete == true)
  }

  @Test("identity strings exactly at the bound are kept")
  func identityStringsAtTheBoundAreKept() async throws {
    let limit = EndpointDecodeLimits.standard.maximumListStringBytes
    let atLimit = String(repeating: "i", count: limit)
    let entry: [String: Any] = [
      "libraryItemId": atLimit,
      "episodeId": atLimit,
      "mediaItemId": atLimit,
    ]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let decoded = try #require(entries.first)
    #expect(decoded.libraryItemID == atLimit)
    #expect(decoded.episodeID == atLimit)
    #expect(decoded.mediaItemID == atLimit)
  }

  @Test("a missing row id decodes as nil")
  func missingRowIdDecodesAsNil() async throws {
    let entry: [String: Any] = ["libraryItemId": "item_sparse_fixture"]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    #expect(entries.first?.serverProgressID == nil)
  }

  // MARK: - UserProgressSnapshot.isComplete

  @Test("isComplete is true for a clean body")
  func isCompleteTrueForCleanBody() async throws {
    let progress = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let envelope: [String: Any] = ["mediaProgresses": [progress]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.isComplete == true)
  }

  @Test("isComplete is true for an empty array")
  func isCompleteTrueForEmptyArray() async throws {
    let envelope: [String: Any] = ["mediaProgresses": []]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.isEmpty)
    #expect(snapshot.isComplete == true)
  }

  @Test("isComplete is false when an element is missing the required libraryItemId")
  func isCompleteFalseWhenElementMissingLibraryItemId() async throws {
    let valid = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    let missingIdentity: [String: Any] = ["mediaItemId": "media_orphan_fixture"]
    let envelope: [String: Any] = ["mediaProgresses": [valid, missingIdentity]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.isComplete == false)
  }

  @Test("isComplete is false when an element fails to decode structurally")
  func isCompleteFalseWhenElementIsMalformed() async throws {
    let valid = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "media-progress")) as? [String: Any]
    )
    // A bare string in the array position instead of an object: `keyedBy:` throws a type
    // mismatch, so `LossyArray` drops it before it ever reaches the `libraryItemId` validator.
    let envelope: [String: Any] = ["mediaProgresses": [valid, "not-an-object"]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let snapshot = try await client.fetchUserProgressSnapshot(account: account)

    #expect(snapshot.progress.count == 1)
    #expect(snapshot.isComplete == false)
  }

  @Test("treats missing optional fields as nil/false defaults without throwing")
  func treatsMissingOptionalDataAsNil() async throws {
    let entry: [String: Any] = ["libraryItemId": "item_sparse_fixture"]
    let envelope: [String: Any] = ["mediaProgresses": [entry]]
    let (client, _, account) = try makeClient(responses: [jsonResponse(object: envelope)])

    let entries = try await client.fetchUserMediaProgress(account: account)

    let decoded = try #require(entries.first)
    #expect(decoded.libraryItemID == "item_sparse_fixture")
    #expect(decoded.episodeID == nil)
    #expect(decoded.mediaItemID == nil)
    #expect(decoded.mediaItemType == nil)
    #expect(decoded.duration == nil)
    #expect(decoded.progress == nil)
    #expect(decoded.currentTime == nil)
    #expect(decoded.isFinished == false)
    #expect(decoded.hideFromContinueListening == false)
    #expect(decoded.ebookLocation == nil)
    #expect(decoded.ebookProgress == nil)
    #expect(decoded.lastUpdate == nil)
    #expect(decoded.startedAt == nil)
    #expect(decoded.finishedAt == nil)
  }
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
