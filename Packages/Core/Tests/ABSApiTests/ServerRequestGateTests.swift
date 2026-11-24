import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Server request gate")
struct ServerRequestGateTests {
  @Test("admits at most four requests and releases permits after success or failure")
  func boundsInFlightRequestsAndReleasesPermits() async throws {
    let gate = ServerRequestGate()
    let permits = try await (0..<4).asyncMap { _ in try await gate.acquire() }

    #expect(await gate.inFlightCount == 4)
    let fifth = Task { try await gate.acquire() }
    await waitUntil { await gate.queuedCount == 1 }
    #expect(await gate.inFlightCount == 4)

    await permits[0].release()
    let fifthPermit = try await fifth.value
    #expect(await gate.inFlightCount == 4)
    await fifthPermit.release()
    for permit in permits.dropFirst() {
      await permit.release()
    }
    #expect(await gate.inFlightCount == 0)

    enum ExpectedFailure: Error { case failed }
    await #expect(throws: ExpectedFailure.self) {
      try await gate.withPermit {
        throw ExpectedFailure.failed
      }
    }
    #expect(await gate.inFlightCount == 0)
  }

  @Test("admits queued requests in FIFO order")
  func preservesAdmissionOrder() async throws {
    let gate = ServerRequestGate()
    let permits = try await (0..<4).asyncMap { _ in try await gate.acquire() }
    let first = Task { try await gate.acquire() }
    let second = Task { try await gate.acquire() }

    await waitUntil { await gate.queuedCount == 2 }
    await permits[0].release()
    let firstPermit = try await first.value
    #expect(await gate.queuedCount == 1)
    await permits[1].release()
    let secondPermit = try await second.value

    await firstPermit.release()
    await secondPermit.release()
    for permit in permits.dropFirst(2) {
      await permit.release()
    }
    #expect(await gate.inFlightCount == 0)
  }

  @Test("removes a cancelled waiter without consuming a later permit")
  func removesCancelledWaiter() async throws {
    let gate = ServerRequestGate()
    let permits = try await (0..<4).asyncMap { _ in try await gate.acquire() }
    let cancelled = Task { try await gate.acquire() }

    await waitUntil { await gate.queuedCount == 1 }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await gate.queuedCount == 0)

    await permits[0].release()
    #expect(await gate.inFlightCount == 3)
    for permit in permits.dropFirst() {
      await permit.release()
    }
    #expect(await gate.inFlightCount == 0)
  }
}

@Suite("Backoff policy")
struct BackoffTests {
  @Test("uses exponential delays with bounded full jitter")
  func exponentialJitterAndCap() {
    var policy = BackoffPolicy()

    #expect(policy.nextDelay(randomUnit: 1) == 1)
    #expect(policy.nextDelay(randomUnit: 1) == 2)
    #expect(policy.nextDelay(randomUnit: 0.5) == 2)
    #expect(policy.nextDelay(randomUnit: 1) == 8)
    #expect(policy.nextDelay(randomUnit: 1) == 16)
    #expect(policy.nextDelay(randomUnit: 1) == 32)
    #expect(policy.nextDelay(randomUnit: 1) == 64)
    #expect(policy.nextDelay(randomUnit: 1) == 128)
    #expect(policy.nextDelay(randomUnit: 1) == 256)
    #expect(policy.nextDelay(randomUnit: 1) == 300)

    let low = policy.nextDelay(randomUnit: 0)
    #expect(low >= 0 && low <= 300)
  }

  @Test("honors sane Retry-After values and ignores unsafe values")
  func retryAfter() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var policy = BackoffPolicy()

    #expect(policy.nextDelay(retryAfter: "7", now: now, randomUnit: 0) == 7)
    #expect(policy.nextDelay(retryAfter: "999", now: now, randomUnit: 1) == 2)
    #expect(policy.nextDelay(retryAfter: "Mon, 12 Jan 1970 13:46:48 GMT", now: now, randomUnit: 0) == 8)
  }

  @Test("resets failure growth after success")
  func resetOnSuccess() {
    var policy = BackoffPolicy()
    _ = policy.nextDelay(randomUnit: 1)
    _ = policy.nextDelay(randomUnit: 1)
    policy.reset()
    #expect(policy.nextDelay(randomUnit: 1) == 1)
  }

  @Test("seeding failureCount reproduces the same delay a fresh policy reaches after that many calls")
  func seededFailureCountMatchesEquivalentFreshSequence() {
    var fresh = BackoffPolicy()
    _ = fresh.nextDelay(randomUnit: 1)
    _ = fresh.nextDelay(randomUnit: 1)
    let freshThirdDelay = fresh.nextDelay(randomUnit: 1)

    var seeded = BackoffPolicy(failureCount: 2)
    let seededThirdDelay = seeded.nextDelay(randomUnit: 1)

    #expect(seededThirdDelay == freshThirdDelay)
    #expect(BackoffPolicy(failureCount: 0).failureCount == 0)
  }

  @Test("retries only transient transport, rate-limit, and server failures")
  func retryClassification() {
    #expect(BackoffPolicy.isRetryable(APIError.transport))
    #expect(BackoffPolicy.isRetryable(APIError.rateLimited))
    #expect(BackoffPolicy.isRetryable(APIError.serverFailure(statusCode: 503)))

    for error in [
      APIError.cancelled,
      APIError.unauthorized,
      APIError.forbidden,
      APIError.notFound,
      APIError.decoding,
      APIError.unexpectedStatus(statusCode: 400),
    ] {
      #expect(BackoffPolicy.isRetryable(error) == false)
    }
  }
}

extension Sequence {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var values: [T] = []
    for element in self {
      values.append(try await transform(element))
    }
    return values
  }
}
