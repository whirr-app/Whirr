import Foundation
import TestSupport
import Testing

@testable import PlayerCore

/// A streamed track's asset load can fail with `NSURLErrorUserAuthenticationRequired`. The stream
/// path fails inside AVFoundation, not in the transport, so the transport's auth recovery never
/// sees it. An authentication failure arriving from the engine must renew the stream's
/// authorization once and reload, rather than replaying the same stale credential. What first
/// triggered the 401 on device is not modelled.
@MainActor
@Suite struct StreamAuthRecoveryTests {

  private static func singleTrackItem(duration: Double = 100) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  private static func authFailure() -> AudioEngineFailure {
    AudioEngineFailure(isRecoverable: true, isAuthenticationFailure: true, message: "401")
  }

  /// Drives the controller to a loaded, ready, playing item (generation 1), the state every test
  /// below starts its failure from. Waits on the engine/controller's own state rather than on the
  /// progress stream, so no iterator has to cross an isolation boundary.
  private static func startPlaying(_ controller: PlayerController, engine: FakeAudioEngine) async {
    controller.send(.load(item: singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    engine.emit(.ready(generation: 1))
    #expect(await waitUntil { controller.state.phase == .ready })
    controller.send(.play)
  }

  @Test func authenticationFailureRenewsStreamAuthorizationAndReloads() async {
    let engine = FakeAudioEngine()
    let renewer = FakeStreamAuthorizationRenewer(result: true)
    let controller = PlayerController(
      engine: engine, clock: ManualClock(now: 0), authorizationRenewer: renewer)
    await Self.startPlaying(controller, engine: engine)

    engine.emit(.failed(generation: 1, Self.authFailure()))

    #expect(await waitUntil { renewer.callCount == 1 })
    // The reload is what proves recovery actually happened: a fresh `load` against the renewed
    // credentials, not just a state change.
    #expect(await waitUntil { engine.loadCalls.count == 2 })
    #expect(engine.loadCalls.last?.generation == 2)
  }

  @Test func nonAuthenticationFailureNeverRenews() async {
    let engine = FakeAudioEngine()
    let renewer = FakeStreamAuthorizationRenewer(result: true)
    let controller = PlayerController(
      engine: engine, clock: ManualClock(now: 0), authorizationRenewer: renewer)
    await Self.startPlaying(controller, engine: engine)

    let transient = AudioEngineFailure(isRecoverable: true, message: "timed out")
    engine.emit(.failed(generation: 1, transient))
    #expect(await waitUntil { controller.state.phase == .failed(transient) })

    #expect(renewer.callCount == 0)
    #expect(engine.loadCalls.count == 1)
  }

  /// A renewal that cannot produce fresh credentials (its own refresh was definitively rejected)
  /// leaves the item failed rather than reloading into the same 401. The transport's own latch
  /// has already raised the recovery sheet by then.
  @Test func failedRenewalDoesNotReload() async {
    let engine = FakeAudioEngine()
    let renewer = FakeStreamAuthorizationRenewer(result: false)
    let controller = PlayerController(
      engine: engine, clock: ManualClock(now: 0), authorizationRenewer: renewer)
    await Self.startPlaying(controller, engine: engine)

    engine.emit(.failed(generation: 1, Self.authFailure()))
    #expect(await waitUntil { renewer.callCount == 1 })

    #expect(engine.loadCalls.count == 1)
    #expect(controller.state.phase == .failed(Self.authFailure()))
  }

  /// The download queue's policy (`handleAuthChallenge`) applied to playback:
  /// one renewed attempt, never an independent refresh loop. A second consecutive challenge with
  /// no successful load in between stops.
  @Test func secondConsecutiveAuthenticationFailureDoesNotRenewAgain() async {
    let engine = FakeAudioEngine()
    let renewer = FakeStreamAuthorizationRenewer(result: true)
    let controller = PlayerController(
      engine: engine, clock: ManualClock(now: 0), authorizationRenewer: renewer)
    await Self.startPlaying(controller, engine: engine)

    engine.emit(.failed(generation: 1, Self.authFailure()))
    #expect(await waitUntil { engine.loadCalls.count == 2 })

    engine.emit(.failed(generation: 2, Self.authFailure()))
    // A renewal would be started from the listener task that applies this event, so waiting for
    // that event to land is enough to see one if it were coming. `waitUntil` on the phase, not a
    // timeout, so nothing here depends on how long a would-be renewal takes.
    #expect(await waitUntil { controller.state.phase == .failed(Self.authFailure()) })

    #expect(renewer.callCount == 1)
    #expect(engine.loadCalls.count == 2)
  }

  /// The one-attempt guard is armed per playback attempt, not for the controller's lifetime: an
  /// explicit user retry after the automatic one gave up is entitled to its own renewal.
  @Test func userRetryAfterAGivenUpRenewalRearmsIt() async {
    let engine = FakeAudioEngine()
    let renewer = FakeStreamAuthorizationRenewer(result: false)
    let controller = PlayerController(
      engine: engine, clock: ManualClock(now: 0), authorizationRenewer: renewer)
    await Self.startPlaying(controller, engine: engine)

    engine.emit(.failed(generation: 1, Self.authFailure()))
    #expect(await waitUntil { renewer.callCount == 1 })

    controller.send(.retry)
    engine.emit(.failed(generation: 2, Self.authFailure()))

    #expect(await waitUntil { renewer.callCount == 2 })
  }
}

/// The classification the App-side adapter applies to an `AVPlayerItem` failure before handing it
/// to `PlayerCore`, pinned here because it is deterministic on the host. The device produced
/// `domain=NSURLErrorDomain code=-1013` with `status=0`; a plain HTTP `401` from the item's error
/// log is the same condition reported the other way round.
@Suite struct AudioEngineFailureClassificationTests {

  @Test func userAuthenticationRequiredIsAnAuthenticationFailure() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
    let failure = AudioEngineFailure(assetLoadError: error, responseStatusCode: 0)
    #expect(failure.isAuthenticationFailure)
    #expect(failure.isRecoverable)
  }

  @Test func unauthorizedResponseStatusIsAnAuthenticationFailure() {
    // AVFoundation reports its own generic media error for a rejected byte-range request; the
    // item's error log is what names the 401.
    let error = NSError(domain: avFoundationErrorDomainName, code: -11800)
    let failure = AudioEngineFailure(assetLoadError: error, responseStatusCode: 401)
    #expect(failure.isAuthenticationFailure)
  }

  @Test func nestedUnderlyingAuthenticationErrorIsAnAuthenticationFailure() {
    let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired)
    let error = NSError(
      domain: avFoundationErrorDomainName, code: -11800,
      userInfo: [NSUnderlyingErrorKey: underlying])
    let failure = AudioEngineFailure(assetLoadError: error, responseStatusCode: 0)
    #expect(failure.isAuthenticationFailure)
  }

