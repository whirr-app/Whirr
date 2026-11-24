import Testing

@testable import PlayerCore

/// Test double for `AudioEngine` (`PlayerControllerTests`). Records every command it receives and
/// lets the test push events onto `events` on demand via `emit`. No real player or timers.
@MainActor
final class FakeAudioEngine: AudioEngine {
  private(set) var loadCalls:
    [(track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap?)] = []
  private(set) var seekCalls: [Double] = []
  private(set) var playCallCount = 0
  private(set) var pauseCallCount = 0
  private(set) var stopCallCount = 0
  private(set) var setRateCalls: [Double] = []
  private(set) var setVolumeCalls: [Double] = []
  private(set) var setBoundaryCalls: [Double?] = []

  let events: AsyncStream<AudioEngineEvent>
  private let continuation: AsyncStream<AudioEngineEvent>.Continuation

  init() {
    var continuation: AsyncStream<AudioEngineEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func load(track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap?) {
    loadCalls.append((track, localOffset, rate, generation, trim))
  }

  func play() { playCallCount += 1 }
  func pause() { pauseCallCount += 1 }
  func seek(toLocalOffset offset: Double) { seekCalls.append(offset) }
  func setRate(_ rate: Double) { setRateCalls.append(rate) }
  func setVolume(_ volume: Double) { setVolumeCalls.append(volume) }
  func setBoundary(atLocalOffset offset: Double?) { setBoundaryCalls.append(offset) }
  func stop() { stopCallCount += 1 }

  /// Test-only: simulates the engine producing an event.
  func emit(_ event: AudioEngineEvent) {
    continuation.yield(event)
  }
}

/// Test double for `PlayerStallScheduling` (`PlayerStallTests`). Records each replacement and
/// cancellation, and lets a test deliver a chosen token synchronously. No real sleeps or timers.
@MainActor
final class FakePlayerStallScheduler: PlayerStallScheduling {
  private(set) var scheduleCalls: [(seconds: Double, token: Int)] = []
  private(set) var cancelCallCount = 0

  let timeouts: AsyncStream<Int>
  private let continuation: AsyncStream<Int>.Continuation

  init() {
    var continuation: AsyncStream<Int>.Continuation!
    timeouts = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  func schedule(after seconds: Double, token: Int) {
    scheduleCalls.append((seconds, token))
  }

  func cancel() {
    cancelCallCount += 1
  }

  /// Test-only: simulates this scheduler reaching a deadline.
  func fire(token: Int) {
    continuation.yield(token)
  }
}

/// Test double for `PlaybackClock` (`PlayerControllerTests`): a manually advanced clock, so no
/// real time passes.
final class ManualClock: PlaybackClock, @unchecked Sendable {
  private var current: Double
  private var slept: Double = 0

  init(now: Double) {
    current = now
  }

  func now() -> Double { current }

  /// Uptime plus any simulated device sleep, which `now()` does not see.
  func continuousNow() -> Double { current + slept }

  func advance(by delta: Double) {
    current += delta
  }

  /// Test-only: the device sleeps for `delta`. Continuous time passes, uptime does not.
  func sleepDevice(for delta: Double) {
    slept += delta
  }
}
