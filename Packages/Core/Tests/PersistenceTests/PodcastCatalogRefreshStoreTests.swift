import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct PodcastCatalogRefreshStoreTests {
  @Test func neverHydratedShowsSortFirstAndRoutingUsesLiveRows() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    let hydrated = try await insertShow(
      database, scope: scope, serverID: "hydrated", serverCount: 2,
      serverUpdatedAt: Date(timeIntervalSince1970: 100))
    let empty = try await insertShow(
      database, scope: scope, serverID: "empty", serverCount: 1,
      serverUpdatedAt: Date(timeIntervalSince1970: 100))
    try await insertEpisode(database, scope: scope, itemID: hydrated, id: "one")
    try await insertEpisode(database, scope: scope, itemID: hydrated, id: "two")
    try await PodcastCatalogRefreshStore(database: database).recordSuccess(
      itemID: hydrated, at: Date(timeIntervalSince1970: 100))

    let candidates = try await PodcastCatalogRefreshStore(database: database).candidates(
      now: Date(timeIntervalSince1970: 200), backstop: 1_000, limit: 10)

    #expect(candidates.map(\.localItemID) == [empty])
    #expect(candidates.first?.changeReason == .neverHydrated)
    #expect(candidates.first?.hasLocalEpisodes == false)
  }

  @Test func countMismatchAndServerUpdateSelectHydratedShows() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    let countChanged = try await insertShow(
      database, scope: scope, serverID: "count", serverCount: 2,
      serverUpdatedAt: Date(timeIntervalSince1970: 100))
    let updated = try await insertShow(
      database, scope: scope, serverID: "updated", serverCount: 1,
      serverUpdatedAt: Date(timeIntervalSince1970: 300))
    for itemID in [countChanged, updated] {
      try await insertEpisode(database, scope: scope, itemID: itemID, id: "one")
      try await PodcastCatalogRefreshStore(database: database).recordSuccess(
        itemID: itemID, at: Date(timeIntervalSince1970: 200))
    }

    let candidates = try await PodcastCatalogRefreshStore(database: database).candidates(
      now: Date(timeIntervalSince1970: 400), backstop: 1_000, limit: 10)

    #expect(candidates.map(\.changeReason) == [.episodeCountMismatch, .serverUpdated])
    #expect(candidates.allSatisfy { $0.hasLocalEpisodes })
  }

  @Test func unchangedShowWaitsForBackstopAndExplicitSelectionCanExcludeIt() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    let itemID = try await insertShow(
      database, scope: scope, serverID: "stable", serverCount: 1,
      serverUpdatedAt: Date(timeIntervalSince1970: 100))
    try await insertEpisode(database, scope: scope, itemID: itemID, id: "one")
    try await PodcastCatalogRefreshStore(database: database).recordSuccess(
      itemID: itemID, at: Date(timeIntervalSince1970: 200))
    let store = PodcastCatalogRefreshStore(database: database)

    #expect(
      try await store.candidates(
        now: Date(timeIntervalSince1970: 250), backstop: 100, limit: 10
      ).isEmpty)
    #expect(
      try await store.candidates(
        now: Date(timeIntervalSince1970: 301), backstop: 100, limit: 10
      ).first?.changeReason == .backstopExpired)
    #expect(
      try await store.candidates(
        now: Date(timeIntervalSince1970: 301), backstop: 100,
        includeBackstop: false, limit: 10
      ).isEmpty)
  }

  @Test func showFailureBacksOffAndSuccessClearsFailureState() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    let itemID = try await insertShow(
      database, scope: scope, serverID: "failing", serverCount: 1,
      serverUpdatedAt: nil)
    let store = PodcastCatalogRefreshStore(database: database)
    let failedAt = Date(timeIntervalSince1970: 100)
    try await store.recordShowFailure(itemID: itemID, at: failedAt, randomUnit: 0.5)

    #expect(
      try await store.candidates(
        now: failedAt, backstop: 100, limit: 10
      ).isEmpty)
    try await store.recordSuccess(itemID: itemID, at: Date(timeIntervalSince1970: 200))
    let state = try database.read { db in
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)
    }
    #expect(state?.consecutiveFailures == 0)
    #expect(state?.nextEligibleAttemptAt == nil)
  }

  @Test func gateIgnoresLibrariesThatHoldNoPodcasts() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    _ = try await insertShow(
      database, scope: scope, serverID: "show", serverCount: 1, serverUpdatedAt: nil)
    // A book library that has never finished a traversal must not gate podcast work.
    let books = try await database.writeAsync { db -> Int64 in
      var other = LibraryRecord(
        accountId: scope.accountID, serverLibraryId: "books", mediaType: "book", name: "Books")
      try other.insert(db)
      return other.id!
    }
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .completed)
    try await insertRun(database, scope: scope, libraryID: books, state: .incomplete)
    try await insertRun(database, scope: scope, libraryID: books, state: .running)

    #expect(try await PodcastCatalogRefreshStore(database: database).traversalIsReady())
  }

  @Test func candidatesAndTraversalIgnoreAnExcludedPodcastLibrary() async throws {
    let database = try AppDatabase.inMemory()
    let included = try await seedScope(database)
    let excludedLibraryID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: included.accountID, serverLibraryId: "excluded-podcasts", mediaType: "podcast",
        name: "Excluded Podcasts", isIncluded: false)
      try library.insert(db)
      return library.id!
    }
    let excluded = Scope(accountID: included.accountID, libraryID: excludedLibraryID)
    let includedShow = try await insertShow(
      database, scope: included, serverID: "included-show", serverCount: 1, serverUpdatedAt: nil)
    _ = try await insertShow(
      database, scope: excluded, serverID: "excluded-show", serverCount: 1, serverUpdatedAt: nil)
    try await insertRun(database, scope: included, libraryID: included.libraryID, state: .completed)

    let store = PodcastCatalogRefreshStore(database: database)
    let candidates = try await store.candidates(
      now: Date(timeIntervalSince1970: 100), backstop: 1_000, limit: 10)

    #expect(candidates.map(\.localItemID) == [includedShow])
    #expect(try await store.traversalIsReady())
  }

  @Test func gateStaysClosedWhileThePodcastLibraryIsTraversing() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    _ = try await insertShow(
      database, scope: scope, serverID: "show", serverCount: 1, serverUpdatedAt: nil)
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .completed)
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .running)

    #expect(try await PodcastCatalogRefreshStore(database: database).traversalIsReady() == false)
  }

  @Test func gateStaysClosedUntilThePodcastLibraryHasCompletedOnce() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    _ = try await insertShow(
      database, scope: scope, serverID: "show", serverCount: 1, serverUpdatedAt: nil)
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .incomplete)

    #expect(try await PodcastCatalogRefreshStore(database: database).traversalIsReady() == false)
  }

  @Test func abandonedRunsFromAPreviousProcessAreReapedNotLeftRunningForever() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await seedScope(database)
    _ = try await insertShow(
      database, scope: scope, serverID: "show", serverCount: 1, serverUpdatedAt: nil)
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .completed)
    try await insertRun(database, scope: scope, libraryID: scope.libraryID, state: .running)

    let reaped = try await SyncRunDAO(database: database).reapAbandonedRunsAsync(
      accountId: scope.accountID, at: Date(timeIntervalSince1970: 500))

    #expect(reaped == 1)
    let states = try database.read { db in
      try SyncRunRecord.fetchAll(db).map(\.state)
    }
    #expect(states.contains(.running) == false)
    #expect(try await PodcastCatalogRefreshStore(database: database).traversalIsReady())
  }

  private struct Scope {
    let accountID: Int64
    let libraryID: Int64
  }

  private func seedScope(_ database: AppDatabase) async throws -> Scope {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "catalogue-client", serverBaseURL: "https://example.test",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      return Scope(accountID: account.id!, libraryID: library.id!)
    }
  }

  private func insertShow(
    _ database: AppDatabase,
    scope: Scope,
    serverID: String,
    serverCount: Int?,
    serverUpdatedAt: Date?
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: scope.accountID, libraryId: scope.libraryID, serverItemId: serverID,
        mediaKind: "podcast", title: serverID, sortTitle: serverID,
        serverUpdatedAt: serverUpdatedAt, podcastServerEpisodeCount: serverCount)
      try item.insert(db)
      return item.id!
    }
  }

  private func insertEpisode(
    _ database: AppDatabase,
    scope: Scope,
    itemID: Int64,
    id: String
  ) async throws {
    try await database.writeAsync { db in
      var episode = PersistenceFixtures.episode(
        accountId: scope.accountID, itemId: itemID, serverEpisodeId: id,
        title: id, lastSeenGeneration: 1)
      try episode.insert(db)
    }
  }

  private func insertRun(
    _ database: AppDatabase,
    scope: Scope,
    libraryID: Int64,
    state: SyncRunState
  ) async throws {
    try await database.writeAsync { db in
      var run = SyncRunRecord(
        accountId: scope.accountID, libraryId: libraryID, reason: "launch", generation: 1,
        startedAt: Date(timeIntervalSince1970: 0),
        completedAt: state == .running ? nil : Date(timeIntervalSince1970: 10),
        state: state)
      try run.insert(db)
    }
  }
}

