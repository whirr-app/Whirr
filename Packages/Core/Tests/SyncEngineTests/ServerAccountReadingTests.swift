import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite struct ServerAccountReadingTests {
  @Test func durableSettingsReadLibrariesSyncStatusAndHeaderNamesOnly() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://books.example.test")))
    let database = try AppDatabase.inMemory()
    let accountID = try await seedAccount(database: database, server: server)
    try await LibraryDAO(database: database).upsertAsync(
      LibraryRecord(
        accountId: accountID,
        serverLibraryId: "library-book",
        mediaType: "book",
        name: "Books"))

    let headerStore = InMemoryCustomHeaderStore()
    try headerStore.save(
      try CustomHeaders([
        "CF-Access-Client-Id": "client-secret",
        "CF-Access-Client-Secret": "secret-value",
      ]),
      for: server.baseURL)
    let client = ABSClient(
      server: server, httpClient: FakeHTTPClient(), tokenStore: InMemoryTokenStore())
    let service = ServerAccountReadingService(
      client: client, database: database, customHeaderStore: headerStore)

    let settings = try await service.readDurableSettings()

    #expect(settings.serverVersion == "2.35.1")
    #expect(
      settings.libraries == [
        ServerAccountLibrary(id: "library-book", name: "Books", mediaType: "book")
      ])
    #expect(settings.syncStatus.lastCompletedAt == nil)
    #expect(settings.customHeaders.names == ["CF-Access-Client-Id", "CF-Access-Client-Secret"])
    #expect(settings.customHeaders.names.contains("client-secret") == false)
    #expect(settings.customHeaders.names.contains("secret-value") == false)
  }

  @Test func liveProfileReadUsesTheBoundedApiMeProjection() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://books.example.test")))
    let database = try AppDatabase.inMemory()
    _ = try await seedAccount(database: database, server: server)
    let tokenStore = InMemoryTokenStore()
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: "client-fixture"),
      userID: "user_fixture")
    try tokenStore.save(
      TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: tokenAccount)
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(
          statusCode: 200,
          headers: [:],
          body: try Fixtures.data(named: "me-profile-response"))
      ])
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let service = ServerAccountReadingService(
      client: client,
      database: database,
      customHeaderStore: InMemoryCustomHeaderStore())

    let profile = try await service.fetchProfile()

    #expect(
      profile
        == ServerAccountProfile(
          username: "fixture-user",
          type: "user",
          librariesAccessible: ["library_book_fixture", "library_podcast_fixture"]))
    #expect(http.requests.first?.url.path == "/api/me")
    #expect(http.requests.first?.headers["Authorization"] == "Bearer access-token")
  }

  private func seedAccount(database: AppDatabase, server: ABSServerConfig) async throws -> Int64 {
    let saved = try await database.writeAsync { db -> AccountRecord in
      var record = AccountRecord(
        clientUUID: "client-fixture",
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    return try #require(saved.id)
  }
}
