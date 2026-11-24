import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

@Suite("Podcast progress ingest")
struct PodcastProgressIngestTests {
  /// The two branches must be told apart by something the merge decision writes. Both leave
  /// `currentTime == 120` (`keepLocal` writes nothing, `needsResolution` records a conflict
  /// instead of touching the progress row), so the conflict table is the only observable
  /// difference and every assertion below names it.
  @Test("an unacknowledged local episode operation outranks the pull and records no conflict")
  func unacknowledgedLocalEpisodeOperationOutranksThePull() async throws {
    let env = try await IngestEnvironment(seedUnacknowledgedLocalOperation: true)
    try await env.refresh()

    try env.database.read { db in
      let protected = try #require(try env.protectedProgress(db))
      #expect(protected.currentTime == 120)
      #expect(protected.origin == .local)
      #expect(protected.localSequence == 7)
      #expect(
        try ProgressConflictRecord.fetchCount(db) == 0,
        "keepLocal writes nothing at all - not even a conflict row")
    }
  }

  /// Same fixture, same pull, one difference: nothing local is outstanding. The policy's
  /// zero-position guard then fires instead, which still protects the local position but does
  /// record a conflict. The previous test has to be distinguishable from this branch.
  @Test("without an outstanding local operation the same pull records a zero-position conflict")
  func anAcknowledgedRowFallsThroughToTheZeroPositionGuard() async throws {
    let env = try await IngestEnvironment(seedUnacknowledgedLocalOperation: false)
    try await env.refresh()

    try env.database.read { db in
      let protected = try #require(try env.protectedProgress(db))
      #expect(protected.currentTime == 120)
      #expect(protected.origin == .local)

      let conflicts = try ProgressConflictRecord.fetchAll(db)
      #expect(conflicts.count == 1)
      let conflict = try #require(conflicts.first)
      #expect(conflict.podcastEpisodeId == env.protectedEpisodeId)
      #expect(conflict.itemId == env.itemId)
      #expect(conflict.serverCurrentTime == 5)
      #expect(conflict.serverIsFinished == false)
    }
  }

  @Test("episode progress uses ProgressMergePolicy without falling back to the show row")
  func episodeProgressUsesExistingPolicyAndIdentity() async throws {
    let env = try await IngestEnvironment(seedUnacknowledgedLocalOperation: true)
    try await env.refresh()

    try env.database.read { db in
      let remoteEpisode = try #require(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == env.itemId)
          .filter(Column("serverEpisodeId") == "remote")
          .fetchOne(db))
      let remote = try #require(
        try MediaProgressRecord
          .filter(Column("podcastEpisodeId") == remoteEpisode.id)
          .fetchOne(db))
      #expect(remote.currentTime == 45)
      #expect(remote.origin == .server)
      #expect(
        try MediaProgressRecord
          .filter(Column("itemId") == env.itemId)
          .filter(Column("podcastEpisodeId") == nil)
          .fetchCount(db) == 0)
      #expect(
        try PodcastEpisodeRecord
          .filter(Column("itemId") == env.itemId)
          .filter(Column("serverEpisodeId") == "unknown")
          .fetchCount(db) == 0)
      #expect(
        try ProgressConflictRecord
          .filter(Column("podcastEpisodeId") == remoteEpisode.id)
          .fetchCount(db) == 0,
        "an episode with no local row applies the server value outright")
    }
  }
}

/// One podcast show with two known episodes, local progress of 120 s on `protected`, and a pull
/// that reports 5 s for it. `seedUnacknowledgedLocalOperation` is the single variable.
private struct IngestEnvironment: Sendable {
  let database: AppDatabase
  let accountId: Int64
  let itemId: Int64
  let protectedEpisodeId: Int64
  private let coordinator: PodcastRefreshCoordinator

  init(seedUnacknowledgedLocalOperation: Bool) async throws {
    let database = try AppDatabase.inMemory()
    self.database = database
    let server = try ABSServerConfig(url: #require(URL(string: "https://sync.example.test")))
    let clientUUID = "fixture-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let seeded = try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)
      var library = LibraryRecord(
        accountId: accountRecord.id!,
        serverLibraryId: "podcasts",
        mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountRecord.id!,
        libraryId: library.id!,
        serverItemId: "show-1",
        mediaKind: "podcast",
        title: "Show",
        sortTitle: "show")
      try item.insert(db)
      var protectedEpisode = PodcastEpisodeRecord(
        accountId: accountRecord.id!,
        itemId: item.id!,
        serverEpisodeId: "protected",
        title: "Protected",
        durationSeconds: 600,
        lastSeenGeneration: 1)
      try protectedEpisode.insert(db)
      var localProgress = MediaProgressRecord(
        accountId: accountRecord.id!,
        itemId: item.id!,
        podcastEpisodeId: protectedEpisode.id!,
        currentTime: 120,
        isFinished: false,
        localSequence: 7,
        origin: .local,
        originKey: "fixture-client")
      try localProgress.insert(db)
      if seedUnacknowledgedLocalOperation {
        var pending = OutboxOperationRecord(
          accountId: accountRecord.id!,
          clientOperationId: "pending-episode-progress",
          entityKey: "show-1",
          podcastEpisodeId: protectedEpisode.id!,
          operationKind: "progress",
          coalescingKey: "episode:protected",
          payloadVersion: 1,
          localSequence: 7)
        try pending.insert(db)
      }
      return (accountRecord.id!, item.id!, protectedEpisode.id!)
    }
    accountId = seeded.0
    itemId = seeded.1
    protectedEpisodeId = seeded.2

    let tokens = InMemoryTokenStore()
    try tokens.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"),
      for: account)
    let http = FakeHTTPClient()
    http.enqueue(
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
          #"""
          {"id":"show-1","libraryId":"podcasts","mediaType":"podcast","media":{
            "metadata":{"title":"Show"},
            "episodes":[
              {"id":"protected","title":"Protected","duration":600},
              {"id":"remote","title":"Remote","duration":300}
            ]
          }}
          """#.utf8)))
    http.enqueue(
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: Data(
          #"""
          {"mediaProgresses":[
            {"libraryItemId":"show-1","episodeId":"protected","currentTime":5,"isFinished":false,"lastUpdate":1900000000000},
            {"libraryItemId":"show-1","episodeId":"remote","currentTime":45,"isFinished":false,"lastUpdate":1900000000000},
            {"libraryItemId":"show-1","episodeId":"unknown","currentTime":99,"isFinished":true,"lastUpdate":1900000000000}
          ]}
          """#.utf8)))
    coordinator = PodcastRefreshCoordinator(
      database: database,
      client: ABSClient(server: server, httpClient: http, tokenStore: tokens),
      persistence: PodcastRefreshStore(database: database))
  }

  func refresh() async throws {
    _ = try await coordinator.refresh(itemID: "show-1")
  }

  func protectedProgress(_ db: Database) throws -> MediaProgressRecord? {
    try MediaProgressRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("podcastEpisodeId") == protectedEpisodeId)
      .fetchOne(db)
  }
}
