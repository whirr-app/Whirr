import ABSApi
import Foundation
import TestSupport
import Testing

@testable import PodcastFeeds

/// The mechanics both feed clients delegate to: one flight per key, last-waiter cancellation, and
/// per-URL pacing. The clients' own suites pin the transport and parser around this.
@Suite struct URLFlightPoolTests {
  private let url = URL(string: "https://feeds.example.test/show.xml")!

  @Test func aWaiterArrivingMidFlightJoinsIt() async throws {
    var pool = makeURLPool()
    var starts = 0
    let gate = makeFlightGate()
    let first = pool.joinOrStart(key: url, waiterID: UUID()) {
      starts += 1
      return Task {
        await gate.pass()
        return 1
      }
    }
    let joined = pool.joinOrStart(key: url, waiterID: UUID()) {
      starts += 1
      return Task { 2 }
    }

    #expect(starts == 1, "the second caller must not start its own request")
    gate.release()
    #expect(try await first.value == 1)
    #expect(try await joined.value == 1)
    #expect(pool.flightCount == 1, "the flight stays until a caller finishes it")
  }

  /// A waiter that leaves must not cancel a flight another waiter still holds.
  @Test func aCancelledWaiterLeavesAnotherWaitersFlightRunning() async throws {
    var pool = makeURLPool()
    let cancelled = UUID()
    let joined = UUID()
    let gate = makeFlightGate()
    let flight = pool.joinOrStart(key: url, waiterID: cancelled) {
      Task {
        await gate.pass()
        return Task.isCancelled ? -1 : 1
      }
    }
    let other = pool.joinOrStart(key: url, waiterID: joined) {
      Issue.record("a joiner must not start a second request")
      return Task { 2 }
    }

    pool.finish(key: url, url: url, waiterID: cancelled, cancelling: true, result: nil)
    gate.release()

    #expect(try await other.value == 1)
    #expect(try await flight.value == 1, "the shared task was never cancelled")
  }

  @Test func theLastWaiterOutCancelsTheFlightAndTheNextCallStartsFresh() async throws {
    var pool = makeURLPool()
    let only = UUID()
    let gate = makeFlightGate()
    var starts = 0
    let flight = pool.joinOrStart(key: url, waiterID: only) {
      starts += 1
      return Task {
        await gate.pass()
        return Task.isCancelled ? -1 : 1
      }
    }

    pool.finish(key: url, url: url, waiterID: only, cancelling: true, result: nil)
    gate.release()
    #expect(try await flight.value == -1, "the last waiter's cancellation reaches the transport")
    #expect(pool.flightCount == 0)

    let next = pool.joinOrStart(key: url, waiterID: UUID()) {
      starts += 1
      return Task { 3 }
    }
    #expect(starts == 2)
    #expect(try await next.value == 3)
  }

  @Test func aRetryableFailurePacesItsURLUntilASuccess() async {
    var pool = makeURLPool()
    let error = APIError.serverFailure(statusCode: 503)
    let failing = UUID()
    let task = pool.joinOrStart(key: url, waiterID: failing) {
      Task { throw error }
    }
    _ = try? await task.value
    pool.finish(key: url, url: url, waiterID: failing, cancelling: false, result: .failure(error))

    #expect(pool.backoffRetryAfter(for: url) != nil)

    let succeeding = UUID()
    let next = pool.joinOrStart(key: url, waiterID: succeeding) {
      Task { 1 }
    }
    _ = try? await next.value
    pool.finish(key: url, url: url, waiterID: succeeding, cancelling: false, result: .success(1))

    #expect(pool.backoffRetryAfter(for: url) == nil, "success clears the URL's pacing")
  }

  @Test func aNonRetryableFailureLeavesNoPacing() async {
    var pool = makeURLPool()
    let error = APIError.notFound
    let only = UUID()
    let task = pool.joinOrStart(key: url, waiterID: only) {
      Task { throw error }
    }
    _ = try? await task.value
    pool.finish(key: url, url: url, waiterID: only, cancelling: false, result: .failure(error))

    #expect(pool.backoffRetryAfter(for: url) == nil)
  }

  /// Pacing is keyed by URL, not by the flight key: two credentials for one feed share the pace
  /// even though their responses never coalesce.
  @Test func pacingIsPerURLWhileFlightsArePerKey() async throws {
    var pool = makeKeyPool()
    let credentialA = Key(url: url, fingerprint: "a")
    let credentialB = Key(url: url, fingerprint: "b")
    let waiterA = UUID()
    let waiterB = UUID()
    let gate = makeFlightGate()
    var starts = 0
    let first = pool.joinOrStart(key: credentialA, waiterID: waiterA) {
      starts += 1
      return Task {
        await gate.pass()
        return 1
      }
    }
    let second = pool.joinOrStart(key: credentialB, waiterID: waiterB) {
      starts += 1
      return Task {
        await gate.pass()
        return 2
      }
    }

    #expect(starts == 2, "different credentials never share a flight")
    gate.release()
    _ = try await first.value
    _ = try await second.value
    pool.finish(
      key: credentialA, url: url, waiterID: waiterA, cancelling: false, result: .success(1))
    pool.finish(
      key: credentialB, url: url, waiterID: waiterB, cancelling: false, result: .success(2))

    let error = APIError.serverFailure(statusCode: 503)
    let failing = UUID()
    let task = pool.joinOrStart(key: credentialA, waiterID: failing) {
      Task { throw error }
    }
    _ = try? await task.value
    pool.finish(
      key: credentialA, url: url, waiterID: failing, cancelling: false, result: .failure(error))
    #expect(pool.backoffRetryAfter(for: url) != nil, "the pace covers every credential for the URL")
  }

  // MARK: - Helpers

  private struct Key: Hashable {
    let url: URL
    let fingerprint: String
  }

  private func makeURLPool() -> URLFlightPool<URL, Int> {
    URLFlightPool<URL, Int>(now: { Date(timeIntervalSince1970: 1_000) }, randomUnit: { 1 })
  }

  private func makeKeyPool() -> URLFlightPool<Key, Int> {
    URLFlightPool<Key, Int>(now: { Date(timeIntervalSince1970: 1_000) }, randomUnit: { 1 })
  }
}

/// A held gate for a flight's task. The task stays parked on cancellation and sees
/// `Task.isCancelled` only once released, as the real transport would.
private func makeFlightGate() -> TestGate<Void> {
  let gate = TestGate<Void>(label: "URLFlightPool flight", ignoresCancellation: true)
  gate.hold()
  return gate
}
