import Foundation
import Testing

@testable import SyncEngine

/// `BackgroundTaskPolicy`'s begin/end-exactly-once bookkeeping over an injected
/// `BackgroundTaskProviding`. Never touches a real `UIApplication`; tests drive
/// begin/end/expiration through the fake.
@Suite("BackgroundTaskPolicy")
struct BackgroundTaskPolicyTests {

  @Test("begin calls the provider exactly once and returns a token wrapping its raw identifier")
  func beginCallsProviderExactlyOnce() {
    let fake = FakeBackgroundTaskProviding()
    let policy = BackgroundTaskPolicy(provider: fake)

    let token = policy.beginBackgroundTask {}

    #expect(fake.beginCallCount == 1)
    #expect(token.rawValue == fake.lastIssuedRawValue)
  }

  @Test("end calls the provider exactly once even when called twice for the same token")
  func endCallsProviderExactlyOnceEvenWhenCalledTwice() {
    let fake = FakeBackgroundTaskProviding()
    let policy = BackgroundTaskPolicy(provider: fake)
    let token = policy.beginBackgroundTask {}

    policy.endBackgroundTask(token)
    policy.endBackgroundTask(token)

    #expect(fake.endCallCount == 1)
    #expect(fake.endedRawValues == [fake.lastIssuedRawValue])
  }

  @Test("two separate begin calls end independently, each exactly once")
  func twoTokensEndIndependently() {
    let fake = FakeBackgroundTaskProviding()
    let policy = BackgroundTaskPolicy(provider: fake)

    let first = policy.beginBackgroundTask {}
    let second = policy.beginBackgroundTask {}
    #expect(first != second)

    policy.endBackgroundTask(first)
    #expect(fake.endCallCount == 1)

    policy.endBackgroundTask(second)
    #expect(fake.endCallCount == 2)
    #expect(fake.endedRawValues == [first.rawValue, second.rawValue])
  }

  @Test("the system revoking background time invokes the caller's own expiration handler")
  func expirationInvokesCallersHandler() {
    let fake = FakeBackgroundTaskProviding()
    let policy = BackgroundTaskPolicy(provider: fake)
    let expired = ExpirationFlag()

    _ = policy.beginBackgroundTask { expired.mark() }
    fake.simulateExpiration()

    #expect(expired.value == true)
  }

  @Test("expiration alone does not itself end the task - the caller's own matching end call still must")
  func expirationAloneDoesNotEndTheTask() {
    let fake = FakeBackgroundTaskProviding()
    let policy = BackgroundTaskPolicy(provider: fake)

    let token = policy.beginBackgroundTask {}
    fake.simulateExpiration()
    #expect(fake.endCallCount == 0)

    policy.endBackgroundTask(token)
    #expect(fake.endCallCount == 1)
  }

  @Test("no background time available: begin never invokes the expiration handler, and end is a safe no-op")
  func unavailableBackgroundTimeIsHandledSafely() {
    let fake = FakeBackgroundTaskProviding()
    fake.hasAvailableBackgroundTime = false
    let policy = BackgroundTaskPolicy(provider: fake)
    let expired = ExpirationFlag()

    let token = policy.beginBackgroundTask { expired.mark() }
    policy.endBackgroundTask(token)

    #expect(fake.beginCallCount == 1)
    #expect(expired.value == false)
    #expect(fake.endCallCount == 0)
  }
}

/// A single-write `Bool` flag, safe to mutate from inside an `@escaping @Sendable` expiration
/// handler. These tests only trigger it synchronously on one thread, so no lock is needed, but a
/// plain captured `var` is not `Sendable`.
private final class ExpirationFlag: @unchecked Sendable {
  private(set) var value = false
  func mark() { value = true }
}

/// Test double for `BackgroundTaskProviding`, with no real `UIApplication`. Tests drive
/// expiration via `simulateExpiration()` and force the "no time available" branch with
/// `hasAvailableBackgroundTime = false`.
private final class FakeBackgroundTaskProviding: BackgroundTaskProviding, @unchecked Sendable {
  var hasAvailableBackgroundTime = true

  private(set) var beginCallCount = 0
  private(set) var endCallCount = 0
  private(set) var endedRawValues: Set<Int> = []
  private(set) var lastIssuedRawValue = -1
  private var nextRawValue = 0
  private var pendingExpirationHandlers: [Int: @Sendable () -> Void] = [:]

  func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> Int? {
    beginCallCount += 1
    guard hasAvailableBackgroundTime else { return nil }
    let rawValue = nextRawValue
    nextRawValue += 1
    lastIssuedRawValue = rawValue
    pendingExpirationHandlers[rawValue] = expirationHandler
    return rawValue
  }

  func endTask(_ rawValue: Int) {
    endCallCount += 1
    endedRawValues.insert(rawValue)
    pendingExpirationHandlers.removeValue(forKey: rawValue)
  }

  /// Simulates the system revoking every currently in-flight task's time before its matching
  /// `endTask` call ever arrived.
  func simulateExpiration() {
    for handler in pendingExpirationHandlers.values {
      handler()
    }
  }
}
