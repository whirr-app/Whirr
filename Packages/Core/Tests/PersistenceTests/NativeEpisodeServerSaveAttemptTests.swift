import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The server-copy attempt is account-owned durable state while native RSS remains
/// device-owned. These tests exercise the persistence contract without a network client.
@Suite struct NativeEpisodeServerSaveAttemptTests {

  private static let allStates: [NativeEpisodeServerSaveAttemptState] = [
    .preparing, .creatingShow, .createUncertain, .requestingDownload, .accepted, .confirmed,
    .deleting, .removed, .deleteUncertain, .deleteFailed, .uncertain, .failed,
  ]

  private static let legalEdges: Set<[NativeEpisodeServerSaveAttemptState]> = [
    [.preparing, .creatingShow], [.preparing, .requestingDownload], [.preparing, .failed],
    [.creatingShow, .requestingDownload], [.creatingShow, .createUncertain], [.creatingShow, .failed],
    [.createUncertain, .preparing], [.createUncertain, .requestingDownload],
    [.createUncertain, .failed],
    [.requestingDownload, .accepted], [.requestingDownload, .uncertain],
    [.requestingDownload, .failed], [.accepted, .confirmed], [.accepted, .uncertain],
    [.confirmed, .deleting], [.deleting, .removed], [.deleting, .deleteUncertain],
    [.deleting, .deleteFailed], [.deleteUncertain, .deleting], [.deleteUncertain, .removed],
    [.deleteUncertain, .deleteFailed], [.deleteFailed, .deleting],
    [.uncertain, .preparing], [.uncertain, .accepted], [.uncertain, .confirmed],
    [.uncertain, .failed], [.failed, .preparing],
  ]

