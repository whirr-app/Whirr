import Foundation
import Synchronization
import TestSupport
import Testing

@testable import AppModel
@testable import Persistence

@Suite("Native episode server-save status projection", .timeLimit(.minutes(1)))
struct NativeEpisodeServerSaveStatusProjectionTests {
  @Test("NoOp returns no status")
  func noOpReturnsNone() async {
    let snapshot = await NoOpNativeEpisodeServerSaveStatusReading().status(feedId: 1, episodeId: 2)
    #expect(snapshot == NativeEpisodeServerSaveStatusSnapshot(status: .none))
  }

  @Test("no signed-in account returns none")
  func noAccountReturnsNone() async throws {
    let database = try AppDatabase.inMemory()
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: NativeEpisodeServerSaveAttemptStore(database: database),
      accountIDReading: StubAccountIDReading(result: .failure(.noAccount)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let snapshot = await projection.status(feedId: 1, episodeId: 2)
    #expect(snapshot.status == .none)
    #expect(snapshot.attemptID == nil)
  }

  @Test("failed account read returns none rather than a stale row")
  func failedAccountReadReturnsNone() async throws {
    let database = try AppDatabase.inMemory()
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: NativeEpisodeServerSaveAttemptStore(database: database),
      accountIDReading: StubAccountIDReading(result: .failure(.readFailed)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let snapshot = await projection.status(feedId: 1, episodeId: 2)
    #expect(snapshot == NativeEpisodeServerSaveStatusSnapshot(status: .none))
  }

  @Test("native subscriptions toggled off returns none")
  func disabledNativeSubscriptionsReturnNone() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode",
      now: Date(timeIntervalSince1970: 20))
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .failed, errorCategory: .transport,
      now: Date(timeIntervalSince1970: 21))
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: false))

    #expect(await projection.status(feedId: 1, episodeId: 2).status == .none)
  }

  @Test("lifecycle reads hide a sent row without transitioning or revoking it")
  func lifecycleReadsNeverMutateSentRow() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest, now: Date(timeIntervalSince1970: 20))
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "show",
      now: Date(timeIntervalSince1970: 21))
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .accepted, now: Date(timeIntervalSince1970: 22))

    let disabledProjection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: false))
    let loggedOutProjection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .failure(.noAccount)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))
    let replacementProjection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID + 1)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    for projection in [disabledProjection, loggedOutProjection, replacementProjection] {
      #expect(await projection.status(feedId: 1, episodeId: 2).status == .none)
      #expect(try await store.fetchAttemptAsync(id: attempt.id!)?.state == .accepted)
    }
  }

  @Test("the most recently updated attempt is projected")
  func mostRecentlyUpdatedAttemptWins() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let older = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode",
      now: Date(timeIntervalSince1970: 10))
    _ = try await store.transitionAsync(
      attemptId: older.id!, to: .failed, errorCategory: .transport,
      now: Date(timeIntervalSince1970: 11))
    let newer = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest, now: Date(timeIntervalSince1970: 20))
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let snapshot = await projection.status(feedId: 1, episodeId: 2)
    #expect(snapshot.status == .preparing)
    #expect(snapshot.attemptID == newer.id)
    #expect(snapshot.preflightPresence == .absentBeforeRequest)
  }

  @Test("projection reports durable state and preserves its provenance")
  func projectionReportsDurableState() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 3, episodeId: 4, episodeIdentityKey: "episode",
      preflightPresence: .absentBeforeRequest, now: Date(timeIntervalSince1970: 30))
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .failed, errorCategory: .invalidDestination,
      now: Date(timeIntervalSince1970: 31))
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let snapshot = await projection.status(feedId: 3, episodeId: 4)
    #expect(snapshot.status == .failed(.invalidDestination, phase: .save))
    #expect(snapshot.attemptID == attempt.id)
    #expect(snapshot.preflightPresence == .absentBeforeRequest)
    #expect(try await store.fetchAttemptAsync(id: attempt.id!)?.state == .failed)
  }

  @Test("the list read projects the latest attempt per episode from one query")
  func listReadProjectsLatestAttemptPerEpisode() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let older = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two",
      now: Date(timeIntervalSince1970: 10))
    _ = try await store.transitionAsync(
      attemptId: older.id!, to: .failed, errorCategory: .transport,
      now: Date(timeIntervalSince1970: 11))
    let newer = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two",
      preflightPresence: .absentBeforeRequest, now: Date(timeIntervalSince1970: 20))
    let three = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 3, episodeIdentityKey: "three",
      now: Date(timeIntervalSince1970: 30))
    _ = try await store.transitionAsync(
      attemptId: three.id!, to: .failed, errorCategory: .invalidDestination,
      now: Date(timeIntervalSince1970: 31))
    // Same episode row id in another feed: never this feed's answer.
    _ = try await store.createAttemptAsync(
      accountId: accountID, feedId: 9, episodeId: 4, episodeIdentityKey: "elsewhere",
      now: Date(timeIntervalSince1970: 40))
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let snapshots = await projection.statuses(feedId: 1, episodeIds: [2, 3, 4, 5])

    #expect(snapshots.count == 2)
    #expect(snapshots[2]?.status == .preparing)
    #expect(snapshots[2]?.attemptID == newer.id)
    #expect(snapshots[2]?.preflightPresence == .absentBeforeRequest)
    #expect(snapshots[3]?.status == .failed(.invalidDestination, phase: .save))
    #expect(snapshots[3]?.attemptID == three.id)
    #expect(snapshots[4] == nil)
    #expect(snapshots[5] == nil)
    #expect(await projection.statuses(feedId: 1, episodeIds: []).isEmpty)
  }

  /// Two attempts for one episode written at the same instant: the later row id is current, in
  /// both the single read and the list read. Fetch order must not decide it.
  @Test("a coincident updatedAt never lets the earlier row mask a newer attempt")
  func coincidentUpdatedAtPrefersTheLaterRow() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let timestamp = Date(timeIntervalSince1970: 20)
    let first = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two", now: timestamp)
    let second = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two", now: timestamp)
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    #expect(first.isOlder(than: second))
    #expect(await projection.status(feedId: 1, episodeId: 2).attemptID == second.id)
    #expect(await projection.statuses(feedId: 1, episodeIds: [2])[2]?.attemptID == second.id)
  }

  @Test("the list read is silenced by the same gates as the single read")
  func listReadHonoursTheSingleReadGates() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    _ = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "two",
      now: Date(timeIntervalSince1970: 10))
    let disabled = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: false))
    let loggedOut = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .failure(.noAccount)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    #expect(await disabled.statuses(feedId: 1, episodeIds: [2]).isEmpty)
    #expect(await loggedOut.statuses(feedId: 1, episodeIds: [2]).isEmpty)
    #expect(await NoOpNativeEpisodeServerSaveStatusReading().statuses(feedId: 1, episodeIds: [2]).isEmpty)
  }

  @Test("observeStatuses yields empty and finishes when native subscriptions are disabled")
  func observeStatusesDisabledGateYieldsEmptyAndFinishes() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    _ = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: false))

    var iterator = projection.observeStatuses(feedId: 1, episodeIds: [2]).makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == [:])
    let second = await iterator.next()
    #expect(second == nil)
  }

  @Test("observeStatuses yields empty and finishes when there is no signed-in account")
  func observeStatusesNoAccountYieldsEmptyAndFinishes() async throws {
    let database = try AppDatabase.inMemory()
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: NativeEpisodeServerSaveAttemptStore(database: database),
      accountIDReading: StubAccountIDReading(result: .failure(.noAccount)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    var iterator = projection.observeStatuses(feedId: 1, episodeIds: [2]).makeAsyncIterator()
    let first = await iterator.next()
    #expect(first == [:])
    let second = await iterator.next()
    #expect(second == nil)
  }

  @Test("observeStatuses reaches a subscriber for a DB-level removal without a new subscribe call")
  func observeStatusesReportsADurableRemovalWithoutAFreshSubscription() async throws {
    let (database, accountID) = try makeDatabaseWithAccount()
    let store = NativeEpisodeServerSaveAttemptStore(database: database)
    let attempt = try await store.createAttemptAsync(
      accountId: accountID, feedId: 1, episodeId: 2, episodeIdentityKey: "episode")
    let projection = NativeEpisodeServerSaveStatusProjection(
      attemptStore: store,
      accountIDReading: StubAccountIDReading(result: .success(accountID)),
      nativeSubscriptionsReading: FakeNativePodcastSubscriptionsReading(enabled: true))

    let observations = ProjectionObservationCollector(
      projection.observeStatuses(feedId: 1, episodeIds: [2]))
    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.status == .preparing }
      })

    _ = try await store.recordPreflightPresenceAsync(.absentBeforeRequest, attemptId: attempt.id!)
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .requestingDownload, serverItemId: "show")
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .accepted)
    _ = try await store.transitionAsync(
      attemptId: attempt.id!, to: .confirmed, serverItemId: "show", serverEpisodeId: "episode-1")
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .deleting)

    // Written directly through the attempt store, not a fake, so this proves the
    // production stream, not the fake `NativeEpisodeServerSaveLiveStatusModelTests` exercises.
    _ = try await store.transitionAsync(attemptId: attempt.id!, to: .removed, serverItemId: "show")

    #expect(
      await TestSupport.waitUntil {
        observations.contains { $0[2]?.status == .removed }
      })
  }

  private func makeDatabaseWithAccount() throws -> (AppDatabase, Int64) {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "projection-client",
        serverBaseURL: "https://server.example",
        serverUserId: "projection-user",
        serverVersion: "2.35.1"))
    return (database, try #require(account.id))
  }
}

