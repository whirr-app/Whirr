import Foundation
import Testing

@testable import TestSupport

/// Adversarial tests for the on-disk fixture itself.
///
/// Every case builds its own gate and census, not `.shared`: other on-disk suites run alongside,
/// so asserting `liveScopes == 0` on a process-wide counter would speak for the whole process.
/// Private instances make the accounting exact and the assertions deterministic.
@Suite struct OnDiskDatabaseGateTests {

  @Test func concurrentScopesNeverExceedThePermitLimit() async throws {
    let gate = OnDiskDatabaseGate(limit: 3)
    let census = OnDiskDatabaseCensus()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<12 {
        group.addTask {
          try await withOnDiskDatabases(named: "gate-cap-\(index)", gate: gate, census: census) {
            scope in
            _ = try scope.open()
            try await Task.sleep(for: .milliseconds(20))
          }
        }
      }
      try await group.waitForAll()
    }

    let snapshot = census.snapshot
    #expect(snapshot.peakLiveScopes <= gate.permitLimit)
    #expect(snapshot.peakLiveScopes > 1, "the group should have exercised real concurrency")
    #expect(snapshot.peakLiveDatabases <= gate.permitLimit)
    #expect(snapshot.openedDatabases == 12)
    #expect(snapshot.liveDatabases == 0)
    #expect(snapshot.liveScopes == 0)
    #expect(gate.liveScopes == 0)
  }

  @Test func normalScopeTeardownClosesDatabasesAndRemovesScratchDirectory() async throws {
    let gate = OnDiskDatabaseGate(limit: 2)
    let census = OnDiskDatabaseCensus()
    let scratchDirectory = Locked<URL?>(nil)

    try await withOnDiskDatabases(named: "gate-normal-teardown", gate: gate, census: census) {
      scope in
      scratchDirectory.value = scope.directoryURL
      _ = try scope.open("first.sqlite")
      _ = try scope.open("second.sqlite")
      #expect(scope.openDatabaseCount == 2)
      #expect(census.snapshot.liveDatabases == 2)
    }

    #expect(census.snapshot.liveDatabases == 0)
    #expect(census.snapshot.liveScopes == 0)
    #expect(gate.liveScopes == 0)
    let directory = try #require(scratchDirectory.value)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  }

  @Test func throwingScopeTeardownClosesDatabasesAndRemovesScratchDirectory() async throws {
    let gate = OnDiskDatabaseGate(limit: 2)
    let census = OnDiskDatabaseCensus()
    let scratchDirectory = Locked<URL?>(nil)

    await #expect(throws: ScopeBodyFailure.self) {
      try await withOnDiskDatabases(named: "gate-throwing-teardown", gate: gate, census: census) {
        scope in
        scratchDirectory.value = scope.directoryURL
        _ = try scope.open("first.sqlite")
        _ = try scope.open("second.sqlite")
        throw ScopeBodyFailure()
      }
    }

    #expect(census.snapshot.liveDatabases == 0)
    #expect(census.snapshot.liveScopes == 0)
    #expect(gate.liveScopes == 0, "a throwing body must still return its permit")
    let directory = try #require(scratchDirectory.value)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
  }

  @Test func aCancelledWaiterCompletesInsteadOfRemainingParked() async throws {
    let gate = OnDiskDatabaseGate(limit: 1)
    let census = OnDiskDatabaseCensus()
    let holderEntered = Locked(false)
    let waiterFinished = Locked(false)

    let holder = Task {
      try? await withOnDiskDatabases(named: "gate-holder", gate: gate, census: census) { scope in
        _ = try scope.open()
        holderEntered.value = true
        try await Task.sleep(for: .seconds(60))
      }
    }
    #expect(await waitUntil { holderEntered.value })

    let waiter = Task {
      defer { waiterFinished.value = true }
      try? await withOnDiskDatabases(named: "gate-waiter", gate: gate, census: census) { _ in }
    }
    // The waiter cannot be admitted while the holder has the only permit, so it is parked here.
    #expect(waiterFinished.value == false)
    waiter.cancel()

    #expect(
      await waitUntil { waiterFinished.value },
      "a cancelled gate waiter must not remain parked")
    await waiter.value

    holder.cancel()
    await holder.value
    #expect(census.snapshot.liveDatabases == 0)
    #expect(census.snapshot.liveScopes == 0)
    #expect(gate.liveScopes == 0, "cancellation must not leak a permit")
  }

  @Test func aWaiterCancelledAfterParkingAlsoUnwinds() async throws {
    let gate = OnDiskDatabaseGate(limit: 1)
    let census = OnDiskDatabaseCensus()
    let holderEntered = Locked(false)
    let waiterFinished = Locked(false)

    let holder = Task {
      try? await withOnDiskDatabases(named: "parked-holder", gate: gate, census: census) { scope in
        _ = try scope.open()
        holderEntered.value = true
        try await Task.sleep(for: .seconds(60))
      }
    }
    #expect(await waitUntil { holderEntered.value })

    let waiter = Task {
      defer { waiterFinished.value = true }
      try? await withOnDiskDatabases(named: "parked-waiter", gate: gate, census: census) { _ in }
    }
    // Unlike the case above, this one waits until the waiter has actually parked. The two together
    // cover both sides of the registration window: cancellation before the continuation exists, and
    // cancellation of one already in the queue.
    #expect(await waitUntil { gate.waitingScopes == 1 })
    waiter.cancel()

    #expect(
      await waitUntil { waiterFinished.value },
      "a waiter cancelled after parking must not stay in the queue")
    await waiter.value

    holder.cancel()
    await holder.value
    #expect(gate.liveScopes == 0, "cancellation must not leak a permit")
    #expect(gate.waitingScopes == 0)
  }

  @Test func theSuiteScopedFormReturnsItsPermitWhenReleased() async throws {
    let gate = OnDiskDatabaseGate(limit: 1)
    let census = OnDiskDatabaseCensus()
    let scratchDirectory: URL

    do {
      let fixture = try await SuiteOnDiskDatabases.acquire(
        named: "gate-suite-scoped", gate: gate, census: census)
      scratchDirectory = fixture.scope.directoryURL
      _ = try fixture.scope.open()
      #expect(census.snapshot.liveDatabases == 1)
      #expect(gate.liveScopes == 1)
    }

    #expect(census.snapshot.liveDatabases == 0)
    #expect(census.snapshot.liveScopes == 0)
    #expect(gate.liveScopes == 0)
    #expect(FileManager.default.fileExists(atPath: scratchDirectory.path) == false)
  }
}

private struct ScopeBodyFailure: Error {}