  @Test func v51CreatesAnAccountOwnedAttemptWithoutRSSForeignKeys() throws {
    let database = try AppDatabase.inMemory()

    try database.read { db in
      #expect(try db.tableExists("nativeEpisodeServerSaveAttempt"))
      #expect(
        Set(try db.columns(in: "nativeEpisodeServerSaveAttempt").map(\.name))
          == [
            "id", "accountId", "accountClientUUID", "accountServerIdentityFingerprint",
            "feedId", "episodeId", "episodeIdentityKey",
            "serverItemId", "serverEpisodeId", "preflightPresence", "state", "errorCategory",
            "createdAt", "updatedAt",
          ])
      let accountForeignKeys = try Row.fetchAll(
        db,
        sql: "PRAGMA foreign_key_list(nativeEpisodeServerSaveAttempt)"
      )
      .filter { $0["table"] as String? == "account" }
      #expect(accountForeignKeys.count == 1)
      #expect(accountForeignKeys.first?["on_delete"] as String? == "CASCADE")
      #expect(
        try db.foreignKeys(on: "nativeEpisodeServerSaveAttempt")
          .contains { $0.destinationTable == "rssEpisode" } == false)
      #expect(
        try db.foreignKeys(on: "nativeEpisodeServerSaveAttempt")
          .contains { $0.destinationTable == "rssFeed" } == false)

      let indexNames = Set(
        try db.indexes(on: "nativeEpisodeServerSaveAttempt").map(\.name))
      #expect(indexNames.contains("index_nativeEpisodeServerSaveAttempt_on_account_feed_episode"))
      #expect(indexNames.contains("index_nativeEpisodeServerSaveAttempt_on_account_state_updated"))
      #expect(indexNames.contains("index_nativeEpisodeServerSaveAttempt_on_account_server_identity"))
      // Applied, not last: this test is about v51 creating the table without RSS foreign keys,
      // and pinning it as the migration head would break on every later migration for a
      // reason that has nothing to do with what it checks.
      #expect(try SchemaV1.migrator().appliedMigrations(db).contains("v51"))
    }
  }

  @Test func v51StateCheckAcceptsCreateUncertain() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode")

    _ = try store.transition(attemptId: attempt.id!, to: .creatingShow)
    let uncertain = try store.transition(
      attemptId: attempt.id!, to: .createUncertain, errorCategory: .transport)
    #expect(uncertain.state == .createUncertain)
  }

  @Test func preExistingConfirmationIsGuardedByProvenanceAndFinishesTheAttempt() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode")
    let id = attempt.id!

    // Without the pre-existing provenance the edge does not exist.
    await #expect(throws: NativeEpisodeServerSaveAttemptStoreError.self) {
      _ = try await store.confirmPreExistingAsync(
        attemptId: id, serverItemId: "show", serverEpisodeId: "episode-1", now: Date())
    }
    #expect(try await store.fetchAttemptAsync(id: id)?.state == .preparing)

    _ = try await store.recordPreflightPresenceAsync(.preExisting, attemptId: id)
    let confirmed = try await store.confirmPreExistingAsync(
      attemptId: id, serverItemId: "show", serverEpisodeId: "episode-1", now: Date())
    #expect(confirmed.state == .confirmed)
    #expect(confirmed.serverItemId == "show")
    #expect(confirmed.serverEpisodeId == "episode-1")
    #expect(confirmed.errorCategory == nil)
    #expect(confirmed.preflightPresence == .preExisting)

    // Only `.preparing` rows can take the edge, so a second call is rejected.
    await #expect(throws: NativeEpisodeServerSaveAttemptStoreError.self) {
      _ = try await store.confirmPreExistingAsync(
        attemptId: id, serverItemId: "show", serverEpisodeId: "episode-1", now: Date())
    }
  }

  @Test func fetchingByStatesReturnsOnlyTheAccountsRowsInThoseStates() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let preparing = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "one")
    let sending = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two")
    _ = try await store.transitionAsync(
      attemptId: sending.id!, to: .creatingShow, serverItemId: nil, errorCategory: nil)

    let unsettled = try await store.fetchAttemptsAsync(
      accountId: accountID, states: [.creatingShow, .requestingDownload, .accepted])
    #expect(unsettled.map(\.id) == [sending.id])

    let everything = try await store.fetchAttemptsAsync(
      accountId: accountID, states: [.preparing, .creatingShow])
    #expect(Set(everything.compactMap(\.id)) == Set([preparing.id!, sending.id!]))
    #expect(try await store.fetchAttemptsAsync(accountId: accountID + 1, states: [.preparing]).isEmpty)
  }

  @Test func creatingAnAttemptValidatesPositiveAndBoundedIdentityValues() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.invalidIdentity
    ) {
      try store.createAttempt(
        accountId: accountID, feedId: 0, episodeId: 1, episodeIdentityKey: "episode")
    }
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.invalidEpisodeIdentity
    ) {
      try store.createAttempt(
        accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "")
    }
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.invalidEpisodeIdentity
    ) {
      try store.createAttempt(
        accountId: accountID, feedId: 1, episodeId: 1,
        episodeIdentityKey: String(repeating: "x", count: 513))
    }
  }

  @Test(arguments: allStates, allStates)
  func transitionMatrixRejectsEveryIllegalEdge(
    from: NativeEpisodeServerSaveAttemptState,
    to: NativeEpisodeServerSaveAttemptState
  ) async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let attemptID = try await insertAttempt(
      database, accountId: accountID, state: from,
      serverItemId: "server-item", serverEpisodeId: "server-episode",
      preflightPresence: .absentBeforeRequest)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let legal = Self.legalEdges.contains([from, to])

    if legal {
      let result = try store.transition(
        attemptId: attemptID, to: to, errorCategory: .transport)
      #expect(result.state == to)
    } else {
      #expect(throws: NativeEpisodeServerSaveAttemptStoreError.self) {
        try store.transition(attemptId: attemptID, to: to)
      }
      let unchanged = try await store.fetchAttemptAsync(id: attemptID)
      #expect(unchanged?.state == from)
    }
  }

  @Test func requiredServerIdentitiesAndRemovalProvenanceAreEnforced() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let withoutServerIdentity = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode")

    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.serverItemIdentityRequired
    ) {
      try store.transition(attemptId: withoutServerIdentity.id!, to: .requestingDownload)
    }
    _ = try store.recordServerItemID("server-item-missing-preflight", attemptId: withoutServerIdentity.id!)
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.preflightRequired
    ) {
      try store.transition(attemptId: withoutServerIdentity.id!, to: .requestingDownload)
    }

    let preExisting = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode-2",
      preflightPresence: .preExisting)
    _ = try store.transition(
      attemptId: preExisting.id!, to: .requestingDownload, serverItemId: "server-item")
    _ = try store.transition(attemptId: preExisting.id!, to: .accepted)
    _ = try store.transition(
      attemptId: preExisting.id!, to: .confirmed, serverEpisodeId: "server-episode")
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.preExistingEpisodeCannotBeRemoved
    ) {
      try store.transition(attemptId: preExisting.id!, to: .deleting)
    }
  }

  @Test func serverIdentitiesAreWriteOnceButIdenticalRetriesSucceed() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest)

    _ = try store.recordServerItemID("server-item-1", attemptId: attempt.id!)
    _ = try store.recordServerItemID("server-item-1", attemptId: attempt.id!)
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded) {
      try store.recordServerItemID("server-item-2", attemptId: attempt.id!)
    }

    _ = try store.transition(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "server-item-1")
    _ = try store.transition(attemptId: attempt.id!, to: .accepted)
    _ = try store.transition(
      attemptId: attempt.id!, to: .confirmed, serverEpisodeId: "server-episode-1")
    _ = try store.recordServerEpisodeID("server-episode-1", attemptId: attempt.id!)
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded) {
      try store.recordServerEpisodeID("server-episode-2", attemptId: attempt.id!)
    }
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.serverIdentityAlreadyRecorded) {
      try store.transition(
        attemptId: attempt.id!, to: .deleting, serverEpisodeId: "server-episode-2")
    }
    _ = try store.transition(
      attemptId: attempt.id!, to: .deleting, serverItemId: "server-item-1",
      serverEpisodeId: "server-episode-1")
  }

  @Test func createUncertainCannotSkipAcceptedButRecoveryCanComplete() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest)

    _ = try store.recordServerItemID("server-item", attemptId: attempt.id!)
    _ = try store.transition(attemptId: attempt.id!, to: .creatingShow)
    _ = try store.transition(attemptId: attempt.id!, to: .createUncertain)
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.self) {
      try store.transition(
        attemptId: attempt.id!, to: .confirmed, serverEpisodeId: "server-episode")
    }
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.self) {
      try store.transition(attemptId: attempt.id!, to: .accepted)
    }

    _ = try store.transition(attemptId: attempt.id!, to: .preparing)
    _ = try store.transition(attemptId: attempt.id!, to: .requestingDownload)
    _ = try store.transition(attemptId: attempt.id!, to: .accepted)
    _ = try store.transition(
      attemptId: attempt.id!, to: .confirmed, serverEpisodeId: "server-episode")
    #expect(try store.fetchAttempt(id: attempt.id!)?.state == .confirmed)
  }

  @Test func preflightProvenanceIsRecordedBeforeTheRequestAndCannotBeRewritten() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode")

    _ = try store.recordPreflightPresence(
      .absentBeforeRequest, attemptId: attempt.id!, now: Date(timeIntervalSince1970: 10))
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.preflightAlreadyRecorded
    ) {
      try store.recordPreflightPresence(
        .preExisting, attemptId: attempt.id!, now: Date(timeIntervalSince1970: 11))
    }
    _ = try store.transition(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "server-item")
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.preflightAlreadyRecorded
    ) {
      try store.transition(
        attemptId: attempt.id!, to: .accepted,
        preflightPresence: .preExisting)
    }

    let lateAttempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode-2")
    #expect(
      throws: NativeEpisodeServerSaveAttemptStoreError.preflightRequired
    ) {
      try store.transition(
        attemptId: lateAttempt.id!, to: .requestingDownload, serverItemId: "server-item-2")
    }
    #expect(try store.fetchAttempt(id: lateAttempt.id!)?.state == .preparing)
  }

  @Test func transitionAndAdjacentLocalWriteCommitOrRollBackTogether() async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 1, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest)
    let timestamp = Date(timeIntervalSince1970: 1_700_000_010)

    _ = try store.transition(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "server-item",
      now: timestamp,
      updatingLocalState: { db in
        try db.execute(
          sql: "UPDATE account SET serverVersion = ? WHERE id = ?",
          arguments: ["next", accountID])
      })
    let committed = try await store.fetchAttemptAsync(id: attempt.id!)
    let committedVersion = try await database.readAsync { db in
      try String.fetchOne(db, sql: "SELECT serverVersion FROM account WHERE id = ?", arguments: [accountID])
    }
    #expect(committed?.state == .requestingDownload)
    #expect(committed?.serverItemId == "server-item")
    #expect(committed?.updatedAt == timestamp)
    #expect(committedVersion == "next")

    await #expect(throws: InjectedFailure.self) {
      try await store.transitionAsync(
        attemptId: attempt.id!, to: .accepted, now: timestamp.addingTimeInterval(1),
        updatingLocalState: { db in
          try db.execute(
            sql: "UPDATE account SET serverVersion = ? WHERE id = ?",
            arguments: ["should-rollback", accountID])
          throw InjectedFailure()
        })
    }
    let rolledBack = try await store.fetchAttemptAsync(id: attempt.id!)
    let rolledBackVersion = try await database.readAsync { db in
      try String.fetchOne(db, sql: "SELECT serverVersion FROM account WHERE id = ?", arguments: [accountID])
    }
    #expect(rolledBack?.state == .requestingDownload)
    #expect(rolledBack?.updatedAt == timestamp)
    #expect(rolledBackVersion == "next")
  }

  @Test func beginAttemptCoalescesConcurrentTapStateWithoutErasingHistory() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    let first = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")
    let second = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9",
      now: Date(timeIntervalSince1970: 1_700_000_100))
    #expect(first.id == second.id)
    #expect(try store.fetchAttempts(accountId: accountID, feedId: 7, episodeId: 9).count == 1)

    _ = try store.transition(attemptId: first.id!, to: .failed, errorCategory: .transport)
    let retry = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")
    #expect(retry.id != first.id)
    #expect(try store.fetchAttempts(accountId: accountID, feedId: 7, episodeId: 9).count == 2)
  }

  @Test func beginAttemptCoalescesUsingAnAlternateEpisodeIdentityKey() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    let first = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "old-key")
    let rekeyed = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "new-key",
      alternateEpisodeIdentityKeys: ["old-key"])

    #expect(rekeyed.id == first.id)
    #expect(rekeyed.episodeIdentityKey == "old-key")
    #expect(try store.fetchAttempts(accountId: accountID, feedId: 7, episodeId: 9).count == 1)
  }

  @Test func failedAttemptCannotReopenWhileAnotherAttemptIsActive() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let failed = try await store.createAttemptAsync(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")
    _ = try store.transition(attemptId: failed.id!, to: .failed)
    let newer = try store.beginAttempt(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")

    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.supersededByNewerAttempt) {
      try store.transition(attemptId: failed.id!, to: .preparing)
    }
    _ = try store.transition(attemptId: newer.id!, to: .failed)
    _ = try store.transition(attemptId: failed.id!, to: .preparing)
  }

  @Test func supersessionCheckAlsoMatchesAlternateEpisodeIdentityKeys() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let failed = try await store.createAttemptAsync(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "old-key")
    _ = try store.transition(attemptId: failed.id!, to: .failed)
    let newer = try await store.createAttemptAsync(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "new-key")

    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.supersededByNewerAttempt) {
      try store.transition(
        attemptId: failed.id!, to: .preparing, alternateEpisodeIdentityKeys: ["new-key"])
    }
    _ = try store.transition(attemptId: newer.id!, to: .failed)
    _ = try store.transition(
      attemptId: failed.id!, to: .preparing, alternateEpisodeIdentityKeys: ["new-key"])
  }

  @Test func capturedAccountFenceAllowsReauthenticationButRejectsAccountReplacement() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9",
      preflightPresence: .absentBeforeRequest)

    let original = try #require(try await store.fetchAttemptAsync(id: attempt.id!))
    #expect(original.accountClientUUID.isEmpty == false)
    #expect(original.accountServerIdentityFingerprint.count == 64)
    #expect(original.accountServerIdentityFingerprint.contains("server.example") == false)

    // A same-account reauthentication may update volatile account metadata without invalidating
    // an operation that already passed its lifecycle fence.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE account SET serverVersion = ? WHERE id = ?",
        arguments: ["2.36.0", accountID])
    }
    #expect(try await store.fetchAttemptAsync(id: attempt.id!) != nil)

    // Reusing the same local row id for a different client/server/user identity must never let an
    // old completion or retry continue against the replacement account.
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE account SET clientUUID = ?, serverBaseURL = ?, serverUserId = ? WHERE id = ?",
        arguments: [UUID().uuidString, "https://replacement.example", UUID().uuidString, accountID])
    }
    await #expect(throws: NativeEpisodeServerSaveAttemptStoreError.accountFenceMismatch) {
      try await store.fetchAttemptAsync(id: attempt.id!)
    }
    #expect(throws: NativeEpisodeServerSaveAttemptStoreError.accountFenceMismatch) {
      try store.transition(attemptId: attempt.id!, to: .requestingDownload, serverItemId: "server-item")
    }

    let persistedState = try await database.readAsync { db in
      try String.fetchOne(
        db, sql: "SELECT state FROM nativeEpisodeServerSaveAttempt WHERE id = ?",
        arguments: [attempt.id!])
    }
    #expect(persistedState == NativeEpisodeServerSaveAttemptState.preparing.rawValue)
  }

  @Test func accountRemovalClearsAttemptsWhileRSSRowsSurvive() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let feedID = try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssFeed (feedURL, subscribedAt, refreshGeneration) VALUES (?, ?, ?)",
        arguments: ["https://rss.example/feed.xml", Date(), 1])
      return db.lastInsertedRowID
    }
    let episodeID = try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration) VALUES (?, ?, ?, ?)",
        arguments: [feedID, "guid:episode", "https://rss.example/episode.mp3", 1])
      return db.lastInsertedRowID
    }
    let attempt = try await NativeEpisodeServerSaveAttemptStore(database: database).createAttemptAsync(
      accountId: accountID, feedId: feedID, episodeId: episodeID, episodeIdentityKey: "guid:episode")
    #expect(attempt.id != nil)
    #expect(try AccountRemover(database: database).accountOwnedTables().contains("nativeEpisodeServerSaveAttempt"))

    try AccountRemover(database: database).removeAccount(accountId: accountID)

    let counts = try await database.readAsync { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM nativeEpisodeServerSaveAttempt"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeed"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode")
      )
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 1)
    #expect(counts.2 == 1)
  }

  /// A flight that is still `.preparing` is active, in-memory work as far as the coordinator knows.
  /// Replacing the account must still take the row with it, through the schema's account cascade, so
  /// no stranded attempt can be read, retried, or reconciled after the account it belonged to is gone.
  @Test func accountRemovalCascadesActivePreparingAttemptsForOnlyThatAccount() async throws {
    let database = try AppDatabase.inMemory()
    let removedAccountID = try await insertAccount(database)
    let survivingAccountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    let removedAttempt = try await store.beginAttemptAsync(
      accountId: removedAccountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")
    let survivingAttempt = try await store.beginAttemptAsync(
      accountId: survivingAccountID, feedId: 7, episodeId: 9, episodeIdentityKey: "guid:9")
    #expect(removedAttempt.state == .preparing)
    #expect(survivingAttempt.state == .preparing)

    try AccountRemover(database: database).removeAccount(accountId: removedAccountID)

    let counts = try await database.readAsync { db in
      (
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM nativeEpisodeServerSaveAttempt WHERE accountId = ?",
          arguments: [removedAccountID]),
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM nativeEpisodeServerSaveAttempt WHERE accountId = ?",
          arguments: [survivingAccountID]),
        try String.fetchOne(
          db, sql: "SELECT state FROM nativeEpisodeServerSaveAttempt WHERE id = ?",
          arguments: [survivingAttempt.id!])
      )
    }
    #expect(counts.0 == 0)
    #expect(counts.1 == 1)
    #expect(counts.2 == NativeEpisodeServerSaveAttemptState.preparing.rawValue)
  }

  @Test func pruningAnRSSRowDoesNotCascadeTheAttempt() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let (feedID, episodeID) = try await insertRSS(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: feedID, episodeId: episodeID, episodeIdentityKey: "guid:episode")

    // The episode is absent from the next complete refresh and has no local history, so the RSS
    // store prunes it. The value-referenced attempt remains available for reconciliation.
    _ = try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET refreshGeneration = 2 WHERE id = ?", arguments: [feedID])
    }
    let result = try await RSSEpisodeStore(database: database).sweepDroppedEpisodes(feedId: feedID)
    #expect(result.deleted == 1)
    #expect(try await store.fetchAttemptAsync(id: attempt.id!) != nil)
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE id = ?", arguments: [episodeID])
      } == 0)
  }

  // MARK: - observeLatestAttempts

  @Test func observeLatestAttemptsEmitsOnceAndFinishesForEmptyEpisodeIds() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    var iterator = store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [])
      .makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == [:])
    let second = await iterator.next()
    #expect(second == nil)
  }

  @Test func observeLatestAttemptsReportsANewAttemptWithoutAFreshSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)

    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2]))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first == [:])

    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.id == attempt.id }
      })
  }

  @Test func observeLatestAttemptsReportsARemovalTransitionWithoutAFreshSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")

    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2]))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.state == .preparing }
      })

    _ = try await store.recordPreflightPresenceAsync(.absentBeforeRequest, attemptId: attempt.id!)
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "show")
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .accepted)
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .confirmed, serverItemId: "show", serverEpisodeId: "episode-1")
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .deleting)
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .removed, serverItemId: "show")

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.state == .removed }
      })
  }

  @Test func observeLatestAttemptsByServerItemKeysConfirmedRowsByServerEpisodeId() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let otherAccountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let confirmed = try await insertAttempt(
      database, accountId: accountID, state: .confirmed, serverItemId: "show",
      serverEpisodeId: "server-episode", preflightPresence: .absentBeforeRequest)
    // No server episode id yet: the server show has nothing to key it by.
    _ = try await insertAttempt(
      database, accountId: accountID, state: .accepted, serverItemId: "show")
    // Another show and another account are both out of scope.
    _ = try await insertAttempt(
      database, accountId: accountID, state: .confirmed, serverItemId: "other-show",
      serverEpisodeId: "elsewhere")
    _ = try await insertAttempt(
      database, accountId: otherAccountID, state: .confirmed, serverItemId: "show",
      serverEpisodeId: "theirs")

    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, serverItemId: "show"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let first = try #require(observations.values.first)
    #expect(Set(first.keys) == ["server-episode"])
    #expect(first["server-episode"]?.id == confirmed)
    #expect(first["server-episode"]?.preflightPresence == .absentBeforeRequest)

    _ = try await store.transitionAsync(attemptId: confirmed, to: .deleting)
    _ = try await store.transitionAsync(attemptId: confirmed, to: .removed, serverItemId: "show")
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0["server-episode"]?.state == .removed }
      })
  }

  @Test func observeLatestAttemptsReducesToTheLatestPerEpisodeAcrossMultipleIds() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let older = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two",
      now: Date(timeIntervalSince1970: 10))
    _ = try await store.transitionAsync(
      attemptId: older.id!, to: .failed, errorCategory: .transport,
      now: Date(timeIntervalSince1970: 11))
    let newer = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two",
      now: Date(timeIntervalSince1970: 20))
    let three = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 3, episodeIdentityKey: "three",
      now: Date(timeIntervalSince1970: 30))

    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2, 3, 4]))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.count == 2 }
      })
    let latest = try #require(observations.last { $0.count == 2 })
    #expect(latest[2]?.id == newer.id)
    #expect(latest[3]?.id == three.id)
    #expect(latest[4] == nil)
  }

  /// Two attempts for one episode written at the same instant: the later row id is current. The
  /// record owns that order, so the live observation and the projection's pull path agree.
  @Test func coincidentUpdatedAtOrdersAttemptsByRowID() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let timestamp = Date(timeIntervalSince1970: 20)
    let first = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two", now: timestamp)
    let second = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two", now: timestamp)

    #expect(first.isOlder(than: second))
    #expect(second.isOlder(than: first) == false)

    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2]))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.id == second.id }
      })
  }

  @Test func observeLatestAttemptsExcludesAnotherAccountsRows() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let otherAccountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    _ = try await store.createAttemptAsync(
      accountId: otherAccountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")

    var iterator = store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2])
      .makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == [:])

    let mine = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")
    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2]))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.id == mine.id }
      })
  }

  @Test func observeLatestAttemptsDropsRowsAfterAccountReplacement() async throws {
    let database = try AppDatabase.inMemory()
    let accountID = try await insertAccount(database)
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")
    let observations = PersistenceObservationCollector(
      store.observeLatestAttempts(accountId: accountID, feedId: 1, episodeIds: [2]))

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.id == attempt.id }
      })

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE account SET clientUUID = ?, serverBaseURL = ?, serverUserId = ? WHERE id = ?",
        arguments: [UUID().uuidString, "https://replacement.example", UUID().uuidString, accountID])
    }

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0.isEmpty }
      })
  }

  // MARK: - Fixtures

  private func insertAccount(_ database: AppDatabase) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = PersistenceFixtures.account(
        clientUUID: UUID().uuidString, serverBaseURL: "https://server.example",
        serverUserId: UUID().uuidString, serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }

  private func insertAttempt(
    _ database: AppDatabase,
    accountId: Int64,
    state: NativeEpisodeServerSaveAttemptState,
    serverItemId: String? = nil,
    serverEpisodeId: String? = nil,
    preflightPresence: NativeEpisodeServerSavePreflightPresence? = nil
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      let account = try #require(try AccountRecord.fetchOne(db, key: accountId))
      var attempt = NativeEpisodeServerSaveAttemptRecord(
        accountId: accountId, accountClientUUID: account.clientUUID,
        accountServerIdentityFingerprint:
          account.serverIdentityFingerprint,
        feedId: 1, episodeId: Int64.random(in: 1...10_000),
        episodeIdentityKey: UUID().uuidString, serverItemId: serverItemId,
        serverEpisodeId: serverEpisodeId, preflightPresence: preflightPresence, state: state,
        createdAt: Date())
      try attempt.insert(db)
      return attempt.id!
    }
  }

  private func insertRSS(_ database: AppDatabase) async throws -> (feedID: Int64, episodeID: Int64) {
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssFeed (feedURL, subscribedAt, refreshGeneration) VALUES (?, ?, ?)",
        arguments: ["https://rss.example/feed-\(UUID().uuidString).xml", Date(), 1])
      let feedID = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration) VALUES (?, ?, ?, ?)",
        arguments: [feedID, "guid:episode", "https://rss.example/episode.mp3", 1])
      return (feedID, db.lastInsertedRowID)
    }
  }
}
