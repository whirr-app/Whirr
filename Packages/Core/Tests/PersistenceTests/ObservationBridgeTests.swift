import Foundation
import GRDB
import Synchronization
import TestSupport
import Testing

@testable import Persistence

@Suite struct ObservationBridgeTests {
  @Test("delivers the initial value")
  func deliversInitialValue() async throws {
    let database = try AppDatabase.inMemory()
    let stream = ObservationBridge.stream(in: database.dbWriter) { _ in 7 }
    var iterator = stream.makeAsyncIterator()

    #expect(await iterator.next() == 7)
  }

  @Test("observes a subsequent write")
  func observesSubsequentWrite() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE bridgeValue (value INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO bridgeValue (value) VALUES (0)")
    }
    let stream = ObservationBridge.stream(in: database.dbWriter) { db in
      try Int.fetchOne(db, sql: "SELECT value FROM bridgeValue")!
    }
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == 0)

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET value = 1")
    }

    #expect(await iterator.next() == 1)
  }

  @Test("cancelling the consuming task cancels the observation")
  func cancellingConsumingTaskCancelsObservation() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE bridgeValue (value INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO bridgeValue (value) VALUES (0)")
    }
    let fetchCount = Mutex(0)
    let stream = ObservationBridge.stream(in: database.dbWriter) { db in
      fetchCount.withLock { $0 += 1 }
      return try Int.fetchOne(db, sql: "SELECT value FROM bridgeValue")!
    }
    let consumer = Task {
      var iterator = stream.makeAsyncIterator()
      _ = await iterator.next()
      return await iterator.next()
    }
    #expect(await TestSupport.waitUntil { fetchCount.withLock { $0 >= 1 } })
    consumer.cancel()
    #expect(await consumer.value == nil)

    let countAfterCancellation = fetchCount.withLock { $0 }
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET value = 1")
    }
    #expect(fetchCount.withLock { $0 } == countAfterCancellation)

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
  }

  @Test("restarts after a transient observation error")
  func restartsAfterTransientObservationError() async throws {
    let database = try AppDatabase.inMemory()
    let fetchCount = Mutex(0)
    let stream = ObservationBridge.stream(in: database.dbWriter) { _ in
      let attempt = fetchCount.withLock { count in
        count += 1
        return count
      }
      if attempt == 1 {
        throw ObservationBridgeTestError.expected
      }
      return 7
    }

    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == 7)
    #expect(fetchCount.withLock { $0 } == 2)
  }

  @Test("everyChange forwards a write that leaves the value equal")
  func everyChangeForwardsAnEqualValue() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(
        sql: "CREATE TABLE bridgeValue (value INTEGER NOT NULL, revision INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO bridgeValue (value, revision) VALUES (0, 0)")
    }
    let received = PersistenceObservationCollector(
      ObservationBridge.stream(in: database.dbWriter, deduplication: .everyChange) {
        db -> Int in
        // Both columns are read, so a revision-only write is a change the observation re-reads
        // while the value a consumer keys on stays equal.
        let row = try Row.fetchOne(db, sql: "SELECT value, revision FROM bridgeValue")!
        return row["value"]
      })
    #expect(await waitUntil("initial value") { received.values == [0] })

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET revision = 1")
    }
    #expect(await waitUntil("equal value forwarded") { received.values == [0, 0] })
  }

  @Test("unchangedValuesSuppressed forwards only a value that moved")
  func unchangedValuesSuppressedForwardsOnlyAValueThatMoved() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(
        sql: "CREATE TABLE bridgeValue (value INTEGER NOT NULL, revision INTEGER NOT NULL)")
      try db.execute(sql: "INSERT INTO bridgeValue (value, revision) VALUES (0, 0)")
    }
    let fetchCount = Mutex(0)
    let received = PersistenceObservationCollector(
      ObservationBridge.stream(
        in: database.dbWriter, deduplication: .unchangedValuesSuppressed
      ) { db -> Int in
        fetchCount.withLock { $0 += 1 }
        // Both columns are read, so a revision-only write re-runs this fetch and its equal value
        // must be suppressed.
        let row = try Row.fetchOne(db, sql: "SELECT value, revision FROM bridgeValue")!
        return row["value"]
      })
    #expect(await waitUntil("initial fetch") { fetchCount.withLock { $0 == 1 } })
    #expect(await waitUntil("initial value") { received.values == [0] })

    let fetchesBeforeEqualWrite = fetchCount.withLock { $0 }
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET revision = 1")
    }
    // The observation re-read the row; the equal value is not forwarded.
    #expect(await waitUntil { fetchCount.withLock { $0 > fetchesBeforeEqualWrite } })
    #expect(received.values == [0])

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET value = 1, revision = 2")
    }
    #expect(await waitUntil("the moved value") { received.values == [0, 1] })
  }

  @Test("a restarted removeDuplicates observation resumes from a fresh baseline")
  func restartedRemoveDuplicatesObservationResumesFromFreshBaseline() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      try db.execute(
        sql: "CREATE TABLE bridgeValue (value INTEGER NOT NULL, revision INTEGER NOT NULL)"
      )
      try db.execute(sql: "INSERT INTO bridgeValue (value, revision) VALUES (0, 0)")
    }
    let fetchCount = Mutex(0)
    let failNextFetch = Mutex(false)
    let observation = ValueObservation.tracking { db -> Int in
      fetchCount.withLock { $0 += 1 }
      let row = try Row.fetchOne(db, sql: "SELECT value, revision FROM bridgeValue")!
      let shouldFail = failNextFetch.withLock { shouldFail in
        defer { shouldFail = false }
        return shouldFail
      }
      if shouldFail {
        throw ObservationBridgeTestError.expected
      }
      return row["value"]
    }.removeDuplicates()
    let stream = ObservationBridge.stream(in: database.dbWriter, observation: observation)
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == 0)

    failNextFetch.withLock { $0 = true }
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET revision = 1")
    }

    // removeDuplicates owns per-subscription state, so the retry re-emits the
    // unchanged value once as its new baseline.
    #expect(await iterator.next() == 0)

    let fetchesBeforeUnchangedWrite = fetchCount.withLock { $0 }
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET revision = 2")
    }
    #expect(
      await TestSupport.waitUntil {
        fetchCount.withLock { $0 > fetchesBeforeUnchangedWrite }
      })

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE bridgeValue SET value = 1, revision = 3")
    }
    #expect(await iterator.next() == 1)
  }
}

private enum ObservationBridgeTestError: Error {
  case expected
}