private enum StubAccountReadError: Error, Sendable, Equatable {
  case noAccount
  case readFailed
}

private struct StubAccountIDReading: NativeEpisodeServerSaveAccountIDReading, Sendable {
  let result: Result<Int64, StubAccountReadError>

  func currentAccountID() async throws -> Int64 {
    try result.get()
  }
}

private final class ProjectionObservationStorage: @unchecked Sendable {
  let mutex = Mutex<[[Int64: NativeEpisodeServerSaveStatusSnapshot]]>([])
}

/// Collects every emission of an `observeStatuses` stream for polling assertions, mirroring
/// `PersistenceObservationCollector` (`LibraryReadingObservationTests.swift`) for the
/// AppModel-side snapshot type.
private final class ProjectionObservationCollector: @unchecked Sendable {
  private let storage = ProjectionObservationStorage()
  private let task: Task<Void, Never>

  init(_ stream: AsyncStream<[Int64: NativeEpisodeServerSaveStatusSnapshot]>) {
    let storage = storage
    task = Task {
      for await value in stream {
        storage.mutex.withLock { $0.append(value) }
      }
    }
  }

  func contains(where predicate: ([Int64: NativeEpisodeServerSaveStatusSnapshot]) -> Bool) -> Bool {
    storage.mutex.withLock { $0.contains(where: predicate) }
  }

  deinit {
    task.cancel()
  }
}
