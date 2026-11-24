import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

/// Schema `v11`'s per-account recent-search store (`RecentSearchStoring` conformance), tested the
/// way `ListeningQueueStoreTests` exercises `ListeningQueueStore`.
@Suite struct RecentSearchStoreTests {

  @Test("recording an existing (normalized) query moves it to the front instead of duplicating")
  func recordMovesExistingQueryToFront() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let tick = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    let store = RecentSearchStore(database: database, accountId: accountId, now: { tick.withLock { $0 } })

    try await store.record(query: "Gaiman")
    tick.withLock { $0 = $0.addingTimeInterval(1) }
    try await store.record(query: "Pratchett")
    tick.withLock { $0 = $0.addingTimeInterval(1) }
    // Same entry under normalized comparison: case-folded, and a trailing space trimmed.
    try await store.record(query: "gaiman ")

    let recent = await store.fetchRecent()
    #expect(recent.map(\.displayQuery) == ["gaiman", "Pratchett"])
    #expect(recent.map(\.normalizedQuery) == ["gaiman", "pratchett"])
  }

  @Test("the recent list is capped at 10 and evicts the oldest entry first")
  func capEvictsOldestFirst() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let tick = Mutex(Date(timeIntervalSince1970: 1_700_000_000))
    let store = RecentSearchStore(database: database, accountId: accountId, now: { tick.withLock { $0 } })

    for index in 1...11 {
      try await store.record(query: "query-\(index)")
      tick.withLock { $0 = $0.addingTimeInterval(1) }
    }

    let recent = await store.fetchRecent()
    #expect(recent.count == 10)
    // The first-recorded ("query-1") is the oldest by `lastUsedAt` and must be the one evicted;
    // everything recorded after it survives.
    #expect(recent.map(\.displayQuery).contains("query-1") == false)
    #expect(recent.map(\.displayQuery).first == "query-11")
    #expect(Set(recent.map(\.displayQuery)) == Set((2...11).map { "query-\($0)" }))
  }

  @Test("clearing one query removes only that query; clearing all removes everything")
  func clearOneAndClearAll() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let store = RecentSearchStore(database: database, accountId: accountId)

    try await store.record(query: "gaiman")
    try await store.record(query: "pratchett")
    #expect(await store.fetchRecent().count == 2)

    try await store.clear(query: "Gaiman")
    let afterClearOne = await store.fetchRecent()
    #expect(afterClearOne.map(\.displayQuery) == ["pratchett"])

    try await store.clearAll()
    #expect(await store.fetchRecent().isEmpty)
  }

  @Test("removing an account cascades away its recent-search rows")
  func accountRemovalCascadesRecentSearches() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.seedAccount(database, suffix: "first")
    let second = try await Self.seedAccount(database, suffix: "second")
    let firstStore = RecentSearchStore(database: database, accountId: first)
    let secondStore = RecentSearchStore(database: database, accountId: second)

    try await firstStore.record(query: "gaiman")
    try await secondStore.record(query: "pratchett")

    try AccountRemover(database: database).removeAccount(accountId: first)

    #expect(await firstStore.fetchRecent().isEmpty)
    #expect(await secondStore.fetchRecent().map(\.displayQuery) == ["pratchett"])
  }

  @Test("a query below the minimum length is never recorded")
  func belowMinimumLengthIsNeverRecorded() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let store = RecentSearchStore(database: database, accountId: accountId)

    try await store.record(query: "a")
    try await store.record(query: " ")
    try await store.record(query: "")

    #expect(await store.fetchRecent().isEmpty)
  }

  @Test("observeRecent re-emits most-recently-used first on every record and clear")
  func observeRecentReemitsMostRecentlyUsedFirst() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let store = RecentSearchStore(database: database, accountId: accountId)
    let observations = PersistenceObservationCollector(store.observeRecent())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    try await store.record(query: "gaiman")
    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty == false } })
    var rows = try #require(observations.last { $0.isEmpty == false })
    #expect(rows.map(\.displayQuery) == ["gaiman"])

    try await store.record(query: "pratchett")
    #expect(await TestSupport.waitUntil { observations.contains { $0.count >= 2 } })
    rows = try #require(observations.last { $0.count >= 2 })
    #expect(rows.map(\.displayQuery) == ["pratchett", "gaiman"])
  }

  @Test("a suspended snapshot consumer resumes with complete states that only move forward")
  func suspendedSnapshotConsumerResumesWithForwardOnlyCompleteStates() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await Self.seedAccount(database)
    let store = RecentSearchStore(database: database, accountId: accountId)
    let stream = store.observeRecent()
    do {
      let initialObservations = PersistenceObservationCollector(stream, stopAfter: 1)
      #expect(await TestSupport.waitUntil { initialObservations.values.isEmpty == false })
      let initial = try #require(initialObservations.values.first)
      #expect(initial.isEmpty)
    }

    // Each write is confirmed to have re-run the tracked query before the next is issued. Sleeping
    // could let the three commits coalesce into one observation cycle on a slow machine, so the
    // test would pass without a superseded state ever existing. The descending order is the
    // observation's own; `evictBeyondCap` sorts ascending and never runs at three rows.
    let recentFetches = Mutex(0)
    try await database.writeAsync { db in
      db.trace { event in
        guard case .statement(let statement) = event else { return }
        guard statement.sql.contains("recentSearch"), statement.sql.contains("DESC") else { return }
        recentFetches.withLock { $0 += 1 }
      }
    }

    // Leave the iterator suspended while three independently committed states reach the
    // observation bridge. Each complete array replaces its predecessor; replaying the one- and
    // two-row intermediates would only make a resumed screen do obsolete work.
    for (index, query) in ["one", "two", "three"].enumerated() {
      try await store.record(query: query)
      await waitUntil { recentFetches.withLock { $0 } >= index + 1 }
    }

    #expect(recentFetches.withLock { $0 } >= 3, "each write must produce its own observation cycle")

    // The trace confirms each fetch ran before the next write, but delivery is asynchronous: GRDB
    // hands the value to a scheduler and the bridging task adds a second hop before the outer
    // buffer. Under full-suite load either hop can be in flight, so the resumed consumer may get
    // the one-row state, as `.bufferingNewest(1)` collapses only what has landed. Guaranteed:
    // every resumed value is a complete snapshot strictly newer than its predecessor, and the
    // drain ends at the newest state.
    let observations = PersistenceObservationCollector(stream)
    #expect(await TestSupport.waitUntil { observations.contains { $0.count >= 3 } })
    let states = observations.values
    for (previous, latest) in zip(states, states.dropFirst()) {
      #expect(
        latest.count > previous.count, "a resumed state must strictly supersede its predecessor")
    }
    let latest = try #require(observations.last { $0.count >= 3 })
    #expect(latest.map(\.displayQuery) == ["three", "two", "one"])
  }

  // MARK: - Helpers

  @discardableResult
  private static func seedAccount(_ database: AppDatabase, suffix: String = "primary") async throws
    -> Int64
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }
}