@Suite struct PodcastCatalogRefreshStoreExpansionTests {
  @Test func recordSuccessWritesCompletenessOnlyWhenTheListWasComplete() async throws {
    let (database, accountID, libraryID) = try await seed()
    let itemID = try await insertShow(database, accountID, libraryID, "a")
    let store = PodcastCatalogRefreshStore(database: database)

    try await store.recordSuccess(itemID: itemID, at: Date(timeIntervalSince1970: 100))
    #expect(try completeAt(database, itemID) == nil)
    try await store.recordSuccess(
      itemID: itemID, at: Date(timeIntervalSince1970: 200), episodeListIsComplete: true)
    #expect(try completeAt(database, itemID) == Date(timeIntervalSince1970: 200))
    // A later partial success never clears or moves it.
    try await store.recordSuccess(
      itemID: itemID, at: Date(timeIntervalSince1970: 300), episodeListIsComplete: false)
    #expect(try completeAt(database, itemID) == Date(timeIntervalSince1970: 200))
    try await store.recordShowFailure(
      itemID: itemID, at: Date(timeIntervalSince1970: 400), randomUnit: 0.5)
    #expect(try completeAt(database, itemID) == Date(timeIntervalSince1970: 200))
  }

  @Test func candidatesRestrictToTheGivenItemsAndKeepTheDefaultBehaviour() async throws {
    let (database, accountID, libraryID) = try await seed()
    let a = try await insertShow(database, accountID, libraryID, "a")
    let b = try await insertShow(database, accountID, libraryID, "b")
    let store = PodcastCatalogRefreshStore(database: database)
    let now = Date(timeIntervalSince1970: 1_000)

    #expect(
      try await store.candidates(now: now, backstop: 10, limit: 10).map(\.localItemID) == [a, b])
    #expect(
      try await store.candidates(now: now, backstop: 10, itemIDs: [b], limit: 10)
        .map(\.localItemID) == [b])
    #expect(
      try await store.candidates(now: now, backstop: 10, itemIDs: [], limit: 10).isEmpty)
  }

  @Test func neverCompletelyExpandedIsOptInAndClearedByACompleteSuccess() async throws {
    let (database, accountID, libraryID) = try await seed()
    let a = try await insertShow(database, accountID, libraryID, "a")
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountID, itemId: a, serverEpisodeId: "e", title: "e", lastSeenGeneration: 1)
      try episode.insert(db)
    }
    let store = PodcastCatalogRefreshStore(database: database)
    try await store.recordSuccess(itemID: a, at: Date(timeIntervalSince1970: 100))
    let now = Date(timeIntervalSince1970: 150)

    // A partial success leaves it out unless asked for.
    #expect(
      try await store.candidates(now: now, backstop: 1_000, limit: 10).isEmpty)
    let asked = try await store.candidates(
      now: now, backstop: 1_000, includeBackstop: false, itemIDs: [a],
      includeNeverCompletelyExpanded: true, limit: 10)
    #expect(asked.map(\.changeReason) == [.neverCompletelyExpanded])
    #expect(asked.first?.lastCompleteEpisodeListAt == nil)

    try await store.recordSuccess(
      itemID: a, at: Date(timeIntervalSince1970: 120), episodeListIsComplete: true)
    #expect(
      try await store.candidates(
        now: now, backstop: 1_000, includeBackstop: false, itemIDs: [a],
        includeNeverCompletelyExpanded: true, limit: 10
      ).isEmpty)
  }

  @Test func backoffStillHidesAShowThatIsNeverCompletelyExpanded() async throws {
    let (database, accountID, libraryID) = try await seed()
    let a = try await insertShow(database, accountID, libraryID, "a")
    let store = PodcastCatalogRefreshStore(database: database)
    let failedAt = Date(timeIntervalSince1970: 100)
    try await store.recordShowFailure(itemID: a, at: failedAt, randomUnit: 0.5)

    #expect(
      try await store.candidates(
        now: failedAt, backstop: 0, includeBackstop: false, itemIDs: [a],
        includeNeverCompletelyExpanded: true, limit: 10
      ).isEmpty)
    #expect(
      try await store.candidates(
        now: failedAt.addingTimeInterval(600), backstop: 0, includeBackstop: false, itemIDs: [a],
        includeNeverCompletelyExpanded: true, limit: 10
      ).count == 1)
  }

  private func seed() async throws -> (AppDatabase, Int64, Int64) {
    let database = try AppDatabase.inMemory()
    let ids = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: "catalogue-client-2", serverBaseURL: "https://example.test",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      return (account.id!, library.id!)
    }
    return (database, ids.0, ids.1)
  }

  private func insertShow(
    _ database: AppDatabase, _ accountID: Int64, _ libraryID: Int64, _ serverID: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: serverID,
        mediaKind: "podcast", title: serverID, sortTitle: serverID)
      try item.insert(db)
      return item.id!
    }
  }

  private func completeAt(_ database: AppDatabase, _ itemID: Int64) throws -> Date? {
    try database.read { db in
      try PodcastRefreshStateRecord.fetchOne(db, key: itemID)?.lastCompleteEpisodeListAt
    }
  }
}