  @Test func ordinaryTransportFailureIsNotAnAuthenticationFailure() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
    let failure = AudioEngineFailure(assetLoadError: error, responseStatusCode: 0)
    #expect(failure.isAuthenticationFailure == false)
    #expect(failure.isRecoverable)
  }

  @Test func forbiddenIsNotTreatedAsRenewable() {
    // A 403 is a decision about the account, not about the credential's freshness. Renewing the
    // token cannot change it, so it must not enter the renew-and-reload path.
    let error = NSError(domain: avFoundationErrorDomainName, code: -11800)
    let failure = AudioEngineFailure(assetLoadError: error, responseStatusCode: 403)
    #expect(failure.isAuthenticationFailure == false)
  }
}

/// `AVFoundationErrorDomain` without importing AVFoundation, which PlayerCore may not do
/// (ARCHITECTURE.md). These tests only need a domain other than `NSURLErrorDomain`.
private let avFoundationErrorDomainName = "AVFoundationErrorDomain"

/// Test double for `StreamAuthorizationRenewing`. Counts calls rather than recording arguments:
/// the seam takes none. Whatever item is loaded is the one whose credentials get re-minted.
final class FakeStreamAuthorizationRenewer: StreamAuthorizationRenewing, @unchecked Sendable {
  private let result: Bool
  private let lock = NSLock()
  private var calls = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return calls
  }

  init(result: Bool) {
    self.result = result
  }

  func renewStreamAuthorizationAndReconfigure() async -> Bool {
    lock.withLock { calls += 1 }
    return result
  }
}
