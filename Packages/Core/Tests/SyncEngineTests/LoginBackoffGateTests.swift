import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("Login backoff gate")
struct LoginBackoffGateTests {
  @Test func concurrentAdmissionsReserveExactlyOneAttempt() async {
    let gate = LoginBackoffGate(now: { Date(timeIntervalSince1970: 0) }, randomUnit: { 1 })

    let results = await withTaskGroup(of: TimeInterval?.self, returning: [TimeInterval?].self) {
      group in
      for _ in 0..<32 {
        group.addTask { await gate.admit() }
      }
      var results: [TimeInterval?] = []
      for await result in group { results.append(result) }
      return results
    }

    #expect(results.filter { $0 == nil }.count == 1)
    #expect(results.filter { $0 != nil }.count == 31)
  }

  @Test func zeroJitterWindowAdmitsTheNextAttempt() async {
    let gate = LoginBackoffGate(
      now: { Date(timeIntervalSince1970: 0) }, randomUnit: { 0 })

    #expect(await gate.admit() == nil)
    await gate.recordFailure()

    #expect(await gate.admit() == nil)
  }

  @Test func failureReleasesReservationAndArmsTheWindow() async {
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })

    #expect(await gate.admit() == nil)
    await gate.recordFailure()
    #expect(await gate.admit() == 1)

    clock.advance(by: 1)
    #expect(await gate.admit() == nil)
  }

  @Test func successReleasesReservationAndClearsTheWindow() async {
    let gate = LoginBackoffGate(
      now: { Date(timeIntervalSince1970: 0) }, randomUnit: { 1 })

    #expect(await gate.admit() == nil)
    await gate.recordFailure()
    #expect(await gate.admit() != nil)

    await gate.recordSuccess()
    #expect(await gate.admit() == nil)
  }

  @Test func releaseReservationKeepsBackoffHistory() async {
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })

    #expect(await gate.admit() == nil)
    await gate.recordFailure()
    clock.advance(by: 1)

    #expect(await gate.admit() == nil)
    await gate.releaseReservation()

    #expect(await gate.admit() == nil)
    await gate.recordFailure()
    #expect(await gate.admit() == 2, "a released reservation must not reset the failure counter")
  }

  /// The setup read that throws here is `existingAccountState()`'s Keychain load. It reaches the
  /// caller as `.localStateUnreadable`, not as the store's own error type: an unclassified
  /// rethrow lands in `SetupFlowModel`'s catch-all and renders the generic "something went wrong"
  /// copy. This test covers the other half: the reservation is released, so the next attempt is
  /// still admitted.
  @Test func setupThrowAfterAdmissionDoesNotWedgeTheNextLogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var account = AccountRecord(
        clientUUID: "existing-uuid",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user-1",
        serverVersion: "2.36.0")
      try account.save(db)
    }
    let tokenStore = FakeTokenStoring()
    tokenStore.stubLoadFailure(FakeTokenStoring.Failure(), times: 1)
    let gate = LoginBackoffGate(
      now: { Date(timeIntervalSince1970: 0) }, randomUnit: { 1 })
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      loginBackoffGate: gate)
    let server = ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!,
      serverVersion: "2.36.0",
      isPlainHTTP: false)

    await #expect(throws: AccountLifecycleError.localStateUnreadable) {
      try await service.login(server: server, username: "user", password: "password")
    }
    try await service.login(server: server, username: "user", password: "password")

    #expect(await transport.requests.count == 1)
  }
}
