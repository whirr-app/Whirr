import SwiftUI
import SyncEngine
import TestSupport
import Testing

@testable import Whirr

/// App-target wiring for `ScenePhaseAppLifecycle`'s `beginBackgroundTask`/`endBackgroundTask`
/// override. It routes to `BackgroundTaskPolicy` through an injected `BackgroundTaskProviding` and
/// never touches a real `UIApplication`. The policy's begin/end, expiration and unavailable-time
/// behaviour is covered in Core. This proves `ScenePhaseAppLifecycle` does not fall through to
/// `AppLifecycle`'s no-op default extension.
@Suite("ScenePhaseAppLifecycle background task wiring")
struct ScenePhaseAppLifecycleBackgroundTaskTests {

  @Test("begin/end round-trip reaches the injected provider exactly once each")
  func beginEndReachesProviderExactlyOnce() {
    let fake = FakeBackgroundTaskProviding()
    let lifecycle = ScenePhaseAppLifecycle(backgroundTaskProviding: fake)

    let token = lifecycle.beginBackgroundTask {}
    #expect(fake.beginCallCount == 1)

    lifecycle.endBackgroundTask(token)
    lifecycle.endBackgroundTask(token)  // A second call must not end the same task twice.

    #expect(fake.endCallCount == 1)
    #expect(fake.endedRawValues == [0])
  }

  @Test("expiration invokes the caller's own expiration handler")
  func expirationInvokesCallersHandler() {
    let fake = FakeBackgroundTaskProviding()
    let lifecycle = ScenePhaseAppLifecycle(backgroundTaskProviding: fake)
    let expired = ExpirationFlag()

    _ = lifecycle.beginBackgroundTask { expired.mark() }
    fake.simulateExpiration()

    #expect(expired.value == true)
  }

  @Test("no background time available: end is a safe no-op and reaches the provider zero times")
  func unavailableBackgroundTimeIsSafe() {
    let fake = FakeBackgroundTaskProviding()
    fake.hasAvailableBackgroundTime = false
    let lifecycle = ScenePhaseAppLifecycle(backgroundTaskProviding: fake)

    let token = lifecycle.beginBackgroundTask {}
    lifecycle.endBackgroundTask(token)

    #expect(fake.endCallCount == 0)
  }

  @Test("every subscriber receives each lifecycle transition")
  func transitionsAreMulticast() async {
    let lifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())
    var first = lifecycle.transitions.makeAsyncIterator()
    var second = lifecycle.transitions.makeAsyncIterator()

    lifecycle.handle(scenePhase: .active)
    lifecycle.handle(scenePhase: .background)

    #expect(await first.next() == .foreground)
    #expect(await second.next() == .foreground)
  }

  @Test("a late subscriber waits for the next transition rather than replaying an old edge")
  func transitionsDoNotReplay() async {
    let lifecycle = ScenePhaseAppLifecycle(
      backgroundTaskProviding: FakeBackgroundTaskProviding())
    lifecycle.handle(scenePhase: .active)

    var iterator = lifecycle.transitions.makeAsyncIterator()
    lifecycle.handle(scenePhase: .background)

    #expect(await iterator.next() == .background)
  }
}

/// A single-write `Bool` flag, safe to mutate from an `@escaping @Sendable` expiration handler.
/// Mirrors the flag in Core's `BackgroundTaskPolicyTests`. It is duplicated because test doubles
/// are not shared across the App/Core module boundary.
private nonisolated final class ExpirationFlag: @unchecked Sendable {
  private let valueBox = Locked(false)

  var value: Bool { valueBox.value }

  func mark() { valueBox.withValue { $0 = true } }
}
