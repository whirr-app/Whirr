import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

/// The shelf refresh: one request per podcast library, one commit for the lot.
@Suite("Recent episode refresh")
struct RecentEpisodeRefreshTests {
  @Test("shelf episodes land against their show")
  func shelfEpisodesLandAgainstTheirShow() async throws {
    let harness = try await Harness()
    try await harness.insertShow("show-1")
    harness.http.enqueue(Self.shelf([Self.episode(id: "ep-1", item: "show-1")]))

    let result = try await harness.coordinator.refresh(
      account: harness.account, accountId: harness.accountID, podcastLibraryIDs: ["podcasts"])

    #expect(result.writtenCount == 1)
    #expect(result.failedLibraryIDs.isEmpty)
    #expect(harness.http.requests.map(\.url.path) == ["/api/libraries/podcasts/recent-episodes"])
    #expect(try harness.liveEpisodeIDs() == ["ep-1"])
  }

  @Test("each podcast library is asked exactly once")
  func eachPodcastLibraryIsAskedOnce() async throws {
    let harness = try await Harness()
    try await harness.insertShow("show-1")
    try await harness.insertShow("show-2")
    harness.http.enqueue(Self.shelf([Self.episode(id: "ep-1", item: "show-1")]))
    harness.http.enqueue(Self.shelf([Self.episode(id: "ep-2", item: "show-2")]))

    let result = try await harness.coordinator.refresh(
      account: harness.account, accountId: harness.accountID,
      podcastLibraryIDs: ["podcasts", "more-podcasts"])

    #expect(result.writtenCount == 2)
    #expect(result.failedLibraryIDs.isEmpty)
    #expect(
      harness.http.requests.map(\.url.path) == [
        "/api/libraries/podcasts/recent-episodes",
        "/api/libraries/more-podcasts/recent-episodes",
      ])
    #expect(try harness.liveEpisodeIDs() == ["ep-1", "ep-2"])
  }

  /// One unreachable library must not cost the others their shelf.
  @Test("a library that fails does not stop the rest")
  func aFailingLibraryDoesNotStopTheRest() async throws {
    let harness = try await Harness()
    try await harness.insertShow("show-2")
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    harness.http.enqueue(Self.shelf([Self.episode(id: "ep-2", item: "show-2")]))

    let result = try await harness.coordinator.refresh(
      account: harness.account, accountId: harness.accountID,
      podcastLibraryIDs: ["broken", "podcasts"])

    #expect(result.writtenCount == 1)
    #expect(result.failedLibraryIDs == ["broken"])
    #expect(try harness.liveEpisodeIDs() == ["ep-2"])
  }

  @Test("no podcast library means no request at all")
  func noPodcastLibraryMeansNoRequest() async throws {
    let harness = try await Harness()

    let result = try await harness.coordinator.refresh(
      account: harness.account, accountId: harness.accountID, podcastLibraryIDs: [])

    #expect(result.writtenCount == 0)
    #expect(result.failedLibraryIDs.isEmpty)
    #expect(harness.http.requests.isEmpty)
  }

  @Test("only a landed shelf commit reports committed")
  func onlyALandedShelfCommitReportsCommitted() async throws {
    let emptyHarness = try await Harness()
    let empty = try await emptyHarness.coordinator.refresh(
      account: emptyHarness.account, accountId: emptyHarness.accountID,
      podcastLibraryIDs: ["podcasts"])
    #expect(empty.commitOutcome == .notCommitted)

    let failedHarness = try await Harness()
    failedHarness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    let failed = try await failedHarness.coordinator.refresh(
      account: failedHarness.account, accountId: failedHarness.accountID,
      podcastLibraryIDs: ["podcasts"])
    #expect(failed.commitOutcome == .notCommitted)

    let successHarness = try await Harness()
    let shelf = Self.shelf([Self.episode(id: "ep-1", item: "not-in-local-catalogue")])
    successHarness.http.enqueue(shelf)
    let zeroRow = try await successHarness.coordinator.refresh(
      account: successHarness.account, accountId: successHarness.accountID,
      podcastLibraryIDs: ["podcasts"])
    #expect(zeroRow.writtenCount == 0)
    #expect(zeroRow.commitOutcome == .committed)
  }

  private static func episode(id: String, item: String) -> [String: Any] {
    [
      "id": id,
      "libraryItemId": item,
      "title": "An Episode",
      "publishedAt": 1_785_107_100_000,
      "duration": 1_200.0,
      "podcast": ["metadata": ["title": "A Show", "author": "A Host"]],
    ]
  }

  private static func shelf(_ episodes: [[String: Any]]) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: ["episodes": episodes]))
  }

  private struct Harness {
    let database: AppDatabase
    let http: FakeHTTPClient
    let coordinator: RecentEpisodeRefreshCoordinator
    let account: TokenAccount
    let accountID: Int64
    private let libraryID: Int64

    init() async throws {
      let database = try AppDatabase.inMemory()
      self.database = database
      let server = try ABSServerConfig(url: try #require(URL(string: "https://shelf.example.test")))
      let clientUUID = "shelf-client"
      account = try TokenAccount(
        credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
      let tokenStore = InMemoryTokenStore()
      try tokenStore.save(
        TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)
      http = FakeHTTPClient()
      coordinator = RecentEpisodeRefreshCoordinator(
        database: database,
        client: ABSClient(server: server, httpClient: http, tokenStore: tokenStore))

      let ids = try await database.writeAsync { db -> (Int64, Int64) in
        var account = AccountRecord(
          clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
          serverUserId: "user_fixture", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)
        return (account.id!, library.id!)
      }
      accountID = ids.0
      libraryID = ids.1
    }

    func insertShow(_ serverItemID: String) async throws {
      try await database.writeAsync { db in
        var item = ItemRecord(
          accountId: accountID, libraryId: libraryID, serverItemId: serverItemID,
          mediaKind: "podcast", title: serverItemID, sortTitle: serverItemID)
        try item.insert(db)
      }
    }

    func liveEpisodeIDs() throws -> [String] {
      try database.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT serverEpisodeId FROM podcastEpisode
            WHERE softDeleted = 0 ORDER BY serverEpisodeId
            """)
      }
    }
  }
}
