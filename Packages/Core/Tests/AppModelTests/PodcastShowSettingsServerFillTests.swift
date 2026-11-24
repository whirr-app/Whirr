import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// The Settings > Podcasts > show route with every real part in place: the real diagnostics
/// observation, the real refresh coordinator, the real refresh store, and a stubbed socket. The
/// unit tests for the fill drive a hand-fed diagnostics stream, so they can only prove the model
/// asks; this proves the ask actually lands the section on screen.
@MainActor
@Suite("Show Settings server fill (composed)", .timeLimit(.minutes(1)))
struct PodcastShowSettingsServerFillTests {
  @Test("a show never opened from the show screen still fills its server section")
  func firstOpenFillsServerSection() async throws {
    let environment = try await ServerFillEnvironment()
    let model = PodcastShowSettingsModel(
      itemID: ServerFillEnvironment.showID,
      reading: PodcastSettingsStore(
        database: environment.database, accountId: environment.accountID),
      podcastReading: DefaultPodcastReading(database: environment.database),
      refreshing: environment.makeRefreshCoordinator())

    await TestSupport.waitUntil { model.serverSettings != nil }
    let section = try #require(model.serverSettings)
    #expect(section.rows.map(\.field).contains(.autoDownloadEpisodes))
  }
}

private final class ServerFillEnvironment: @unchecked Sendable {
  static let libraryID = "podcast-library"
  static let showID = "show-fill"

  let database: AppDatabase
  let accountID: Int64

  private let fixture: SuiteOnDiskDatabases
  private var root: URL { fixture.scope.directoryURL }
  private let server: ABSServerConfig
  private let tokenStore: InMemoryTokenStore

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "PodcastShowSettingsServerFillTests")
    self.fixture = fixture
    database = try fixture.scope.open(fileAttributes: InertFileAttributes())
    server = try ABSServerConfig(
      url: try #require(URL(string: "https://server-fill.example.test")))
    let clientUUID = "server-fill-client"
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "fill-user")
    tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "fill-user", serverVersion: "2.35.1"))
    accountID = try #require(account.id)

    let libraryID = try await database.dbWriter.write { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: Self.libraryID, mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return try #require(library.id)
    }
    // The five server columns stay NULL, exactly as the library sync leaves them.
    _ = try ItemDAO(database: database).upsert(
      ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: Self.showID,
        mediaKind: "podcast", title: "Fill Show", sortTitle: "fill show"))
  }

  func makeRefreshCoordinator() -> PodcastRefreshCoordinator {
    let http = FakeHTTPClient()
    http.enqueue(Self.expandedShowResponse())
    http.enqueue(Self.jsonResponse(["mediaProgresses": [] as [Any]]))
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    return PodcastRefreshCoordinator(
      database: database, client: client,
      persistence: PodcastRefreshStore(database: database))
  }

  private static func expandedShowResponse() -> HTTPResponse {
    jsonResponse([
      "id": showID,
      "libraryId": libraryID,
      "mediaType": "podcast",
      "media": [
        "metadata": ["title": "Fill Show", "author": "Fill Host"],
        "episodes": [
          [
            "id": "episode-a", "title": "Episode A", "duration": 100,
            "publishedAt": 1_800_000_000_000,
            "audioFile": [
              "ino": "ino-episode-a", "metadata": ["size": 8], "mimeType": "audio/mpeg",
              "duration": 100,
            ],
          ]
        ],
        "autoDownloadEpisodes": true,
        "autoDownloadSchedule": "0 * * * *",
        "lastEpisodeCheck": 1_800_000_000_000,
        "maxEpisodesToKeep": 10,
        "maxNewEpisodesToDownload": 3,
      ] as [String: Any],
    ])
  }

  private static func jsonResponse(_ object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}
